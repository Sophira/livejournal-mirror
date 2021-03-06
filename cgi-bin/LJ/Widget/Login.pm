package LJ::Widget::Login;

use strict;
use base qw(LJ::Widget::Template);
use Carp qw(croak);
use LJ::Auth::Challenge;
use LJ::Request;

# TODO: remove this method after Schemius Project is released.
sub render_body {
    my $class = shift;

    if ($LJ::DISABLED{'schemius_with_usescheme'}) {
        return $class->render_body_old(@_);
    }
    else {
        return $class->SUPER::render_body(@_);
    }
}

sub need_res {
    return 'stc/widgets/login.css';
}

sub template_filename {
    return "$ENV{'LJHOME'}/templates/Widgets/login.tmpl";
}

sub template_params {
    my ($class, $opts) = @_;
    $opts ||= {};

    my $remote = LJ::get_remote();
    return {} if $remote;

    my $is_login_page = (LJ::Request->uri eq '/login.bml');

    my $ret = $opts->{'get_ret'} || $opts->{'post_ret'};
    if (!$ret && $opts->{'ret_cur_page'}) {
        # use current url as return destination after login, for inline login
        $ret = $LJ::SITEROOT . LJ::Request->uri;
    }

    my @get_extra;
    if ($opts->{'nojs'}) {
        push @get_extra, [ nojs => 1 ];
    }

    if (!$is_login_page && $ret && $ret == 1) {
        push @get_extra, [ ret => 1 ];
    }

    my $use_ssl_login = $LJ::USE_SSL_LOGIN || $LJ::IS_SSL ? 1 : 0;
    my $form_siteroot = $use_ssl_login ? $LJ::SSLROOT : $LJ::SITEROOT;
    my $form_action_url = "$form_siteroot/login.bml" . (@get_extra ? '?' . join '&', map { "$_->[0]=$_->[1]" } @get_extra : '');

    my $ref;
    if ($is_login_page && $ret && $ret == 1) {
        $ref = LJ::Request->header_in('Referer');
    }

    my $params = {
        form_action_url => $form_action_url,
        use_ssl_login   => $use_ssl_login,
        user            => $opts->{'user'},
        returnto        => $opts->{'returnto'},
        ref             => $ref,
        ret             => $ret,
    };

    unless ($use_ssl_login) {
        $params->{'chal'} = LJ::Auth::Challenge->generate(300); # 5 minute auth token
    }

    return $params;
}

sub prepare_template_params {
    my ($class, $template, $opts) = @_;

    $template->param( %{ $class->template_params($opts) } );
}

