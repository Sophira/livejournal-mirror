package LJ::Widget::SubmitRequest;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( Captcha::reCAPTCHA );

use LJ::ModuleLoader;
LJ::ModuleLoader->autouse_subclasses('LJ::Widget::SubmitRequest');

sub need_res { }

# opts:
#  spid     -> comes from handle_post, spid of req this generated

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $post = $opts{post};

    # bail if we're done
    return $class->text_done(%opts) if $opts{spid};

    my $remote = LJ::get_remote();
    my $ret = $class->start_form;

    $ret .= "<?p " . $class->text_intro(%opts) . " p?>";

    unless ($remote && $remote->email_raw) {
        unless ($remote) {
            $ret .= "<?p <em>" . $class->ml('widget.support.submit.login.note', {sitename=>$LJ::SITENAMESHORT, loginlink=>"href='$LJ::SITEROOT/login.bml?ret=1'"}) . "</em> p?>";

            $ret .= "<p><b>" . $class->ml('widget.support.submit.yourname') . "</b><br />";
            $ret .= "<div style='margin-left: 30px'>";
            $ret .= $class->html_text(name => 'reqname', size => '40', maxlength => '50', value => $post->{reqname});
            $ret .= "</div></p>";
        }

        $ret .= "<p><b>" . $class->ml('widget.support.submit.yourmail') . "</b><br />";
        $ret .= "<div style='margin-left: 30px'>";
        $ret .= $class->html_text(name => 'email', size => '30', maxlength => '70', value => $post->{email});
        $ret .= "<br /><?de " . $class->ml('widget.support.submit.notshow') . " de?></div></p>";
     };

    my $cats = LJ::Support::load_cats();
    # hidden, if a subclass specifies a category
    if (my $cat = LJ::Support::get_cat_by_key($cats, $class->category)) {
        $ret .= $class->html_hidden("spcatid" => $cat->{spcatid});

    # shown with no choices if passed in as an opt
    } elsif (($cat = LJ::Support::get_cat_by_key($cats, $opts{category})) && $cat->{is_selectable}) {
        $ret .= "<p><b>" . $class->ml('widget.support.submit.category') . "</b><br />";
        $ret .= "<div style='margin-left: 30px'>";
        $ret .= $cat->{catname};
        $ret .= "</div></p>";
        $ret .= $class->html_hidden("spcatid" => $cat->{spcatid});

    # dropdown, otherwise
    } else {
        $ret .= "<p><b>" . $class->ml('widget.support.submit.category') . "</b><br />";
        $ret .= "<div style='margin-left: 30px'>";

        my @choices;
        foreach (sort { $a->{sortorder} <=> $b->{sortorder} } values %$cats) {
            next unless $_->{is_selectable};
            push @choices, $_->{spcatid}, $_->{catname};
        }
        my $selected = $post->{spcatid};
        LJ::run_hook("support_request_extra_cat", \@choices, \$selected, $cats);
        $ret .= $class->html_select(name => 'spcatid', list => \@choices, selected => $selected);
        $ret .= LJ::run_hook("support_request_cat_extra_text");
        $ret .= "</div></p>";
    }

    if (LJ::is_enabled("support_request_language")) {
        my $lang_list = LJ::Lang::get_lang_names();
        for (my $i = 0; $i < @$lang_list; $i = $i+2) {
            unless ($LJ::LANGS_FOR_SUPPORT_REQUESTS{$lang_list->[$i]}) {
                splice(@$lang_list, $i, 2);
                $i = $i - 2;
            }
        }

        if ($lang_list) {
            push @$lang_list, ( xx => $class->ml('widget.support.submit.language.other') );
            $ret .= "<p><b>" . $class->ml('widget.support.submit.language') . "</b><br />";
            $ret .= "<div style='margin-left: 30px'>";
            $ret .= "<p><?de " . $class->ml('widget.support.submit.language.note') . " de?></p>";
            $ret .= $class->html_select(name => 'language', list => $lang_list, selected => $post->{language} || "en_LJ");
            $ret .= "</div></p>";
        }
    }

    $ret .= "<p><b>" . $class->header_summary(%opts) . "</b><br />";
    $ret .= "<div style='margin-left: 30px'>";
    $ret .= $class->html_text(name => 'subject', size => '40', maxlength => '80', value => $post->{subject});
    $ret .= "</div></p>";

    $ret .= "<p><b>" . $class->header_question(%opts) . "</b><br />";
    $ret .= "<div style='margin-left: 30px'>";
    $ret .= "<p><?de " . $class->text_question(%opts) . " de?></p>";
    $ret .= $class->html_textarea(name => 'message', rows => '15', cols => '70', wrap => 'soft', value => $post->{message});
    $ret .= "</div></p>";

    ## is javascript on?
    $ret .= "\n" . $class->html_hidden({name => 'has_js', id => 'has_js', value => 'N'});
    $ret .= "\n" . '
