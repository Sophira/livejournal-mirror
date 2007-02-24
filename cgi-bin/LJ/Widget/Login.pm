package LJ::Widget::Login;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub render_body {
    my $class = shift;
    my %opts = @_;
    my $ret;

    my $remote = LJ::get_remote();
    return "" if $remote;

    my $nojs = $opts{nojs};
    my $user = $opts{user};

    my $getextra = $nojs ? '?nojs=1' : '';

    LJ::need_res('stc/widgets/login.css');

    $ret .= "<form action='login.bml$getextra' method='post' id='login'>\n";
    $ret .= LJ::form_auth();

    my $chal = LJ::challenge_generate(300); # 5 minute auth token
    $ret .= "<input type='hidden' name='chal' id='login_chal' value='$chal' />\n";
    $ret .= "<input type='hidden' name='response' id='login_response' value='' />\n";

    my $referer = BML::get_client_header('Referer');
    if ($opts{get_ret} == 1 && $referer) {
        my $eh_ref = LJ::ehtml($referer);
        $ret .= "<input type='hidden' name='ref' value='$eh_ref' />\n";
    }

    $ret .= "<h2>" . LJ::Lang::ml('/login.bml.login.welcome', { 'sitename' => $LJ::SITENAMESHORT }) . "</h2>\n";
    $ret .= "<fieldset class='pkg nostyle'>\n";
    $ret .= "<label for='user' class='left'>" . LJ::Lang::ml('/login.bml.login.username') . "</label>\n";
    $ret .= "<input type='text' value='$user' name='user' id='user' class='text' size='18' maxlength='17' style='' />\n";
    $ret .= "</fieldset>\n";
    $ret .= "<fieldset class='pkg nostyle'>\n";
    $ret .= "<label for='xc_password' class='left'>" . LJ::Lang::ml('/login.bml.login.password') . "</label>\n";
    $ret .= "<input type='password' name='password' id='xc_password' class='text' size='20' maxlength='30' />\n";
    $ret .= "</fieldset>\n";

    my $secure = "<p>";
    $secure .= "<img src='$LJ::IMGPREFIX/padlocked.gif' class='secure-image' width='20' height='16' alt='secure login' />";
    $secure .= LJ::Lang::ml('/login.bml.login.secure') . " | <a href='$LJ::SITEROOT/login.bml?nojs=1'>" . LJ::Lang::ml('/login.bml.login.standard') . "</a></p>";

    if ($LJ::IS_SSL) {
        $ret .= $secure;
        $ret .= "<p><input name='action:login' type='submit' value='" . LJ::Lang::ml('/login.bml.login.btn.login') . "' /></p>";
    } else {
        my $login_btn_text = LJ::ejs(LJ::Lang::ml('/login.bml.login.btn.login'));
        unless ($nojs) {
            $ret .= "<script type='text/javascript' language='Javascript'> \n <!-- \n
              document.write(\"$secure\")
              document.write(\"<p><input name='action:login' onclick='return sendForm()' type='submit' value='$login_btn_text' /></p>\");";
            $ret .= "
              if (document.getElementById && document.getElementById('login')) {
                //document.write(\"&nbsp; <img src='$LJ::IMGPREFIX/icon_protected.gif' width='14' height='15' alt='secure login' align='middle' />\");
               }\n // -->\n ";
            $ret .= '</script>';
            $ret .= "<noscript>";
        }

        if ($nojs) {
            # insecure now, but because they choose to not use javascript.  link to
            # javascript version of login if they seem to have javascript, otherwise
            # noscript to SSL
            $ret .= "<script type='text/javascript' language='Javascript'>\n";
            $ret .= "<!-- \n document.write(\"<p style='padding-bottom: 5px'><img src='$LJ::IMGPREFIX/unpadlocked.gif' width='20' height='16' alt='secure login' align='middle' />" .
                LJ::ejs(" <a href='$LJ::SITEROOT/login.bml'>" . LJ::Lang::ml('/login.bml.login.secure') . "</a> | " . LJ::Lang::ml('/login.bml.login.standard') . "</p>") .
                "\"); \n // -->\n </script>\n";
            if ($LJ::USE_SSL) {
                $ret .= "<noscript>";
                $ret .= "<p style='padding-bottom: 5px'><img src='$LJ::IMGPREFIX/unpadlocked.gif' width='20' height='16' alt='secure login' align='middle' /> <a href='$LJ::SSLROOT/login.bml'>" . LJ::Lang::ml('/login.bml.login.secure') . "</a> | " . LJ::Lang::ml('/login.bml.login.standard') . "</p>";
                $ret .= "</noscript>";
            }
        } else {
            # insecure now, and not because it was forced, so javascript doesn't work.
            # only way to get to secure now is via SSL, so link there
            $ret .= "<p><img src='$LJ::IMGPREFIX/unpadlocked.gif' width='20' height='16' class='secure-image' alt='secure login' />";
            $ret .= " <a href='$LJ::SSLROOT/login.bml'>" . LJ::Lang::ml('/login.bml.login.secure') . "</a> | " . LJ::Lang::ml('/login.bml.login.standard') . "</p>\n"
                if $LJ::USE_SSL;

        }

        $ret .= "<p><input name='action:login' type='submit' value='" . LJ::Lang::ml('/login.bml.login.btn.login') . "' /></p>";
        $ret .= "</noscript>" unless $nojs;
    }
    $ret .= LJ::help_icon('securelogin', '&nbsp;');

    $ret .= "<p class='forgot-password'><a href='/lostinfo.bml'>" . LJ::Lang::ml('/login.bml.login.forget2') . "</a></p>\n";

    if (LJ::are_hooks("login_formopts")) {
        $ret .= "<table>";
        $ret .= "<tr><td>" . LJ::Lang::ml('/login.bml.login.otheropts') . "</td><td style='white-space: nowrap'>\n";
        LJ::run_hooks("login_formopts", { 'ret' => \$ret });
        $ret .= "</td></tr></table>";
    }

    # Save offsite redirect uri between POSTs
    my $redir = $opts{get_ret} || $opts{post_ret};
    $ret .= LJ::html_hidden('ret', $redir) if $redir && $redir != 1;

    $ret .= "</form>\n";

    return $ret;
}

1;