sub render_body_old {
    my $class = shift;
    my %opts = @_;
    my $ret;

    my $remote = LJ::get_remote();
    return "" if $remote;

    my $nojs = $opts{nojs};
    my $user = $opts{user};
    my $mode = $opts{mode};
    
    my $getextra = $nojs ? '?nojs=1' : '';

    # Is this the login page?
    # If so treat ret value differently
    my $isloginpage = 0;
    $isloginpage = 1 if LJ::Request->uri eq '/login.bml';

    if (!$isloginpage && $opts{get_ret} == 1) {
        $getextra .= $getextra eq '' ? '?ret=1' : '&ret=1';
    }

    my $root = $LJ::IS_SSL ? $LJ::SSLROOT : $LJ::SITEROOT;
    my $form_class = LJ::run_hook("login_form_class_name_$opts{mode}");
    $form_class = "lj_login_form pkg" unless $form_class;
    my $form_siteroot = ($LJ::USE_SSL_LOGIN) ? $LJ::SSLROOT : $root;
    $ret .= "<form action='$form_siteroot/login.bml$getextra' method='post' class='$form_class'>\n";

    if (!$LJ::USE_SSL_LOGIN) {
        $ret .= LJ::form_auth();
        my $chal = LJ::Auth::Challenge->generate(300); # 5 minute auth token
        $ret .= "<input type='hidden' name='chal' class='lj_login_chal' value='$chal' />\n";
        $ret .= "<input type='hidden' name='response' class='lj_login_response' value='' />\n";
    }

    my $referer = LJ::Request->header_in('Referer');
    if ($isloginpage && $opts{get_ret} == 1 && $referer) {
        my $eh_ref = LJ::ehtml($referer);
        $ret .= "<input type='hidden' name='ref' value='$eh_ref' />\n";
    }

    if (! $opts{get_ret} && $opts{ret_cur_page}) {
        # use current url as return destination after login, for inline login
        $ret .= LJ::html_hidden('ret', $LJ::SITEROOT . LJ::Request->uri);
    }

    if ($opts{returnto}) {
        $ret .= LJ::html_hidden('returnto', $opts{returnto});
    }

    my $hook_rv = LJ::run_hook("login_form_$opts{mode}", create_link => $opts{create_link});
    if ($hook_rv) {
        $ret .= $hook_rv;
    } else {
        $ret .= "<h2>" . LJ::Lang::ml('/login.bml.login.welcome', { 'sitename' => $LJ::SITENAMESHORT }) . "</h2>\n";
        $ret .= "<fieldset class='pkg nostyle'>\n";
        $ret .= "<label for='user' class='left'>" . LJ::Lang::ml('/login.bml.login.username') . "</label>\n";
        $ret .= "<input type='text' value='$user' name='user' id='user' class='text' size='18' maxlength='17' style='' />\n";
        $ret .= "</fieldset>\n";
        $ret .= "<fieldset class='pkg nostyle'>\n";
        $ret .= "<label for='lj_loginwidget_password' class='left'>" . LJ::Lang::ml('/login.bml.login.password') . "</label>\n";
        $ret .= "<input type='password' id='lj_loginwidget_password' name='password' class='lj_login_password text' size='20' maxlength='30' /><a href='$LJ::SITEROOT/lostinfo.bml' class='small-link'>" . LJ::Lang::ml('/login.bml.login.forget2') . "</a>\n";
        $ret .= "</fieldset>\n";
        $ret .= "<p><input type='checkbox' name='remember_me' id='remember_me' value='1' tabindex='4' /> <label for='remember_me'>" . LJ::Lang::ml('/login.bml.login.remember') . "</label></p>";

        # standard/secure links removed for now
        my $secure = "<p>";
        $secure .= "<img src='$LJ::IMGPREFIX/padlocked.gif?v=5938' class='secure-image' width='20' height='16' alt='secure login' />";
        $secure .= LJ::Lang::ml('/login.bml.login.secure') . " | <a href='$LJ::SITEROOT/login.bml?nojs=1'>" . LJ::Lang::ml('/login.bml.login.standard') . "</a></p>";

        $ret .= "<p><input name='action:login' type='submit' value='" . LJ::Lang::ml('/login.bml.login.btn.login') . "' /> <a href='$LJ::SITEROOT/openid/' class='small-link'>" . LJ::Lang::ml('/login.bml.login.openid') . "</a></p>";

        if (! $LJ::IS_SSL) {
            my $login_btn_text = LJ::ejs(LJ::Lang::ml('/login.bml.login.btn.login'));

            if ($nojs) {
                # insecure now, but because they choose to not use javascript.  link to
                # javascript version of login if they seem to have javascript, otherwise
                # noscript to SSL
                $ret .= "<script type='text/javascript' language='Javascript'>\n";
                $ret .= "<!-- \n document.write(\"<p style='padding-bottom: 5px'><img src='$LJ::IMGPREFIX/unpadlocked.gif?v=5938' width='20' height='16' alt='secure login' align='middle' />" .
                    LJ::ejs(" <a href='$LJ::SITEROOT/login.bml'>" . LJ::Lang::ml('/login.bml.login.secure') . "</a> | " . LJ::Lang::ml('/login.bml.login.standard') . "</p>") .
                    "\"); \n // -->\n </script>\n";
                if ($LJ::USE_SSL) {
                    $ret .= "<noscript>";
                    $ret .= "<p style='padding-bottom: 5px'><img src='$LJ::IMGPREFIX/unpadlocked.gif?v=5938' width='20' height='16' alt='secure login' align='middle' /> <a href='$LJ::SSLROOT/login.bml'>" . LJ::Lang::ml('/login.bml.login.secure') . "</a> | " . LJ::Lang::ml('/login.bml.login.standard') . "</p>";
                    $ret .= "</noscript>";
                }
            } else {
                # insecure now, and not because it was forced, so javascript doesn't work.
                # only way to get to secure now is via SSL, so link there
                $ret .= "<p><img src='$LJ::IMGPREFIX/unpadlocked.gif?v=5938' width='20' height='16' class='secure-image' alt='secure login' />";
                $ret .= " <a href='$LJ::SSLROOT/login.bml'>" . LJ::Lang::ml('/login.bml.login.secure') . "</a> | " . LJ::Lang::ml('/login.bml.login.standard') . "</p>\n"
                    if $LJ::USE_SSL;

            }
        }
        $ret .= LJ::help_icon('securelogin', '&nbsp;');

        if (LJ::are_hooks("login_formopts")) {
            $ret .= "<table>";
            $ret .= "<tr><td>" . LJ::Lang::ml('/login.bml.login.otheropts') . "</td><td style='white-space: nowrap'>\n";
            LJ::run_hooks("login_formopts", { 'ret' => \$ret });
            $ret .= "</td></tr></table>";
        }
    }

    # Save offsite redirect uri between POSTs
    my $redir = $opts{get_ret} || $opts{post_ret};
    $ret .= LJ::html_hidden('ret', $redir) if $redir && $redir != 1;

    $ret .= "</form>\n";

    return $ret;
}

1;
