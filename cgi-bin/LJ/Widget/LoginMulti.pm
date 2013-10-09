package LJ::Widget::LoginMulti;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use LJ::Request;
use URI;
use LJ::SocialScripts;

sub need_res { return 'stc/widgets/login.css' }

sub render_body {
    my $class = shift;
    my %opts = @_;
    my $ret;
    my @errors = ();

    ## Page with widget
    my $thispage = $opts{thispage} || "$LJ::SITEROOT/identity/login.bml";
    my $forwhat = $opts{'forwhat'} || 'login';
    $thispage =~ m|^http://|
        or die "'thispage' param should be absolute uri";

    ## Handle auth params
    if (LJ::Request->did_post) {
        do_login($thispage, $forwhat, \@errors, \%opts);
        ## where to go on success?
        return if LJ::Request->redirected;
    }

    my $filename = 'Login';
    if ( $opts{'embedded'} ) {
        my $partner = $opts{'partner'};
        $filename = 'ExternalLogin/v' . $partner->widget_version;
    }

    ## Draw widget
    my $template = LJ::HTML::Template->new(
        { use_expr => 1 }, # force HTML::Template::Pro with Expr support
        filename => "$ENV{'LJHOME'}/templates/Identity/$filename.tmpl",
        die_on_bad_params => 0,
        strict => 0,
    ) or die "Can't open template: $!";

    my $current_type = LJ::Request->post_param('type') ||
                       LJ::Request->get_param('type')  ||
                       $LJ::IDENTITY_TYPES[0];

    ## to lj.com authorization we need to send data to https endpoint of this page
    my $action_uri = URI->new($thispage);
    $action_uri->scheme("https");
    $action_uri->fragment(undef);
    $action_uri->query(undef);

    ## Auth types.
    ## User type (LJ.com) is always enabled.
    my @types;
    my $auth_types = ['user', @LJ::IDENTITY_TYPES];
    LJ::run_hook('override_auth_sequence', $opts{'partner'}->{'journal'}, $auth_types);

    ## external auth
    foreach my $type (@$auth_types) {
        if ($type eq 'user') {
            next unless $opts{'lj_auth'};
        } else {
            my $idclass = LJ::Identity->find_class($type);
            next unless $idclass->enabled;
        }

        my $type_display = {
            'type' => $type,
            'ml_tab_heading' => LJ::Lang::ml("/identity/login.bml.tab.$type"),
            'user_returnto'   => $type eq 'user' && $opts{'user_returnto'},
        };

        if ($type eq $current_type) {
            $type_display->{'errors'} = [ map { { 'error' => $_ } } @errors ];
        }

        if ( $opts{'embedded'} && ($type eq 'user' || $opts{'partner'}->identity_type_enabled($type)) )
        {
           $template->param( 'type_' . $type => [ $type_display ] );
        }
        push @types, $type_display;

        if ( $type eq 'google' ) {
            $template->param( "page_javascript" => LJ::SocialScripts::load_scripts( { require_scripts => ["google"] } ) );
            $template->param( 'google_client_id' => $LJ::GOOGLE_OAUTH_CONF->{'client_id'}, );
            LJ::need_res("js/google_auth.js");
        }
    }

    $template->param(
        'types'             => \@types,
        'primary_types'     => [@types[0 .. int(@types/2)-1]],
        'secondary_types'   => [@types[int(@types/2) .. @types-1]],
        'current_type'      => $current_type,
        'returnto'          => $thispage,
        'js_check_domain'   => $opts{'js_check_domain'},
        'resources_html'    => $opts{'resources_html'},
        'external_resources'=> $opts{'external_resources'},
    );

    ## well cooked widget is here
    return $template->output;
}

sub do_login {
    my ( $thispage, $forwhat, $errors, $opts ) = @_;
    my $idtype = LJ::Request->post_param('type');

    ## Special case: perform LJ.com login.
    if ($idtype eq 'user') {
        ## Determine user
        my $username = LJ::Request->post_param('user');
        unless ($username){
            push @$errors => LJ::Lang::ml("/talkpost_do.bml.error.nousername");
            return;
        }
        ##
        my $u = LJ::load_user($username);
        unless ($u){
            push @$errors,
                LJ::Lang::ml( '/identity/login.bml.user.error.badusername', {
                    'sitename' => $LJ::SITENAMESHORT,
                    'aopts'    => "href='$LJ::SITEROOT/lostinfo.bml'",
                } );
            return;
        }
        ##
        unless ($u->is_person and $u->is_visible){
            push @$errors => LJ::Lang::ml("/identity/login.bml.user.denylogin");
            return;
        }


        ## Verify
        my $ok = LJ::auth_okay($u, LJ::Request->post_param('password'));
        unless ($ok){
            push @$errors => LJ::Lang::ml("/talkpost_do.bml.error.badpassword2", {
                                            'aopts' => "href='$LJ::SITEROOT/lostinfo.bml'",
                                            });
            return;
        }

        ## Init Session
        my $exptype = (LJ::Request->post_param('remember_me') ? 'long' : 'short');
        my $ipfixed = 0;
        $u->make_login_session($exptype, $ipfixed);

        ## Where to go?
        my $returnto = LJ::Request->post_param("returnto") || $thispage;
        unless ( $returnto =~ m!^https?://\Q$LJ::DOMAIN_WEB\E/! ) {
            my $returl_fail;
            ($returnto, $returl_fail)
                = LJ::Identity->unpack_forwhat($forwhat);
        }
        LJ::Request->redirect($returnto);

        return 1;

    } else {
        my $idclass = LJ::Identity->find_class($idtype);
        if ($idclass && $idclass->enabled) {
            ## Where to go?
            my $returnto = LJ::Request->post_param("returnto") || $thispage;
            my $returl_fail = LJ::Request->post_param("returl_fail") || "$thispage?type=$idtype&failed=1";
            if ( $opts->{'embedded'}
              || $returnto !~ m!^https?://\Q$LJ::DOMAIN_WEB\E/! )
            {
                ($returnto, $returl_fail)
                    = LJ::Identity->unpack_forwhat($forwhat);
            }

            $idclass->attempt_login($errors,
                'returl' => $returnto,
                'returl_fail' => $returl_fail,
                'forwhat' => $forwhat,
            );

            return 1 if LJ::Request->redirected;

            LJ::Request->redirect($returnto);

        } else {
            push @$errors, 'unknown identity type';
        }
    }

}

1;