<script>
    // $() is DOM.getElement() defined in htdocs/js/dom.js
    if ($) {
        var has_js = $("has_js"); 
        if (has_js) { has_js.value = "Y" } 
    }
</script>';

    if ($LJ::HUMAN_CHECK{support_submit} && LJ::is_enabled("recaptcha") && !$remote) {
        my $c = Captcha::reCAPTCHA->new;

        $ret .= "<p><b>" . $class->ml('widget.support.submit.captcha') . "</b><br />";
        $ret .= "<div style='margin-left: 30px'>";
        $ret .= "<p><?de " . $class->text_captcha(%opts) . " de?></p>";
        $ret .= "<div style='position: relative; height: 1%;'>" . $c->get_options_setter({ theme => 'white', lang => BML::get_language() });
        $ret .= $c->get_html( LJ::conf_test($LJ::RECAPTCHA{public_key}) ) . "</div>";
        $ret .= "</div></p>";
    }

    $ret .= "<br /><?standout <input type='submit' value='" . $class->text_submit(%opts) . "' /> standout?>";
    $ret .= $class->end_form;

    return $ret;
}

# override with a specific category key that these should go into
sub category { undef }

# whether the user should get the link to the request generated
sub send_email { 1 }

sub header_summary { $_[0]->ml('widget.support.submit.summary') }

sub header_question { $_[0]->ml('widget.support.submit.question') }

sub text_done {
    my ($class, %opts) = @_;

    my $spid = $opts{spid};
    my $auth = LJ::Support::mini_auth(LJ::Support::load_request($spid, undef, {'db_force' => 1}));
    my $url = "$LJ::SITEROOT/support/see_request.bml?id=$spid&amp;auth=$auth";

    return $class->ml('widget.support.submit.complete.text', {'url'=>$url});
}

sub text_intro { "" }

sub text_question { $_[0]->ml('widget.support.submit.question.note') }

sub text_captcha { $_[0]->ml('widget.support.submit.captcha.note', { email => $LJ::SUPPORT_EMAIL }) }

sub text_submit { $_[0]->ml('widget.support.submit.button') }

sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    my %req;
    my $remote = LJ::get_remote();

    if ($remote) {
        $req{'reqtype'} = "user";
        $req{'requserid'} = $remote->id;
        $req{'reqemail'} = $remote->email_raw || $post->{'email'};
        $req{'reqname'} = $remote->name_html;

    } else {
        $req{'reqtype'} = "email";
        $req{'reqemail'} = $post->{'email'};
        $req{'reqname'} = $post->{'reqname'};
    }

    my @errors;
    LJ::check_email($post->{'email'}, \@errors) if $post->{'email'};

    if ($LJ::HUMAN_CHECK{support_submit} && LJ::is_enabled("recaptcha") && !$remote) {
        my $c = Captcha::reCAPTCHA->new;
        my $result = $c->check_answer(
            LJ::conf_test($LJ::RECAPTCHA{private_key}), $ENV{REMOTE_ADDR},
            $post->{recaptcha_challenge_field}, $post->{recaptcha_response_field}
        );

        push @errors, $class->ml('widget.support.submit.error.captcha') unless $result->{is_valid} eq '1';
    }

    if (LJ::is_enabled("support_request_language")) {
        $post->{'language'} = "en_LJ" unless grep { $post->{'language'} eq $_ } (@LJ::LANGS, "xx");
        $req{'language'} = $post->{'language'};
    }

    $req{'body'}    = $post->{'message'};
    $req{'subject'} = $post->{'subject'};
    $req{'spcatid'} = $post->{'spcatid'};
    $req{'uniq'}    = LJ::UniqCookie->current_uniq;
    $req{'ip'}      = LJ::get_remote_ip();
    $req{'has_js'}  = $post->{'has_js'};

    $req{'is_beta'} = LJ::Request->cookie('ljbetatest') ? 1 : 0;

    # don't autoreply if they aren't gonna get a link
    $req{'no_autoreply'} = $class->send_email ? 0 : 1;

    # insert diagnostic information
    $req{'useragent'} = BML::get_client_header('User-Agent')
        if $LJ::SUPPORT_DIAGNOSTICS{track_useragent};

    return $class->error_list(@errors) if @errors;
    my $spid = LJ::Support::file_request(\@errors, \%req);
    return $class->error_list(@errors) if @errors;

    return ('spid' => $spid);
}

sub error_list {
    my ($class, @errors) = @_;
    return unless @errors;

    $class->error($_) foreach @errors;
}

1;
