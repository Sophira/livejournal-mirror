#!/usr/bin/perl
#

package LJ;
use strict;

use lib "$ENV{LJHOME}/cgi-bin";

# load the bread crumb hash
require "crumbs.pl";

use Carp;
use Class::Autouse qw(
                      LJ::Event
                      LJ::Subscription::Pending
                      LJ::M::ProfilePage
                      LJ::Directory::Search
                      LJ::Directory::Constraint
                      LJ::M::FriendsOf
                      );

# <LJFUNC>
# name: LJ::img
# des: Returns an HTML &lt;img&gt; or &lt;input&gt; tag to an named image
#      code, which each site may define with a different image file with
#      its own dimensions.  This prevents hard-coding filenames & sizes
#      into the source.  The real image data is stored in LJ::Img, which
#      has default values provided in cgi-bin/imageconf.pl but can be
#      overridden in etc/ljconfig.pl.
# args: imagecode, type?, attrs?
# des-imagecode: The unique string key to reference the image.  Not a filename,
#                but the purpose or location of the image.
# des-type: By default, the tag returned is an &lt;img&gt; tag, but if 'type'
#           is "input", then an input tag is returned.
# des-attrs: Optional hashref of other attributes.  If this isn't a hashref,
#            then it's assumed to be a scalar for the 'name' attribute for
#            input controls.
# </LJFUNC>
sub img
{
    my $ic = shift;
    my $type = shift;  # either "" or "input"
    my $attr = shift;

    my $attrs;
    if ($attr) {
        if (ref $attr eq "HASH") {
            foreach (keys %$attr) {
                $attrs .= " $_=\"" . LJ::ehtml($attr->{$_}) . "\"";
            }
        } else {
            $attrs = " name=\"$attr\"";
        }
    }

    my $i = $LJ::Img::img{$ic};
    my $alt = LJ::Lang::string_exists($i->{'alt'}) ? LJ::Lang::ml($i->{'alt'}) : $i->{'alt'};
    if ($type eq "") {
        return "<img src=\"$LJ::IMGPREFIX$i->{'src'}\" width=\"$i->{'width'}\" ".
            "height=\"$i->{'height'}\" alt=\"$alt\" title=\"$alt\" ".
            "border='0'$attrs />";
    }
    if ($type eq "input") {
        return "<input type=\"image\" src=\"$LJ::IMGPREFIX$i->{'src'}\" ".
            "width=\"$i->{'width'}\" height=\"$i->{'height'}\" title=\"$alt\" ".
            "alt=\"$alt\" border='0'$attrs />";
    }
    return "<b>XXX</b>";
}

# <LJFUNC>
# name: LJ::date_to_view_links
# class: component
# des: Returns HTML of date with links to user's journal.
# args: u, date
# des-date: date in yyyy-mm-dd form.
# returns: HTML with yyyy, mm, and dd all links to respective views.
# </LJFUNC>
sub date_to_view_links
{
    my ($u, $date) = @_;
    return unless $date =~ /^(\d\d\d\d)-(\d\d)-(\d\d)/;

    my ($y, $m, $d) = ($1, $2, $3);
    my ($nm, $nd) = ($m+0, $d+0);   # numeric, without leading zeros
    my $user = $u->{'user'};
    my $base = LJ::journal_base($u);

    my $ret;
    $ret .= "<a href=\"$base/$y/\">$y</a>-";
    $ret .= "<a href=\"$base/$y/$m/\">$m</a>-";
    $ret .= "<a href=\"$base/$y/$m/$d/\">$d</a>";
    return $ret;
}


# <LJFUNC>
# name: LJ::auto_linkify
# des: Takes a plain-text string and changes URLs into <a href> tags (auto-linkification).
# args: str
# des-str: The string to perform auto-linkification on.
# returns: The auto-linkified text.
# </LJFUNC>
sub auto_linkify
{
    my $str = shift;
    my $match = sub {
        my $str = shift;
        if ($str =~ /^(.*?)(&(#39|quot|lt|gt)(;.*)?)$/) {
            return "<a href='$1'>$1</a>$2";
        } else {
            return "<a href='$str'>$str</a>";
        }
    };
    $str =~ s!https?://[^\s\'\"\<\>]+[a-zA-Z0-9_/&=\-]! $match->($&); !ge;
    return $str;
}

# return 1 if URL is a safe stylesheet that S1/S2/etc can pull in.
# return 0 to reject the link tag
# return a URL to rewrite the stylesheet URL
# $href will always be present.  $host and $path may not.
sub valid_stylesheet_url {
    my ($href, $host, $path) = @_;
    unless ($host && $path) {
        return 0 unless $href =~ m!^https?://([^/]+?)(/.*)$!;
        ($host, $path) = ($1, $2);
    }

    my $cleanit = sub {
        # allow tag, if we're doing no css cleaning
        return 1 if $LJ::DISABLED{'css_cleaner'};

        # remove tag, if we have no CSSPROXY configured
        return 0 unless $LJ::CSSPROXY;

        # rewrite tag for CSS cleaning
        return "$LJ::CSSPROXY?u=" . LJ::eurl($href);
    };

    return 1 if $LJ::TRUSTED_CSS_HOST{$host};
    return $cleanit->() unless $host =~ /\Q$LJ::DOMAIN\E$/i;

    # let users use system stylesheets.
    return 1 if $host eq $LJ::DOMAIN || $host eq $LJ::DOMAIN_WEB ||
        $href =~ /^\Q$LJ::STATPREFIX\E/;

    # S2 stylesheets:
    return 1 if $path =~ m!^(/\w+)?/res/(\d+)/stylesheet(\?\d+)?$!;

    # unknown, reject.
    return $cleanit->();
}


# <LJFUNC>
# name: LJ::make_authas_select
# des: Given a u object and some options, determines which users the given user
#      can switch to.  If the list exists, returns a select list and a submit
#      button with labels.  Otherwise returns a hidden element.
# returns: string of HTML elements
# args: u, opts?
# des-opts: Optional.  Valid keys are:
#           'authas' - current user, gets selected in drop-down;
#           'label' - label to go before form elements;
#           'button' - button label for submit button;
#           others - arguments to pass to [func[LJ::get_authas_list]].
# </LJFUNC>
sub make_authas_select {
    my ($u, $opts) = @_; # type, authas, label, button

    my @list = LJ::get_authas_list($u, $opts);

    # only do most of form if there are options to select from
    if (@list > 1 || $list[0] ne $u->{'user'}) {
        my $ret;
        my $label = $BML::ML{'web.authas.label'};
        $label = $BML::ML{'web.authas.label.comm'} if ($opts->{'type'} eq "C");
        $ret = ($opts->{'label'} || $label) . " ";
        $ret .= LJ::html_select({ 'name' => 'authas',
                                 'selected' => $opts->{'authas'} || $u->{'user'},
                                 'class' => 'hideable',
                                 },
                                 map { $_, $_ } @list) . " ";
        $ret .= LJ::html_submit(undef, $opts->{'button'} || $BML::ML{'web.authas.btn'});
        return $ret;
    }

    # no communities to choose from, give the caller a hidden
    return  LJ::html_hidden('authas', $opts->{'authas'} || $u->{'user'});
}

# <LJFUNC>
# name: LJ::make_postto_select
# des: Given a u object and some options, determines which users the given user
#      can post to.  If the list exists, returns a select list and a submit
#      button with labels.  Otherwise returns a hidden element.
# returns: string of HTML elements
# args: u, opts?
# des-opts: Optional.  Valid keys are:
#           'postto' - current user, gets selected in drop-down;
#           'label' - label to go before form elements;
#           'button' - button label for submit button;
#           others - arguments to pass to [func[LJ::get_postto_list]].
# </LJFUNC>
sub make_postto_select {
    my ($u, $opts) = @_; # type, authas, label, button

    my @list = LJ::get_postto_list($u, $opts);

    # only do most of form if there are options to select from
    if (@list > 1) {
        return ($opts->{'label'} || $BML::ML{'web.postto.label'}) . " " .
               LJ::html_select({ 'name' => 'authas',
                                 'selected' => $opts->{'authas'} || $u->{'user'}},
                                 map { $_, $_ } @list) . " " .
               LJ::html_submit(undef, $opts->{'button'} || $BML::ML{'web.postto.btn'});
    }

    # no communities to choose from, give the caller a hidden
    return  LJ::html_hidden('authas', $opts->{'authas'} || $u->{'user'});
}

# <LJFUNC>
# name: LJ::help_icon
# des: Returns BML to show a help link/icon given a help topic, or nothing
#      if the site hasn't defined a URL for that topic.  Optional arguments
#      include HTML/BML to place before and after the link/icon, should it
#      be returned.
# args: topic, pre?, post?
# des-topic: Help topic key.
#            See doc/ljconfig.pl.txt, or [special[helpurls]] for examples.
# des-pre: HTML/BML to place before the help icon.
# des-post: HTML/BML to place after the help icon.
# </LJFUNC>
sub help_icon
{
    my $topic = shift;
    my $pre = shift;
    my $post = shift;
    return "" unless (defined $LJ::HELPURL{$topic});
    return "$pre<?help $LJ::HELPURL{$topic} help?>$post";
}

# like help_icon, but no BML.
sub help_icon_html {
    my $topic = shift;
    my $url = $LJ::HELPURL{$topic} or return "";
    my $pre = shift || "";
    my $post = shift || "";
    # FIXME: use LJ::img() here, not hard-coding width/height
    return "$pre<a href=\"$url\" class=\"helplink\" target=\"_blank\"><img src=\"$LJ::IMGPREFIX/help.gif\" alt=\"Help\" title=\"Help\" width='14' height='14' border='0' /></a>$post";
}

# <LJFUNC>
# name: LJ::bad_input
# des: Returns common BML for reporting form validation errors in
#      a bulleted list.
# returns: BML showing errors.
# args: error*
# des-error: A list of errors
# </LJFUNC>
sub bad_input
{
    my @errors = @_;
    my $ret = "";
    $ret .= "<?badcontent?>\n<ul>\n";
    foreach my $ei (@errors) {
        my $err  = LJ::errobj($ei) or next;
        $err->log;
        $ret .= $err->as_bullets;
    }
    $ret .= "</ul>\n";
    return $ret;
}


# <LJFUNC>
# name: LJ::error_list
# des: Returns an error bar with bulleted list of errors.
# returns: BML showing errors.
# args: error*
# des-error: A list of errors
# </LJFUNC>
sub error_list
{
    # FIXME: retrofit like bad_input above?  merge?  make aliases for each other?
    my @errors = @_;
    my $ret;
    $ret .= "<?errorbar ";
    $ret .= "<strong>";
    $ret .= BML::ml('error.procrequest');
    $ret .= "</strong><ul>";

    foreach my $ei (@errors) {
        my $err  = LJ::errobj($ei) or next;
        $err->log;
        $ret .= $err->as_bullets;
    }
    $ret .= " </ul> errorbar?>";
    return $ret;
}


# <LJFUNC>
# name: LJ::error_noremote
# des: Returns an error telling the user to log in.
# returns: Translation string "error.notloggedin"
# </LJFUNC>
sub error_noremote
{
    return "<?needlogin?>";
}


# <LJFUNC>
# name: LJ::warning_list
# des: Returns a warning bar with bulleted list of warnings.
# returns: BML showing warnings
# args: warnings*
# des-warnings: A list of warnings
# </LJFUNC>
sub warning_list
{
    my @warnings = @_;
    my $ret;

    $ret .= "<?warningbar ";
    $ret .= "<strong>";
    $ret .= BML::ml('label.warning');
    $ret .= "</strong><ul>";

    foreach (@warnings) {
        $ret .= "<li>$_</li>";
    }
    $ret .= " </ul> warningbar?>";
    return $ret;
}

sub tosagree_widget {
    my ($checked, $errstr) = @_;

    return
        "<div class='formitemDesc'>" .
        BML::ml('tos.mustread',
                { aopts => "target='_new' href='$LJ::SITEROOT/legal/tos.bml'" }) .
        "</div>" .
        "<iframe width='684' height='300' src='/legal/tos-mini.bml' " .
        "style='border: 1px solid gray;'></iframe>" .
        "<div>" . LJ::html_check({ name => 'agree_tos', id => 'agree_tos',
                                   value => '1', selected =>  $checked }) .
        "<label for='agree_tos'>" . BML::ml('tos.haveread') . "</label></div>" .
        ($errstr ? "<?inerr $errstr inerr?>" : '');
}

sub tosagree_html {
    my $domain = shift;

    my $ret = "<?h1 $LJ::REQUIRED_TOS{title} h1?>";

    my $html_str = LJ::tosagree_str($domain => 'html');
    $ret .= "<?p $html_str p?>" if $html_str;

    $ret .= "<div style='margin-left: 40px; margin-bottom: 20px;'>";
    $ret .= LJ::tosagree_widget(@_);
    $ret .= "</div>";

    return $ret;
}

sub tosagree_str {
    my ($domain, $key) = @_;

    return ref $LJ::REQUIRED_TOS{$domain} && $LJ::REQUIRED_TOS{$domain}->{$key} ?
        $LJ::REQUIRED_TOS{$domain}->{$key} : $LJ::REQUIRED_TOS{$key};
}

# <LJFUNC>
# name: LJ::did_post
# des: Cookies should only show pages which make no action.
#      When an action is being made, check the request coming
#      from the remote user is a POST request.
# info: When web pages are using cookie authentication, you can't just trust that
#       the remote user wants to do the action they're requesting.  It's way too
#       easy for people to force other people into making GET requests to
#       a server.  What if a user requested http://server/delete_all_journal.bml,
#       and that URL checked the remote user and immediately deleted the whole
#       journal?  Now anybody has to do is embed that address in an image
#       tag and a lot of people's journals will be deleted without them knowing.
#       Cookies should only show pages which make no action.  When an action is
#       being made, check that it's a POST request.
# returns: true if REQUEST_METHOD == "POST"
# </LJFUNC>
sub did_post
{
    return (BML::get_method() eq "POST");
}

# <LJFUNC>
# name: LJ::robot_meta_tags
# des: Returns meta tags to instruct a robot/crawler to not index or follow links.
# returns: A string with appropriate meta tags
# </LJFUNC>
sub robot_meta_tags
{
    return "<meta name=\"robots\" content=\"noindex, nofollow, noarchive\" />\n" .
           "<meta name=\"googlebot\" content=\"noindex, nofollow, noarchive, nosnippet\" />\n";
}

sub paging_bar
{
    my ($page, $pages, $opts) = @_;

    my $self_link = $opts->{'self_link'} ||
                    sub { BML::self_link({ 'page' => $_[0] }) };

    my $navcrap;
    if ($pages > 1) {
        $navcrap .= "<center><font face='Arial,Helvetica' size='-1'><b>";
        $navcrap .= BML::ml('ljlib.pageofpages',{'page'=>$page, 'total'=>$pages}) . "<br />";
        my $left = "<b>&lt;&lt;</b>";
        if ($page > 1) { $left = "<a href='" . $self_link->($page-1) . "'>$left</a>"; }
        my $right = "<b>&gt;&gt;</b>";
        if ($page < $pages) { $right = "<a href='" . $self_link->($page+1) . "'>$right</a>"; }
        $navcrap .= $left . " ";
        for (my $i=1; $i<=$pages; $i++) {
            my $link = "[$i]";
            if ($i != $page) { $link = "<a href='" . $self_link->($i) . "'>$link</a>"; }
            else { $link = "<font size='+1'><b>$link</b></font>"; }
            $navcrap .= "$link ";
        }
        $navcrap .= "$right";
        $navcrap .= "</font></center>\n";
        $navcrap = BML::fill_template("standout", { 'DATA' => $navcrap });
    }
    return $navcrap;
}

# <LJFUNC>
# class: web
# name: LJ::make_cookie
# des: Prepares cookie header lines.
# returns: An array of cookie lines.
# args: name, value, expires, path?, domain?
# des-name: The name of the cookie.
# des-value: The value to set the cookie to.
# des-expires: The time (in seconds) when the cookie is supposed to expire.
#              Set this to 0 to expire when the browser closes. Set it to
#              undef to delete the cookie.
# des-path: The directory path to bind the cookie to.
# des-domain: The domain (or domains) to bind the cookie to.
# </LJFUNC>
sub make_cookie
{
    my ($name, $value, $expires, $path, $domain) = @_;
    my $cookie = "";
    my @cookies = ();

    # let the domain argument be an array ref, so callers can set
    # cookies in both .foo.com and foo.com, for some broken old browsers.
    if ($domain && ref $domain eq "ARRAY") {
        foreach (@$domain) {
            push(@cookies, LJ::make_cookie($name, $value, $expires, $path, $_));
        }
        return;
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($expires);
    $year+=1900;

    my @day = qw{Sunday Monday Tuesday Wednesday Thursday Friday Saturday};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};

    $cookie = sprintf "%s=%s", LJ::eurl($name), LJ::eurl($value);

    # this logic is confusing potentially
    unless (defined $expires && $expires==0) {
        $cookie .= sprintf "; expires=$day[$wday], %02d-$month[$mon]-%04d %02d:%02d:%02d GMT",
                $mday, $year, $hour, $min, $sec;
    }

    $cookie .= "; path=$path" if $path;
    $cookie .= "; domain=$domain" if $domain;
    push(@cookies, $cookie);
    return @cookies;
}

sub set_active_crumb
{
    $LJ::ACTIVE_CRUMB = shift;
    return undef;
}

sub set_dynamic_crumb
{
    my ($title, $parent) = @_;
    $LJ::ACTIVE_CRUMB = [ $title, $parent ];
}

sub get_parent_crumb
{
    my $thiscrumb = LJ::get_crumb(LJ::get_active_crumb());
    return LJ::get_crumb($thiscrumb->[2]);
}

sub get_active_crumb
{
    return $LJ::ACTIVE_CRUMB;
}

sub get_crumb_path
{
    my $cur = LJ::get_active_crumb();
    my @list;
    while ($cur) {
        # get crumb, fix it up, and then put it on the list
        if (ref $cur) {
            # dynamic crumb
            push @list, [ $cur->[0], '', $cur->[1], 'dynamic' ];
            $cur = $cur->[1];
        } else {
            # just a regular crumb
            my $crumb = LJ::get_crumb($cur);
            last unless $crumb;
            last if $cur eq $crumb->[2];
            $crumb->[3] = $cur;
            push @list, $crumb;

            # now get the next one we're going after
            $cur = $crumb->[2]; # parent of this crumb
        }
    }
    return @list;
}

sub get_crumb
{
    my $crumbkey = shift;
    if (defined $LJ::CRUMBS_LOCAL{$crumbkey}) {
        return $LJ::CRUMBS_LOCAL{$crumbkey};
    } else {
        return $LJ::CRUMBS{$crumbkey};
    }
}

# <LJFUNC>
# name: LJ::check_referer
# class: web
# des: Checks if the user is coming from a given URI.
# args: uri?, referer?
# des-uri: string; the URI we want the user to come from.
# des-referer: string; the location the user is posting from.
#              If not supplied, will be retrieved with BML::get_client_header.
#              In general, you don't want to pass this yourself unless
#              you already have it or know we can't get it from BML.
# returns: 1 if they're coming from that URI, else undef
# </LJFUNC>
sub check_referer {
    my $uri = shift(@_) || '';
    my $referer = shift(@_) || BML::get_client_header('Referer');

    # get referer and check
    return 1 unless $referer;
    return 1 if $LJ::SITEROOT   && $referer =~ m!^$LJ::SITEROOT$uri!;
    return 1 if $LJ::DOMAIN     && $referer =~ m!^http://$LJ::DOMAIN$uri!;
    return 1 if $LJ::DOMAIN_WEB && $referer =~ m!^http://$LJ::DOMAIN_WEB$uri!;
    return 1 if $uri =~ m!^http://! && $referer eq $uri;
    return undef;
}

# <LJFUNC>
# name: LJ::form_auth
# class: web
# des: Creates an authentication token to be used later to verify that a form
#      submission came from a particular user.
# args: raw?
# des-raw: boolean; If true, returns only the token (no HTML).
# returns: HTML hidden field to be inserted into the output of a page.
# </LJFUNC>
sub form_auth {
    my $raw = shift;
    my $chal = $LJ::REQ_GLOBAL{form_auth_chal};

    unless ($chal) {
        my $remote = LJ::get_remote();
        my $id     = $remote ? $remote->id : 0;
        my $sess   = $remote && $remote->session ? $remote->session->id : LJ::UniqCookie->current_uniq;

        my $auth = join('-', LJ::rand_chars(10), $id, $sess);
        $chal = LJ::challenge_generate(86400, $auth);
        $LJ::REQ_GLOBAL{form_auth_chal} = $chal;
    }

    return $raw ? $chal : LJ::html_hidden("lj_form_auth", $chal);
}

# <LJFUNC>
# name: LJ::check_form_auth
# class: web
# des: Verifies form authentication created with [func[LJ::form_auth]].
# returns: Boolean; true if the current data in %POST is a valid form, submitted
#          by the user in $remote using the current session,
#          or false if the user has changed, the challenge has expired,
#          or the user has changed session (logged out and in again, or something).
# </LJFUNC>
sub check_form_auth {
    my $formauth = shift || $BMLCodeBlock::POST{'lj_form_auth'};
    return 0 unless $formauth;

    my $remote = LJ::get_remote();
    my $id     = $remote ? $remote->id : 0;
    my $sess   = $remote && $remote->session ? $remote->session->id : LJ::UniqCookie->current_uniq;

    # check the attributes are as they should be
    my $attr = LJ::get_challenge_attributes($formauth);
    my ($randchars, $chal_id, $chal_sess) = split(/\-/, $attr);

    return 0 unless $id   == $chal_id;
    return 0 unless $sess eq $chal_sess;

    # check the signature is good and not expired
    my $opts = { dont_check_count => 1 };  # in/out
    LJ::challenge_check($formauth, $opts);
    return $opts->{valid} && ! $opts->{expired};
}

# <LJFUNC>
# name: LJ::create_qr_div
# class: web
# des: Creates the hidden div that stores the QuickReply form.
# returns: undef upon failure or HTML for the div upon success
# args: user, remote, ditemid, stylemine, userpic.
# des-u: user object or userid for journal reply in.
# des-ditemid: ditemid for this comment.
# des-stylemine: if the user has specified style=mine for this page.
# des-userpic: alternate default userpic.
# </LJFUNC>
sub create_qr_div {

    my ($user, $ditemid, $stylemine, $userpic, $viewing_thread) = @_;
    my $u = LJ::want_user($user);
    my $remote = LJ::get_remote();
    return undef unless $u && $remote && $ditemid;
    return undef if $remote->underage;

    $stylemine ||= 0;
    my $qrhtml;

    LJ::load_user_props($remote, "opt_no_quickreply");
    return undef if $remote->{'opt_no_quickreply'};

    $qrhtml .= "<div id='qrformdiv'><form id='qrform' name='qrform' method='POST' action='$LJ::SITEROOT/talkpost_do.bml'>";
    $qrhtml .= LJ::form_auth();

    my $stylemineuri = $stylemine ? "style=mine&" : "";
    my $basepath =  LJ::journal_base($u) . "/$ditemid.html?${stylemineuri}";
    $qrhtml .= LJ::html_hidden({'name' => 'replyto', 'id' => 'replyto', 'value' => ''},
                               {'name' => 'parenttalkid', 'id' => 'parenttalkid', 'value' => ''},
                               {'name' => 'journal', 'id' => 'journal', 'value' => $u->{'user'}},
                               {'name' => 'itemid', 'id' => 'itemid', 'value' => $ditemid},
                               {'name' => 'usertype', 'id' => 'usertype', 'value' => 'cookieuser'},
                               {'name' => 'userpost', 'id' => 'userpost', 'value' => $remote->{'user'}},
                               {'name' => 'qr', 'id' => 'qr', 'value' => '1'},
                               {'name' => 'cookieuser', 'id' => 'cookieuser', 'value' => $remote->{'user'}},
                               {'name' => 'dtid', 'id' => 'dtid', 'value' => ''},
                               {'name' => 'basepath', 'id' => 'basepath', 'value' => $basepath},
                               {'name' => 'stylemine', 'id' => 'stylemine', 'value' => $stylemine},
                               {'name' => 'viewing_thread', 'id' => 'viewing_thread', 'value' => $viewing_thread},
                               );

    # rate limiting challenge
    {
        my ($time, $secret) = LJ::get_secret();
        my $rchars = LJ::rand_chars(20);
        my $chal = $ditemid . "-$u->{userid}-$time-$rchars";
        my $res = Digest::MD5::md5_hex($secret . $chal);
        $qrhtml .= LJ::html_hidden("chrp1", "$chal-$res");
    }

    # Start making the div itself
    $qrhtml .= "<table style='border: 1px solid black'>";
    $qrhtml .= "<tr valign='center'>";
    $qrhtml .= "<td align='right'><b>".BML::ml('/talkpost.bml.opt.from')."</b></td><td align='left'>";
    $qrhtml .= LJ::ljuser($remote->{'user'});
    $qrhtml .= "</td><td align='center'>";

    # Userpic selector
    {
        my %res;
        LJ::do_request({ "mode" => "login",
                         "ver" => ($LJ::UNICODE ? "1" : "0"),
                         "user" => $remote->{'user'},
                         "getpickws" => 1, },
                       \%res, { "noauth" => 1, "userid" => $remote->{'userid'}}
                       );

        if ($res{'pickw_count'}) {
            $qrhtml .= BML::ml('/talkpost.bml.label.picturetouse2',
                               {
                                   'aopts'=>"href='$LJ::SITEROOT/allpics.bml?user=$remote->{'user'}'"});
            my @pics;
            for (my $i=1; $i<=$res{'pickw_count'}; $i++) {
                push @pics, $res{"pickw_$i"};
            }
            @pics = sort { lc($a) cmp lc($b) } @pics;
            $qrhtml .= LJ::html_select({'name' => 'prop_picture_keyword',
                                        'selected' => $userpic, 'id' => 'prop_picture_keyword' },
                                       ("", BML::ml('/talkpost.bml.opt.defpic'), map { ($_, $_) } @pics));

            # userpic browse button
            $qrhtml .= qq {
                <input type="button" id="lj_userpicselect" value="Browse" />
                } unless $LJ::DISABLED{userpicselect} || ! $remote->get_cap('userpicselect');

            $qrhtml .= LJ::help_icon_html("userpics", " ");
        }
    }

    $qrhtml .= "</td></tr>";

    $qrhtml .= "<tr><td align='right'>";
    $qrhtml .= "<b>".BML::ml('/talkpost.bml.opt.subject')."</b></td>";
    $qrhtml .= "<td colspan='2' align='left'>";
    $qrhtml .= "<input class='textbox' type='text' size='50' maxlength='100' name='subject' id='subject' value='' />";
    $qrhtml .= "</td></tr>";

    $qrhtml .= "<tr valign='top'>";
    $qrhtml .= "<td align='right'><b>".BML::ml('/talkpost.bml.opt.message')."</b></td>";
    $qrhtml .= "<td colspan='3' style='width: 90%'>";

    $qrhtml .= "<textarea class='textbox' rows='10' cols='50' wrap='soft' name='body' id='body' style='width: 99%'></textarea>";
    $qrhtml .= "</td></tr>";

    $qrhtml .= "<tr><td>&nbsp;</td>";
    $qrhtml .= "<td colspan='3' align='left'>";

    $qrhtml .= LJ::html_submit('submitpost', BML::ml('/talkread.bml.button.post'),
                               { 'id' => 'submitpost',
                                 'raw' => 'onclick="if (checkLength()) {submitform();}"'
                                 });

    $qrhtml .= "&nbsp;" . LJ::html_submit('submitmoreopts', BML::ml('/talkread.bml.button.more'),
                                          { 'id' => 'submitmoreopts',
                                            'raw' => 'onclick="if (moreopts()) {submitform();}"'
                                            });
    if ($LJ::SPELLER) {
        $qrhtml .= "&nbsp;<input type='checkbox' name='do_spellcheck' value='1' id='do_spellcheck' /> <label for='do_spellcheck'>";
        $qrhtml .= BML::ml('/talkread.bml.qr.spellcheck');
        $qrhtml .= "</label>";
    }

    LJ::load_user_props($u, 'opt_logcommentips');
    if ($u->{'opt_logcommentips'} eq 'A') {
        $qrhtml .= '<br />';
        $qrhtml .= LJ::deemp(BML::ml('/talkpost.bml.logyourip'));
        $qrhtml .= LJ::help_icon_html("iplogging", " ");
    }

    $qrhtml .= "</td></tr></table>";
    $qrhtml .= "</form></div>";

    my $ret;
    $ret = "<script language='JavaScript'>\n";

    $qrhtml = LJ::ejs($qrhtml);

    # here we create some separate fields for saving the quickreply entry
    # because the browser will not save to a dynamically-created form.

    my $qrsaveform .= LJ::ejs(LJ::html_hidden(
                                      {'name' => 'saved_subject', 'id' => 'saved_subject'},
                                      {'name' => 'saved_body', 'id' => 'saved_body'},
                                      {'name' => 'saved_spell', 'id' => 'saved_spell'},
                                      {'name' => 'saved_upic', 'id' => 'saved_upic'},
                                      {'name' => 'saved_dtid', 'id' => 'saved_dtid'},
                                      {'name' => 'saved_ptid', 'id' => 'saved_ptid'},
                                      ));

    $ret .= qq{
               var de;
               if (document.createElement && document.body.insertBefore && !(xMac && xIE4Up)) {
                   document.write("$qrsaveform");
                   de = document.createElement("div");

                   if (de) {
                       de.id = "qrdiv";
                       de.innerHTML = "$qrhtml";
                       var bodye = document.getElementsByTagName("body");
                       if (bodye[0])
                           bodye[0].insertBefore(de, bodye[0].firstChild);
                       de.style.display = 'none';
                   }
               }
           };

    $ret .= "\n</script>";

    $ret .= qq {
        <script type="text/javascript" language="JavaScript">
            DOM.addEventListener(window, "load", function (evt) {
                // attach userpicselect code to userpicbrowse button
                var ups_btn = \$("lj_userpicselect");
                if (ups_btn) {
                    DOM.addEventListener(ups_btn, "click", function (evt) {
                     var ups = new UserpicSelect();
                     ups.init();
                     ups.setPicSelectedCallback(function (picid, keywords) {
                         var kws_dropdown = \$("prop_picture_keyword");

                         if (kws_dropdown) {
                             var items = kws_dropdown.options;

                             // select the keyword in the dropdown
                             keywords.forEach(function (kw) {
                                 for (var i = 0; i < items.length; i++) {
                                     var item = items[i];
                                     if (item.value == kw) {
                                         kws_dropdown.selectedIndex = i;
                                         return;
                                     }
                                 }
                             });
                         }
                     });
                     ups.show();
                 });
                }
            });
        </script>
        } unless $LJ::DISABLED{userpicselect} || ! $remote->get_cap('userpicselect');

    return $ret;
}

# <LJFUNC>
# name: LJ::make_qr_link
# class: web
# des: Creates the link to toggle the QR reply form or if
#      JavaScript is not enabled, then forwards the user through
#      to replyurl.
# returns: undef upon failure or HTML for the link
# args: dtid, basesubject, linktext, replyurl
# des-dtid: dtalkid for this comment
# des-basesubject: parent comment's subject
# des-linktext: text for the user to click
# des-replyurl: URL to forward user to if their browser
#               does not support QR.
# </LJFUNC>
sub make_qr_link
{
    my ($dtid, $basesubject, $linktext, $replyurl) = @_;

    return undef unless defined $dtid && $linktext && $replyurl;

    my $remote = LJ::get_remote();
    LJ::load_user_props($remote, "opt_no_quickreply");
    unless ($remote->{'opt_no_quickreply'}) {
        my $pid = int($dtid / 256);

        $basesubject =~ s/^(Re:\s*)*//i;
        $basesubject = "Re: $basesubject" if $basesubject;
        $basesubject = LJ::ehtml(LJ::ejs($basesubject));
        my $onclick = "return quickreply(\"$dtid\", $pid, \"$basesubject\")";
        return "<a onclick='$onclick' href='$replyurl' >$linktext</a>";
    } else { # QR Disabled
        return "<a href='$replyurl' >$linktext</a>";
    }
}

# <LJFUNC>
# name: LJ::get_lastcomment
# class: web
# des: Looks up the last talkid and journal the remote user posted in.
# returns: talkid, jid
# args:
# </LJFUNC>
sub get_lastcomment {
    my $remote = LJ::get_remote();
    return (undef, undef) unless $remote;

    # Figure out their last post
    my $memkey = [$remote->{'userid'}, "lastcomm:$remote->{'userid'}"];
    my $memval = LJ::MemCache::get($memkey);
    my ($jid, $talkid) = split(/:/, $memval) if $memval;

    return ($talkid, $jid);
}

# <LJFUNC>
# name: LJ::make_qr_target
# class: web
# des: Returns a div usable for QuickReply boxes.
# returns: HTML for the div
# args:
# </LJFUNC>
sub make_qr_target {
    my $name = shift;

    return "<div id='ljqrt$name' name='ljqrt$name'></div>";
}

# <LJFUNC>
# name: LJ::set_lastcomment
# class: web
# des: Sets the lastcomm memcached key for this user's last comment.
# returns: undef on failure
# args: u, remote, dtalkid, life?
# des-u: Journal they just posted in, either u or userid
# des-remote: Remote user
# des-dtalkid: Talkid for the comment they just posted
# des-life: How long, in seconds, the memcached key should live.
# </LJFUNC>
sub set_lastcomment
{
    my ($u, $remote, $dtalkid, $life) = @_;

    my $userid = LJ::want_userid($u);
    return undef unless $userid && $remote && $dtalkid;

    # By default, this key lasts for 10 seconds.
    $life ||= 10;

    # Set memcache key for highlighting the comment
    my $memkey = [$remote->{'userid'}, "lastcomm:$remote->{'userid'}"];
    LJ::MemCache::set($memkey, "$userid:$dtalkid", time()+$life);

    return;
}

sub deemp {
    "<span class='de'>$_[0]</span>";
}

# <LJFUNC>
# name: LJ::entry_form
# class: web
# des: Returns a properly formatted form for creating/editing entries.
# args: head, onload, opts
# des-head: string reference for the <head> section (JavaScript previews, etc).
# des-onload: string reference for JavaScript functions to be called on page load
# des-opts: hashref of keys/values:
#           mode: either "update" or "edit", depending on context;
#           datetime: date and time, formatted yyyy-mm-dd hh:mm;
#           remote: remote u object;
#           subject: entry subject;
#           event: entry text;
#           richtext: allow rich text formatting;
#           auth_as_remote: bool option to authenticate as remote user, pre-filling pic/friend groups/etc.
# return: form to include in BML pages.
# </LJFUNC>
sub entry_form {
    my ($opts, $head, $onload, $errors) = @_;

    my $out = "";
    my $remote = $opts->{'remote'};
    my ($moodlist, $moodpics, $userpics);

    # usejournal has no point if you're trying to use the account you're logged in as,
    # so disregard it so we can assume that if it exists, we're trying to post to an
    # account that isn't us
    if ($remote && $opts->{usejournal} && $remote->{user} eq $opts->{usejournal}) {
        delete $opts->{usejournal};
    }

    $opts->{'richtext'} = $opts->{'richtext_default'};
    my $tabnum = 10; #make allowance for username and password
    my $tabindex = sub { return $tabnum++; };
    $opts->{'event'} = LJ::durl($opts->{'event'}) if $opts->{'mode'} eq "edit";

    # 1 hour auth token, should be adequate
    my $chal = LJ::challenge_generate(3600);
    $out .= "\n\n<div id='entry-form-wrapper'>";
    $out .= "\n<input type='hidden' name='chal' id='login_chal' value='$chal' />\n";
    $out .= "<input type='hidden' name='response' id='login_response' value='' />\n\n";
    $out .= LJ::error_list($errors->{entry}) if $errors->{entry};
    # do a login action to get pics and usejournals, but only if using remote
    my $res;
    if ($opts->{'auth_as_remote'}) {
        $res = LJ::Protocol::do_request("login", {
            "ver" => $LJ::PROTOCOL_VER,
            "username" => $remote->{'user'},
            "getpickws" => 1,
            "getpickwurls" => 1,
        }, undef, {
            "noauth" => 1,
            "u" => $remote,
        });
    }

    ### Userpic

        my $userpic_preview = "";

            # User Picture
            if ($res && ref $res->{'pickws'} eq 'ARRAY' && scalar @{$res->{'pickws'}} > 0) {
                my @pickws = map { ($_, $_) } @{$res->{'pickws'}};
                my $num = 0;
                $userpics .= "    userpics[$num] = \"$res->{'defaultpicurl'}\";\n";
                foreach (@{$res->{'pickwurls'}}) {
                    $num++;
                    $userpics .= "    userpics[$num] = \"$_\";\n";
                }
                $$onload .= " userpic_preview();";

                my $userpic_link_text;
                $userpic_link_text = BML::ml('entryform.userpic.choose') if $remote;

                $$head .= qq {
                    <script type="text/javascript" language="JavaScript"><!--
                        if (document.getElementById) {
                            var userpics = new Array();
                            $userpics
                            function userpic_preview() {
                                if (! document.getElementById) return false;
                                var userpic_select          = document.getElementById('prop_picture_keyword');

                                if (\$('userpic') && \$('userpic').style.display == 'none') {
                                    \$('userpic').style.display = 'block';
                                }
                                var userpic_msg;
                                if (userpics[0] == "") { userpic_msg = 'Choose default userpic' }
                                if (userpics.length == 0) { userpic_msg = 'Upload a userpic' }

                                if (userpic_select && userpics[userpic_select.selectedIndex] != "") {
                                    \$('userpic_preview').className = '';
                                    var userpic_preview_image = \$('userpic_preview_image');
                                    userpic_preview_image.style.display = 'block';
                                    if (\$('userpic_msg')) {
                                        \$('userpic_msg').style.display = 'none';
                                    }
                                    userpic_preview_image.src = userpics[userpic_select.selectedIndex];
                                } else {
                                    userpic_preview.className += " userpic_preview_border";
                                    userpic_preview.innerHTML = '<a href="$LJ::SITEROOT/editpics.bml"><img src="" alt="selected userpic" id="userpic_preview_image" style="display: none;" /><span id="userpic_msg">' + userpic_msg + '</span></a>';
                                }
                            }
                        }
                    //--></script>
                    };

                $$head .= qq {
                    <script type="text/javascript" language="JavaScript">
                    // <![CDATA[
                        DOM.addEventListener(window, "load", function (evt) {
                        // attach userpicselect code to userpicbrowse button
                            var ups_btn = \$("lj_userpicselect");
                            var ups_btn_img = \$("lj_userpicselect_img");
                        if (ups_btn) {
                            DOM.addEventListener(ups_btn, "click", function (evt) {
                                var ups = new UserpicSelect();
                                ups.init();
                                ups.setPicSelectedCallback(function (picid, keywords) {
                                    var kws_dropdown = \$("prop_picture_keyword");

                                    if (kws_dropdown) {
                                        var items = kws_dropdown.options;

                                        // select the keyword in the dropdown
                                        keywords.forEach(function (kw) {
                                            for (var i = 0; i < items.length; i++) {
                                                var item = items[i];
                                                if (item.value == kw) {
                                                    kws_dropdown.selectedIndex = i;
                                                    userpic_preview();
                                                    return;
                                                }
                                            }
                                        });
                                    }
                                });
                                ups.show();
                            });
                        }
                        if (ups_btn_img) {
                            DOM.addEventListener(ups_btn_img, "click", function (evt) {
                                var ups = new UserpicSelect();
                                ups.init();
                                ups.setPicSelectedCallback(function (picid, keywords) {
                                    var kws_dropdown = \$("prop_picture_keyword");

                                    if (kws_dropdown) {
                                        var items = kws_dropdown.options;

                                        // select the keyword in the dropdown
                                        keywords.forEach(function (kw) {
                                            for (var i = 0; i < items.length; i++) {
                                                var item = items[i];
                                                if (item.value == kw) {
                                                    kws_dropdown.selectedIndex = i;
                                                    userpic_preview();
                                                    return;
                                                }
                                            }
                                        });
                                    }
                                });
                                ups.show();
                            });
                            DOM.addEventListener(ups_btn_img, "mouseover", function (evt) {
                                var msg = \$("lj_userpicselect_img_txt");
                                msg.style.display = 'block';
                            });
                            DOM.addEventListener(ups_btn_img, "mouseout", function (evt) {
                                var msg = \$("lj_userpicselect_img_txt");
                                msg.style.display = 'none';
                            });
                        }
                    });
                    // ]]>
                    </script>
                } unless $LJ::DISABLED{userpicselect} || ! $remote->get_cap('userpicselect');

                # libs for userpicselect
                LJ::need_res(qw(
                                js/core.js
                                js/dom.js
                                js/json.js
                                js/template.js
                                js/ippu.js
                                js/lj_ippu.js
                                js/userpicselect.js
                                js/httpreq.js
                                js/hourglass.js
                                js/inputcomplete.js
                                stc/ups.css
                                js/datasource.js
                                js/selectable_table.js
                                )) if ! $LJ::DISABLED{userpicselect} && $remote->get_cap('userpicselect');

                $out .= "<div id='userpic' style='display: none;'><p id='userpic_preview'><a href='javascript:void(0);' id='lj_userpicselect_img'><img src='' alt='selected userpic' id='userpic_preview_image' /><span id='lj_userpicselect_img_txt'>$userpic_link_text</span></a></p></div>";
                $out .= "\n";

            } elsif (!$remote)  {
                $out .= "<div id='userpic'><p id='userpic_preview'><img src='/img/userpic_loggedout.gif' alt='selected userpic' id='userpic_preview_image' class='userpic_loggedout'  /></p></div>";
            } else {
                $out .= "<div id='userpic'><p id='userpic_preview' class='userpic_preview_border'><a href='$LJ::SITEROOT/editpics.bml'>Upload a userpic</a></p></div>";
            }


    ### Meta Information Column 1
    {
        $out .= "<div id='metainfo'>\n\n";
        # login info
        $out .= $opts->{'auth'};
        if ($opts->{'mode'} eq "update") {
            # communities the user can post in
            my $usejournal = $opts->{'usejournal'};
            if ($usejournal) {
                $out .= "<p id='usejournal_list' class='pkg'>\n";
                $out .= "<label for='usejournal' class='left'>" . BML::ml('entryform.postto') . "</label>\n";
                $out .= LJ::ljuser($usejournal);
                $out .= LJ::html_hidden('usejournal' => $usejournal, 'usejournal_set' => 'true');
                $out .= "</p>\n";
            } elsif ($res && ref $res->{'usejournals'} eq 'ARRAY') {
                my $submitprefix = BML::ml('entryform.update3');
                $out .= "<p id='usejournal_list' class='pkg'>\n";
                $out .= "<label for='usejournal' class='left'>" . BML::ml('entryform.postto') . "</label>\n";
                $out .= LJ::html_select({ 'name' => 'usejournal', 'id' => 'usejournal', 'selected' => $usejournal,
                                    'tabindex' => $tabindex->(), 'class' => 'select',
                                    "onchange" => "changeSubmit('".$submitprefix."','".$remote->{'user'}."'); getUserTags('$remote->{user}');" },
                                    "", $remote->{'user'},
                                    map { $_, $_ } @{$res->{'usejournals'}}) . "\n";
                $out .= "</p>\n";
            }
        }

        # Authentication box
        $out .= "<p class='update-errors'><?inerr $errors->{'auth'} inerr?></p>\n" if $errors->{'auth'};

        # Date / Time
        {
            my ($year, $mon, $mday, $hour, $min) = split( /\D/, $opts->{'datetime'});
            my $monthlong = LJ::Lang::month_long($mon);
            # date entry boxes / formatting note
            my $datetime = LJ::html_datetime({ 'name' => "date_ymd", 'notime' => 1, 'default' => "$year-$mon-$mday", 'disabled' => $opts->{'disabled_save'}});
            $datetime .= "<span class='float-left'>&nbsp;&nbsp;</span>";
            $datetime .=   LJ::html_text({ size => 2, class => 'text', maxlength => 2, value => $hour, name => "hour", tabindex => $tabindex->(), disabled => $opts->{'disabled_save'} }) . "<span class='float-left'>:</span>";
            $datetime .=   LJ::html_text({ size => 2, class => 'text', maxlength => 2, value => $min, name => "min", tabindex => $tabindex->(), disabled => $opts->{'disabled_save'} });

            # JavaScript sets this value, so we know that the time we get is correct
            # but always trust the time if we've been through the form already
            my $date_diff = ($opts->{'mode'} eq "edit" || $opts->{'spellcheck_html'}) ? 1 : 0;
            $datetime .= LJ::html_hidden("date_diff", $date_diff);

            # but if we don't have JS, give a signal to trust the given time
            $datetime .= "<noscript>" .  LJ::html_hidden("date_diff_nojs", "1") . "</noscript>";

            $out .= "<p class='pkg'>\n";
            $out .= "<label for='modifydate' class='left'>" . BML::ml('entryform.date') . "</label>\n";
            $out .= "<span id='currentdate' class='float-left'><span id='currentdate-date'>$monthlong $mday, $year, $hour" . ":" . "$min</span> <a href='javascript:void(0)' onclick='editdate();' id='currentdate-edit'>" . BML::ml('entryform.date.edit') . "</a></span>\n";
            $out .= "<span id='modifydate'>$datetime <?de " . BML::ml('entryform.date.24hournote') . " de?><br />\n";
            $out .= LJ::html_check({ 'type' => "check", 'id' => "prop_opt_backdated",
                    'name' => "prop_opt_backdated", "value" => 1,
                    'selected' => $opts->{'prop_opt_backdated'},
                    'tabindex' => $tabindex->() });
            $out .= "<label for='prop_opt_backdated' class='right'>" . BML::ml('entryform.backdated3') . "</label>\n";
            $out .= LJ::help_icon_html("backdate", "", "") . "\n";
            $out .= "</span><!-- end #modifydate -->\n";
            $out .= "</p>\n";
            $out .= "<noscript><p id='time-correct' class='small'>" . BML::ml('entryform.nojstime.note') . "</p></noscript>\n";
            $$onload .= " defaultDate();";
        }

            # User Picture
            if ($res && ref $res->{'pickws'} eq 'ARRAY' && scalar @{$res->{'pickws'}} > 0) {
                my @pickws = map { ($_, $_) } @{$res->{'pickws'}};
                my $num = 0;
                $userpics .= "    userpics[$num] = \"$res->{'defaultpicurl'}\";\n";
                foreach (@{$res->{'pickwurls'}}) {
                    $num++;
                    $userpics .= "    userpics[$num] = \"$_\";\n";
                }
                $out .= "<p id='userpic_select_wrapper' class='pkg'>\n";
                $out .= "<label for='prop_picture_keyword' class='left'>" . BML::ml('entryform.userpic') . "</label>\n" ;
                $out .= LJ::html_select({'name' => 'prop_picture_keyword', 'id' => 'prop_picture_keyword', 'class' => 'select',
                                         'selected' => $opts->{'prop_picture_keyword'}, 'onchange' => "userpic_preview()",
                                         'tabindex' => $tabindex->() },
                                        "", BML::ml('entryform.opt.defpic'),
                                        @pickws) . "\n";
                $out .= "<a href='javascript:void(0);' id='lj_userpicselect'> </a>";
                # userpic browse button
                $$onload .= " insertViewThumbs();" if ! $LJ::DISABLED{userpicselect} && $remote->get_cap('userpicselect');
                $out .= LJ::help_icon_html("userpics", "", " ") . "\n";
                $out .= "</p>\n\n";

            }

        $out .= "</div><!-- end #metainfo -->\n\n";


        ### Other Posting Options
        {
        $out .= "<div id='infobox'>\n";
        $out .= LJ::run_hook('entryforminfo', $opts->{'usejournal'}, $opts->{'remote'});
        $out .= "</div><!-- end #infobox -->\n\n";
        }

        ### Subject
        $out .= "<div id='entry' class='pkg'>\n";

        if ($opts->{prop_qotdid} && !$opts->{richtext}) {
            my $qotd = LJ::QotD->get_single_question($opts->{prop_qotdid});
            $out .= "<div style='margin-bottom: 10px;' id='qotd_html_preview'>" . LJ::Widget::QotD->qotd_display_embed( questions => [ $qotd ], no_answer_link => 1 ) . "</div>";
        }

        $out .= "<label class='left' for='subject'>" . BML::ml('entryform.subject') . "</label>\n";
        $out .= LJ::html_text({ 'name' => 'subject', 'value' => $opts->{'subject'},
                                'class' => 'text', 'id' => 'subject', 'size' => '43', 'maxlength' => '100',
                                'tabindex' => $tabindex->(),
                                'disabled' => $opts->{'disabled_save'}}) . "\n";
        $out .= "<ul id='entry-tabs' style='display: none;'>\n";
        $out .= "<li id='jrich'>" . BML::ml("entryform.htmlokay.rich4", { 'opts' => 'href="javascript:void(0);" onclick="return useRichText(\'draft\', \'' . $LJ::WSTATPREFIX. '\');"' })  . "</li>\n";
        $out .= "<li id='jplain' class='on'>" . BML::ml("entryform.plainswitch2", { 'aopts' => 'href="javascript:void(0);" onclick="return usePlainText(\'draft\');"' }) . "</li>\n";
        $out .= "</ul>";
        $out .= "</div><!-- end #entry -->\n\n";
        $$onload .= " showEntryTabs();";
        }

        ### Display Spell Check Results:
        $out .= "<div id='spellcheck-results'><strong>" . BML::ml('entryform.spellchecked') . "</strong><br />$opts->{'spellcheck_html'}</div>\n"
            if $opts->{'spellcheck_html'};

    ### Insert Object Toolbar:
    LJ::need_res(qw(
                    js/core.js
                    js/dom.js
                    js/ippu.js
                    js/lj_ippu.js
                    ));
    $out .= "<div id='htmltools' class='pkg'>\n";
    $out .= "<ul class='pkg'>\n";
    $out .= "<li class='image'><a href='javascript:void(0);' onclick='InOb.handleInsertImage();' title='"
        . BML::ml('fckland.ljimage') . "'>" . BML::ml('entryform.insert.image2') . "</a></li>\n";
    $out .= "<li class='media'><a href='javascript:void(0);' onclick='InOb.handleInsertEmbed();' title='Embed Media'>"
        . "Embed Media</a></li>\n" unless $LJ::DISABLED{embed_module};
    $out .= "</ul>\n";
    my $format_selected = $opts->{'prop_opt_preformatted'} || $opts->{'event_format'} ? "checked='checked'" : "";
    $out .= "<span id='linebreaks'><input type='checkbox' class='check' value='preformatted' name='event_format' id='event_format' $format_selected  />
            <label for='event_format'>" . BML::ml('entryform.format3') . "</label>" . LJ::help_icon_html("noautoformat", "", " ") . "</span>\n";
    $out .= "</div>\n\n";

    ### Draft Status Area
    $out .= "<div id='draft-container' class='pkg'>\n";
    $out .= LJ::html_textarea({ 'name' => 'event', 'value' => $opts->{'event'},
                                'rows' => '20', 'cols' => '50', 'style' => '',
                                'tabindex' => $tabindex->(), 'wrap' => 'soft',
                                'disabled' => $opts->{'disabled_save'},
                                'id' => 'draft'}) . "\n";
    $out .= "</div><!-- end #draft-container -->\n\n";
    $out .= "<input type='text' disabled='disabled' name='draftstatus' id='draftstatus' />\n\n";
    LJ::need_res('stc/fck/fckeditor.js', 'js/rte.js', 'stc/display_none.css');
    if (!$opts->{'did_spellcheck'}) {

        my $jnorich = LJ::ejs(LJ::deemp(BML::ml('entryform.htmlokay.norich2')));

        $out .= <<RTE;
        <script language='JavaScript' type='text/javascript'>
            <!--

        // Check if this browser supports FCKeditor
        var rte = new FCKeditor();
        var t = rte._IsCompatibleBrowser();
        if (t) {
RTE

    $out .= "var FCKLang;\n";
    $out .= "if (!FCKLang) FCKLang = {};\n";
    $out .= "FCKLang.UserPrompt = \"".LJ::ejs(BML::ml('fcklang.userprompt'))."\";\n";
    $out .= "FCKLang.InvalidChars = \"".LJ::ejs(BML::ml('fcklang.invalidchars'))."\";\n";
    $out .= "FCKLang.LJUser = \"".LJ::ejs(BML::ml('fcklang.ljuser'))."\";\n";
    $out .= "FCKLang.VideoPrompt = \"".LJ::ejs(BML::ml('fcklang.videoprompt'))."\";\n";
    $out .= "FCKLang.LJVideo = \"".LJ::ejs(BML::ml('fcklang.ljvideo2'))."\";\n";
    $out .= "FCKLang.CutPrompt = \"".LJ::ejs(BML::ml('fcklang.cutprompt'))."\";\n";
    $out .= "FCKLang.ReadMore = \"".LJ::ejs(BML::ml('fcklang.readmore'))."\";\n";
    $out .= "FCKLang.CutContents = \"".LJ::ejs(BML::ml('fcklang.cutcontents'))."\";\n";
    $out .= "FCKLang.LJCut = \"".LJ::ejs(BML::ml('fcklang.ljcut'))."\";\n";

        if ($opts->{'richtext_default'}) {
            $$onload .= 'useRichText("draft", "' . LJ::ejs($LJ::WSTATPREFIX) . '");';
        }

        {
            my $jrich = LJ::ejs(LJ::deemp(
                                          BML::ml("entryform.htmlokay.rich2", { 'opts' => 'href="javascript:void(0);" onclick="return useRichText(\'draft\', \'' . LJ::ejs($LJ::WSTATPREFIX) . '\');"' })));

            my $jplain = LJ::ejs(LJ::deemp(
                                           BML::ml("entryform.plainswitch", { 'aopts' => 'href="javascript:void(0);" onclick="return usePlainText(\'draft\');"' })));
        }

        $out .= <<RTE;
        } else {
            document.getElementById('entry-tabs').style.visibility = 'hidden';
            document.getElementById('htmltools').style.display = 'block';
            document.write("$jnorich");
            usePlainText('draft');
        }
        //-->
            </script>
RTE

        $out .= '<noscript><?de ' . BML::ml('entryform.htmlokay.norich2') . ' de?><br /></noscript>';
    }
    $out .= LJ::html_hidden({ name => 'switched_rte_on', id => 'switched_rte_on', value => '0'});

    $out .= "<div id='options' class='pkg'>";
    if (!$opts->{'disabled_save'}) {
        ### Options

            # Tag labeling
            unless ($LJ::DISABLED{tags}) {
                $out .= "<p class='pkg'>";
                $out .= "<label for='prop_taglist' class='left options'>" . BML::ml('entryform.tags') . "</label>";
                $out .= LJ::html_text(
                    {
                        'name'      => 'prop_taglist',
                        'id'        => 'prop_taglist',
                        'class'     => 'text',
                        'size'      => '35',
                        'value'     => $opts->{'prop_taglist'},
                        'tabindex'  => $tabindex->(),
                        'raw'       => "autocomplete='off'",
                    }
                );
                $out .= LJ::help_icon_html('addtags');
                $out .= "</p>";
            }

            $out .= "<p class='pkg'>\n";
            $out .= "<span id='prop_mood_wrapper' class='inputgroup-left'>\n";
            $out .= "<label for='prop_current_moodid' class='left options'>" . BML::ml('entryform.mood') . "</label>";
            # Current Mood
            {
                my @moodlist = ('', BML::ml('entryform.mood.noneother'));
                my $sel;

                my $moods = LJ::get_moods();

                foreach (sort { $moods->{$a}->{'name'} cmp $moods->{$b}->{'name'} } keys %$moods) {
                    push @moodlist, ($_, $moods->{$_}->{'name'});

                    if ($opts->{'prop_current_mood'} eq $moods->{$_}->{'name'} ||
                        $opts->{'prop_current_moodid'} == $_) {
                        $sel = $_;
                    }
                }

                if ($remote) {
                    LJ::load_mood_theme($remote->{'moodthemeid'});
                      foreach my $mood (keys %$moods) {
                          if (LJ::get_mood_picture($remote->{'moodthemeid'}, $moods->{$mood}->{id}, \ my %pic)) {
                              $moodlist .= "    moods[" . $moods->{$mood}->{id} . "] = \"" . $moods->{$mood}->{name} . "\";\n";
                              $moodpics .= "    moodpics[" . $moods->{$mood}->{id} . "] = \"" . $pic{pic} . "\";\n";
                          }
                      }
                      $$onload .= " mood_preview();";
                $$head .= <<MOODS;
<script type="text/javascript" language="JavaScript"><!--
if (document.getElementById) {
    var moodpics = new Array();
    $moodpics
    var moods    = new Array();
    $moodlist
}
//--></script>
MOODS
                }
                my $moodpreviewoc;
                $moodpreviewoc = 'mood_preview()' if $remote;
                $out .= LJ::html_select({ 'name' => 'prop_current_moodid', 'id' => 'prop_current_moodid',
                                          'selected' => $sel, 'onchange' => $moodpreviewoc, 'class' => 'select',
                                          'tabindex' => $tabindex->() }, @moodlist);
                $out .= " " . LJ::html_text({ 'name' => 'prop_current_mood', 'id' => 'prop_current_mood', 'class' => 'text',
                                              'value' => $opts->{'prop_current_mood'}, 'onchange' => $moodpreviewoc,
                                              'size' => '15', 'maxlength' => '30',
                                              'tabindex' => $tabindex->() });
            }
            $out .= "<span id='mood_preview'></span>";
            $out .= "</span>\n";
            $out .= "<span class='inputgroup-right'>\n";
            $out .= "<label for='comment_settings' class='left options'>" . BML::ml('entryform.comment.settings2') . "</label>\n";
            # Comment Settings
            my $comment_settings_selected = sub {
                return "noemail" if $opts->{'prop_opt_noemail'};
                return "nocomments" if $opts->{'prop_opt_nocomments'};
                return $opts->{'comment_settings'};
            };

            my $comment_settings_journaldefault = sub {
                return "Disabled" if $opts->{'prop_opt_default_nocomments'} eq 'N';
                return "No Email" if $opts->{'prop_opt_default_noemail'} eq 'N';
                return "Enabled";
            };

            my $comment_settings_default = BML::ml('entryform.comment.settings.default5', {'aopts' => $comment_settings_journaldefault->()});
            $out .= LJ::html_select({ 'name' => "comment_settings", 'id' => 'comment_settings', 'class' => 'select', 'selected' => $comment_settings_selected->(),
                                  'tabindex' => $tabindex->() },
                                "", $comment_settings_default, "nocomments", BML::ml('entryform.comment.settings.nocomments',"noemail"), "noemail", BML::ml('entryform.comment.settings.noemail'));
            $out .= LJ::help_icon_html("comment", "", " ");
            $out .= "\n";
            $out .= "</span>\n";
            $out .= "</p>\n";

            # Current Location
            $out .= "<p class='pkg'>";
            unless ($LJ::DISABLED{'web_current_location'}) {
                $out .= "<span class='inputgroup-left'>";
                $out .= "<label for='prop_current_location' class='left options'>" . BML::ml('entryform.location') . "</label>";
                $out .= LJ::html_text({ 'name' => 'prop_current_location', 'value' => $opts->{'prop_current_location'}, 'id' => 'prop_current_location',
                                        'class' => 'text', 'size' => '35', 'maxlength' => '60', 'tabindex' => $tabindex->() }) . "\n";
                $out .= "</span>";
            }

            # Comment Screening settings
            $out .= "<span class='inputgroup-right'>\n";
            $out .= "<label for='prop_opt_screening' class='left options'>" . BML::ml('entryform.comment.screening2') . "</label>\n";
            my $screening_levels_default = $opts->{'prop_opt_default_screening'} eq 'N' ? BML::ml('label.screening.none2') :
                    $opts->{'prop_opt_default_screening'} eq 'R' ? BML::ml('label.screening.anonymous2') :
                    $opts->{'prop_opt_default_screening'} eq 'F' ? BML::ml('label.screening.nonfriends2') :
                    $opts->{'prop_opt_default_screening'} eq 'A' ? BML::ml('label.screening.all2') : BML::ml('label.screening.none2');
            my @levels = ('', BML::ml('label.screening.default4', {'aopts'=>$screening_levels_default}), 'N', BML::ml('label.screening.none2'),
                      'R', BML::ml('label.screening.anonymous2'), 'F', BML::ml('label.screening.nonfriends2'),
                      'A', BML::ml('label.screening.all2'));
            $out .= LJ::html_select({ 'name' => 'prop_opt_screening', 'id' => 'prop_opt_screening', 'class' => 'select', 'selected' => $opts->{'prop_opt_screening'},
                      'tabindex' => $tabindex->() }, @levels);
            $out .= LJ::help_icon_html("screening", "", " ");
            $out .= "</span>\n";
            $out .= "</p>\n";

            # Current Music
            $out .= "<p class='pkg'>\n";
            $out .= "<span class='inputgroup-left'>\n";
            $out .= "<label for='prop_current_music' class='left options'>" . BML::ml('entryform.music') . "</label>\n";
            # BML::ml('entryform.music')
            $out .= LJ::html_text({ 'name' => 'prop_current_music', 'value' => $opts->{'prop_current_music'}, 'id' => 'prop_current_music',
                                    'class' => 'text', 'size' => '35', 'maxlength' => LJ::std_max_length(), 'tabindex' => $tabindex->() }) . "\n";
            $out .= "</span>\n";
            $out .= "<span class='inputgroup-right'>";

            # Content Flag
            if (LJ::is_enabled("content_flag")) {
                my @adult_content_menu = (
                    "" => BML::ml('entryform.adultcontent.default'),
                    none => BML::ml('entryform.adultcontent.none'),
                    concepts => BML::ml('entryform.adultcontent.concepts'),
                    explicit => BML::ml('entryform.adultcontent.explicit'),
                );

                $out .= "<label for='prop_adult_content' class='left options'>" . BML::ml('entryform.adultcontent') . "</label>\n";
                $out .= LJ::html_select({
                    name => 'prop_adult_content',
                    id => 'prop_adult_content',
                    class => 'select',
                    selected => $opts->{prop_adult_content} || "",
                    tabindex => $tabindex->(),
                }, @adult_content_menu);
                $out .= LJ::help_icon_html("adult_content", "", " ");
            }
            $out .= "</span>\n";
            $out .= "</p>\n";

            $out .= "<p class='pkg'>\n";
            $out .= "<span class='inputgroup-left'></span>";
            $out .= "<span class='inputgroup-right'>";
            # extra submit button so make sure it posts the form when person presses enter key
            if ($opts->{'mode'} eq "edit") {
                $out .= "<input type='submit' name='action:save' class='hidden_submit' />";
            }
            if ($opts->{'mode'} eq "update") {
                $out .= "<input type='submit' name='action:update' class='hidden_submit' />";
            }
            my $preview;
            $preview    = "<input type='button' value='" . BML::ml('entryform.preview') . "' onclick='entryPreview(this.form)' tabindex='" . $tabindex->() . "' />";
            if(!$opts->{'disabled_save'}) {
            $out .= <<PREVIEW;
<script type="text/javascript" language="JavaScript">
<!--
if (document.getElementById) {
    document.write("$preview ");
}
//-->
</script>
PREVIEW
            }
            if ($LJ::SPELLER && !$opts->{'disabled_save'}) {
                $out .= LJ::html_submit('action:spellcheck', BML::ml('entryform.spellcheck'), { 'tabindex' => $tabindex->() }) . "&nbsp;";
            }
            $out .= "</span>\n";
            $out .= "</p>\n";
        }



    $out .= "</div><!-- end #options -->\n\n";

    ### Submit Bar
    {
        $out .= "<div id='submitbar' class='pkg'>\n\n";

        $out .= "<div id='security_container'>\n";
        $out .= "<label for='security'>" . BML::ml('entryform.security2') . " </label>\n";

        # Security
            {
                $$onload .= " setColumns();" if $remote;
                my @secs = ("public", BML::ml('label.security.public2'), "friends", BML::ml('label.security.friends'),
                            "private", BML::ml('label.security.private2'));

                my @secopts;
                if ($res && ref $res->{'friendgroups'} eq 'ARRAY' && scalar @{$res->{'friendgroups'}} && !$opts->{'usejournal'}) {
                    push @secs, ("custom", BML::ml('label.security.custom'));
                    push @secopts, ("onchange" => "customboxes()");
                }

                $out .= LJ::html_select({ 'id' => "security", 'name' => 'security', 'include_ids' => 1,
                                          'class' => 'select', 'selected' => $opts->{'security'},
                                          'tabindex' => $tabindex->(), @secopts }, @secs) . "\n";

                # if custom security groups available, show them in a hideable div
                if ($res && ref $res->{'friendgroups'} eq 'ARRAY' && scalar @{$res->{'friendgroups'}}) {
                    my $display = $opts->{'security'} eq "custom" ? "block" : "none";
                    $out .= LJ::help_icon("security", "<span id='security-help'>\n", "\n</span>\n");
                    $out .= "<div id='custom_boxes' class='pkg' style='display: $display;'>\n";
                    $out .= "<ul id='custom_boxes_list'>";
                    foreach my $fg (@{$res->{'friendgroups'}}) {
                        $out .= "<li>";
                        $out .= LJ::html_check({ 'name' => "custom_bit_$fg->{'id'}",
                                                 'id' => "custom_bit_$fg->{'id'}",
                                                 'selected' => $opts->{"custom_bit_$fg->{'id'}"} || $opts->{'security_mask'}+0 & 1 << $fg->{'id'} }) . " ";
                        $out .= "<label for='custom_bit_$fg->{'id'}'>" . LJ::ehtml($fg->{'name'}) . "</label>\n";
                        $out .= "</li>";
                    }
                    $out .= "</ul>";
                    $out .= "</div><!-- end #custom_boxes -->\n";
                }
            }

        if ($opts->{'mode'} eq "update") {
            my $onclick = "";
            $onclick .= "convert_post('draft');return sendForm('updateForm');" if ! $LJ::IS_SSL;

            my $defaultjournal;
            my $not_a_journal = 0;
            if ($opts->{'usejournal'}) {
                $defaultjournal = $opts->{'usejournal'};
            } elsif ($remote && $opts->{auth_as_remote}) {
                $defaultjournal = $remote->user;
            } else {
                $defaultjournal = "Journal";
                $not_a_journal = 1;
            }

            $$onload .= " changeSubmit('" . BML::ml('entryform.update3') . "', '$defaultjournal');";
            $$onload .= " getUserTags('$defaultjournal');" unless $not_a_journal;

            $out .= LJ::html_submit('action:update', BML::ml('entryform.update4'),
                    { 'onclick' => $onclick, 'class' => 'submit', 'id' => 'formsubmit',
                      'tabindex' => $tabindex->() }) . "&nbsp;\n"; }

        if ($opts->{'mode'} eq "edit") {
            my $onclick = "";
            $onclick .= "convert_post('draft');return sendForm('updateForm');" if ! $LJ::IS_SSL;

            $out .= LJ::html_submit('action:save', BML::ml('entryform.save'),
                                    { 'onclick' => $onclick, 'disabled' => $opts->{'disabled_save'},
                                      'tabindex' => $tabindex->() }) . "&nbsp;\n";
            $out .= LJ::html_submit('action:delete', BML::ml('entryform.delete'), {
                'disabled' => $opts->{'disabled_delete'},
                'tabindex' => $tabindex->(),
                'onclick' => "return confirm('" . LJ::ejs(BML::ml('entryform.delete.confirm')) . "')" }) . "&nbsp;\n";

            if (!$opts->{'disabled_spamdelete'}) {
                $out .= LJ::html_submit('action:deletespam', BML::ml('entryform.deletespam'), {
                    'onclick' => "return confirm('" . LJ::ejs(BML::ml('entryform.deletespam.confirm')) . "')",
                    'tabindex' => $tabindex->() }) . "\n";
            }
        }

        $out .= "</div><!-- end #security_container -->\n\n";
        $out .= "</div><!-- end #submitbar -->\n\n";
        $out .= "</div><!-- end #entry-form-wrapper -->\n\n";

        $out .= "<script  type='text/javascript'>\n";
        $out .= "// <![CDATA[ \n ";
        $out .= "init_update_bml() \n";
        $out .= "// ]]>\n";
        $out .= "</script>\n";
    }
    return $out;
}

# entry form subject
sub entry_form_subject_widget {
    my $class = shift;

    if ($class) {
        $class = qq { class="$class" };
    }
    return qq { <input name="subject" $class/> };
}

# entry form hidden date field
sub entry_form_date_widget {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    $year+=1900;
    $mon=sprintf("%02d", $mon+1);
    $mday=sprintf("%02d", $mday);
    $min=sprintf("%02d", $min);
    return LJ::html_hidden({'name' => 'date_ymd_yyyy', 'value' => $year, 'id' => 'update_year'},
                           {'name' => 'date_ymd_dd', 'value'  => $mday, 'id' => 'update_day'},
                           {'name' => 'date_ymd_mm', 'value'  => $mon,  'id' => 'update_mon'},
                           {'name' => 'hour', 'value' => $hour, 'id' => 'update_hour'},
                           {'name' => 'min', 'value'  => $min,  'id' => 'update_min'});
}

# entry form event text box
sub entry_form_entry_widget {
    my $class = shift;

    if ($class) {
        $class = qq { class="$class" };
    }

    return qq { <textarea cols=50 rows=10 name="event" $class></textarea> };
}


# entry form "journals can post to" dropdown
# NOTE!!! returns undef if no other journals user can post to
sub entry_form_postto_widget {
    my $remote = shift;

    return undef unless LJ::isu($remote);

    my $ret;
    # log in to get journals can post to
    my $res;
    $res = LJ::Protocol::do_request("login", {
        "ver" => $LJ::PROTOCOL_VER,
        "username" => $remote->{'user'},
    }, undef, {
        "noauth" => 1,
        "u" => $remote,
    });

    return undef unless $res;

    my @journals = map { $_, $_ } @{$res->{'usejournals'}};

    return undef unless @journals;

    push @journals, $remote->{'user'};
    push @journals, $remote->{'user'};
    @journals = sort @journals;
    $ret .= LJ::html_select({ 'name' => 'usejournal', 'selected' => $remote->{'user'}}, @journals) . "\n";
    return $ret;
}

sub entry_form_security_widget {
    my $ret = '';

    my @secs = ("public", BML::ml('label.security.public'),
                "private", BML::ml('label.security.private'),
                "friends", BML::ml('label.security.friends'));

    $ret .= LJ::html_select({ 'name' => 'security'},
                            @secs);

    return $ret;
}

sub entry_form_tags_widget {
    my $ret = '';

    return '' if $LJ::DISABLED{tags};

    $ret .= LJ::html_text({
                              'name'      => 'prop_taglist',
                              'size'      => '35',
                              'maxlength' => '255',
                          });
    $ret .= LJ::help_icon('addtags');

    return $ret;
}

# <LJFUNC>
# name: LJ::entry_form_decode
# class: web
# des: Decodes an entry_form into a protocol-compatible hash.
# info: Generate form with [func[LJ::entry_form]].
# args: req, post
# des-req: protocol request hash to build.
# des-post: entry_form POST contents.
# returns: req
# </LJFUNC>
sub entry_form_decode
{
    my ($req, $POST) = @_;

    # find security
    my $sec = "public";
    my $amask = 0;
    if ($POST->{'security'} eq "private") {
        $sec = "private";
    } elsif ($POST->{'security'} eq "friends") {
        $sec = "usemask"; $amask = 1;
    } elsif ($POST->{'security'} eq "custom") {
        $sec = "usemask";
        foreach my $bit (1..30) {
            next unless $POST->{"custom_bit_$bit"};
            $amask |= (1 << $bit);
        }
    }
    $req->{'security'} = $sec;
    $req->{'allowmask'} = $amask;

    # date/time
    my $date = LJ::html_datetime_decode({ 'name' => "date_ymd", }, $POST);
    my ($year, $mon, $day) = split( /\D/, $date);
    my ($hour, $min) = ($POST->{'hour'}, $POST->{'min'});

    # TEMP: ease golive by using older way of determining differences
    my $date_old = LJ::html_datetime_decode({ 'name' => "date_ymd_old", }, $POST);
    my ($year_old, $mon_old, $day_old) = split( /\D/, $date_old);
    my ($hour_old, $min_old) = ($POST->{'hour_old'}, $POST->{'min_old'});

    my $different = $POST->{'min_old'} && (($year ne $year_old) || ($mon ne $mon_old)
                    || ($day ne $day_old) || ($hour ne $hour_old) || ($min ne $min_old));

    # this value is set when the JS runs, which means that the user-provided
    # time is sync'd with their computer clock. otherwise, the JS didn't run,
    # so let's guess at their timezone.
    if ($POST->{'date_diff'} || $POST->{'date_diff_nojs'} || $different) {
        delete $req->{'tz'};
        $req->{'year'} = $year;
        $req->{'mon'} = $mon;
        $req->{'day'} = $day;
        $req->{'hour'} = $hour;
        $req->{'min'} = $min;
    }

    # copy some things from %POST
    foreach (qw(subject
                prop_picture_keyword prop_current_moodid
                prop_current_mood prop_current_music
                prop_opt_screening prop_opt_noemail
                prop_opt_preformatted prop_opt_nocomments
                prop_current_location prop_current_coords
                prop_taglist prop_qotdid)) {
        $req->{$_} = $POST->{$_};
    }

    if ($POST->{"subject"} eq BML::ml('entryform.subject.hint2')) {
        $req->{"subject"} = "";
    }

    $req->{"prop_opt_preformatted"} ||= $POST->{'switched_rte_on'} ? 1 :
        $POST->{'event_format'} eq "preformatted" ? 1 : 0;
    $req->{"prop_opt_nocomments"}   ||= $POST->{'comment_settings'} eq "nocomments" ? 1 : 0;
    $req->{"prop_opt_noemail"}      ||= $POST->{'comment_settings'} eq "noemail" ? 1 : 0;
    $req->{'prop_opt_backdated'}      = $POST->{'prop_opt_backdated'} ? 1 : 0;

    if (LJ::is_enabled("content_flag")) {
        $req->{prop_adult_content} = $POST->{prop_adult_content};
        $req->{prop_adult_content} = ""
            unless $req->{prop_adult_content} eq "none" || $req->{prop_adult_content} eq "concepts" || $req->{prop_adult_content} eq "explicit";
    }

    # nuke taglists that are just blank
    $req->{'prop_taglist'} = "" unless $req->{'prop_taglist'} && $req->{'prop_taglist'} =~ /\S/;

    # Convert the rich text editor output back to parsable lj tags.
    my $event = $POST->{'event'};
    if ($POST->{'switched_rte_on'}) {
        $req->{"prop_used_rte"} = 1;

        # We want to see if we can hit the fast path for cleaning
        # if they did nothing but add line breaks.
        my $attempt = $event;
        $attempt =~ s!<br />!\n!g;

        if ($attempt !~ /<\w/) {
            $event = $attempt;

            # Make sure they actually typed something, and not just hit
            # enter a lot
            $attempt =~ s!(?:<p>(?:&nbsp;|\s)+</p>|&nbsp;)\s*?!!gm;
            $event = '' unless $attempt =~ /\S/;

            $req->{'prop_opt_preformatted'} = 0;
        } else {
            # Old methods, left in for compatibility during code push
            $event =~ s!<lj-cut class="ljcut">!<lj-cut>!gi;

            $event =~ s!<lj-raw class="ljraw">!<lj-raw>!gi;
        }
    } else {
        $req->{"prop_used_rte"} = 0;
    }

    $req->{'event'} = $event;

    ## see if an "other" mood they typed in has an equivalent moodid
    if ($POST->{'prop_current_mood'}) {
        if (my $id = LJ::mood_id($POST->{'prop_current_mood'})) {
            $req->{'prop_current_moodid'} = $id;
            delete $req->{'prop_current_mood'};
        }
    }
    return $req;
}

# returns exactly what was passed to it normally.  but in developer mode,
# it includes a link to a page that automatically grants the needed priv.
sub no_access_error {
    my ($text, $priv, $privarg) = @_;
    if ($LJ::IS_DEV_SERVER) {
        my $remote = LJ::get_remote();
        return "$text <b>(DEVMODE: <a href='/admin/priv/?devmode=1&user=$remote->{user}&priv=$priv&arg=$privarg'>Grant $priv\[$privarg\]</a>)</b>";
    } else {
        return $text;
    }
}

# Data::Dumper for JavaScript
sub js_dumper {
    my $obj = shift;
    if (ref $obj eq "HASH") {
        my $ret = "{";
        foreach my $k (keys %$obj) {
            # numbers as keys need to be quoted.  and things like "null"
            my $kd = ($k =~ /^\w+$/) ? "\"$k\"" : LJ::js_dumper($k);
            $ret .= "$kd: " . js_dumper($obj->{$k}) . ",\n";
        }
        if (keys %$obj) {
            chop $ret;
            chop $ret;
        }
        $ret .= "}";
        return $ret;
    } elsif (ref $obj eq "ARRAY") {
        my $ret = "[" . join(", ", map { js_dumper($_) } @$obj) . "]";
        return $ret;
    } else {
        return $obj if $obj =~ /^\d+$/;
        return "\"" . LJ::ejs($obj) . "\"";
    }
}


{
    my %stat_cache = ();  # key -> {lastcheck, modtime}
    sub _file_modtime {
        my ($key, $now) = @_;
        if (my $ci = $stat_cache{$key}) {
            if ($ci->{lastcheck} > $now - 10) {
                return $ci->{modtime};
            }
        }

        my $set = sub {
            my $mtime = shift;
            $stat_cache{$key} = { lastcheck => $now, modtime => $mtime };
            return $mtime;
        };

        my $file = "$LJ::HOME/htdocs/$key";
        my $mtime = (stat($file))[9];
        return $set->($mtime);
    }
}

sub need_res {
    foreach my $reskey (@_) {
        die "Bogus reskey $reskey" unless $reskey =~ m!^(js|stc)/!;
        unless ($LJ::NEEDED_RES{$reskey}++) {
            push @LJ::NEEDED_RES, $reskey;
        }
    }
}

sub res_includes {
    # TODO: automatic dependencies from external map and/or content of files,
    # currently it's limited to dependencies on the order you call LJ::need_res();
    my $ret = "";
    my $do_concat = $LJ::IS_SSL ? $LJ::CONCAT_RES_SSL : $LJ::CONCAT_RES;

    # use correct root and prefixes for SSL pages
    my ($siteroot, $imgprefix, $statprefix, $jsprefix, $wstatprefix);
    if ($LJ::IS_SSL) {
        $siteroot = $LJ::SSLROOT;
        $imgprefix = $LJ::SSLIMGPREFIX;
        $statprefix = $LJ::SSLSTATPREFIX;
        $jsprefix = $LJ::SSLJSPREFIX;
        $wstatprefix = $LJ::SSLWSTATPREFIX;
    } else {
        $siteroot = $LJ::SITEROOT;
        $imgprefix = $LJ::IMGPREFIX;
        $statprefix = $LJ::STATPREFIX;
        $jsprefix = $LJ::JSPREFIX;
        $wstatprefix = $LJ::WSTATPREFIX;
    }

    # find current journal
    my $r = eval { Apache->request };
    my $journal_base = '';
    my $journal = '';
    if ($r) {
        my $journalid = $r->notes('journalid');

        my $ju;
        $ju = LJ::load_userid($journalid) if $journalid;

        if ($ju) {
            $journal_base = $ju->journal_base;
            $journal = $ju->{user};
        }
    }

    my $remote = LJ::get_remote();
    my $hasremote = $remote ? 1 : 0;

    # ctxpopup prop
    my $ctxpopup = 1;
    $ctxpopup = 0 if $remote && ! $remote->prop("opt_ctxpopup");

    # poll for esn inbox updates?
    my $inbox_update_poll = $LJ::DISABLED{inbox_update_poll} ? 0 : 1;

    # are media embeds enabled?
    my $embeds_enabled = $LJ::DISABLED{embed_module} ? 0 : 1;

    # esn ajax enabled?
    my $esn_async = LJ::conf_test($LJ::DISABLED{esn_ajax}) ? 0 : 1;

    my %site = (
                imgprefix => "$imgprefix",
                siteroot => "$siteroot",
                statprefix => "$statprefix",
                currentJournalBase => "$journal_base",
                currentJournal => "$journal",
                has_remote => $hasremote,
                ctx_popup => $ctxpopup,
                inbox_update_poll => $inbox_update_poll,
                media_embed_enabled => $embeds_enabled,
                esn_async => $esn_async,
                );

    my $site_params = LJ::js_dumper(\%site);
    my $site_param_keys = LJ::js_dumper([keys %site]);

    # include standard JS info
    $ret .= qq {
        <script language="JavaScript" type="text/javascript">
            var Site;
            if (!Site)
                Site = {};

            var site_p = $site_params;
            var site_k = $site_param_keys;
            for (var i = 0; i < site_k.length; i++) {
                Site[site_k[i]] = site_p[site_k[i]];
            }
       </script>
    };

    my $now = time();
    my %list;   # type -> [];
    my %oldest; # type -> $oldest
    my $add = sub {
        my ($type, $what, $modtime) = @_;

        # in the concat-res case, we don't directly append the URL w/
        # the modtime, but rather do one global max modtime at the
        # end, which is done later in the tags function.
        $what .= "?v=$modtime" unless $do_concat;

        push @{$list{$type} ||= []}, $what;
        $oldest{$type} = $modtime if $modtime > $oldest{$type};
    };

    foreach my $key (@LJ::NEEDED_RES) {
        my $path;
        my $mtime = _file_modtime($key, $now);
        if ($key =~ m!^stc/fck/! || $LJ::FORCE_WSTAT{$key}) {
            $path = "w$key";  # wstc/ instead of stc/
        } else {
            $path = $key;
        }

        # if we want to also include a local version of this file, include that too
        if (@LJ::USE_LOCAL_RES) {
            if (grep { lc $_ eq lc $key } @LJ::USE_LOCAL_RES) {
                my $inc = $key;
                $inc =~ s/(\w+)\.(\w+)$/$1-local.$2/;
                LJ::need_res($inc);
            }
        }

        if ($path =~ m!^js/(.+)!) {
            $add->('js', $1, $mtime);
        } elsif ($path =~ /\.css$/ && $path =~ m!^(w?)stc/(.+)!) {
            $add->("${1}stccss", $2, $mtime);
        } elsif ($path =~ /\.js$/ && $path =~ m!^(w?)stc/(.+)!) {
            $add->("${1}stcjs", $2, $mtime);
        }
    }

    my $tags = sub {
        my ($type, $template) = @_;
        my $list;
        return unless $list = $list{$type};

        if ($do_concat) {
            my $csep = join(',', @$list);
            $csep .= "?v=" . $oldest{$type};
            $template =~ s/__+/??$csep/;
            $ret .= $template;
        } else {
            foreach my $item (@$list) {
                my $inc = $template;
                $inc =~ s/__+/$item/;
                $ret .= $inc;
            }
        }
    };

    $tags->("js",      "<script type=\"text/javascript\" src=\"$jsprefix/___\"></script>\n");
    $tags->("stccss",  "<link rel=\"stylesheet\" type=\"text/css\" href=\"$statprefix/___\" />\n");
    $tags->("wstccss", "<link rel=\"stylesheet\" type=\"text/css\" href=\"$wstatprefix/___\" />\n");
    $tags->("stcjs",   "<script type=\"text/javascript\" src=\"$statprefix/___\"></script>\n");
    $tags->("wstcjs",  "<script type=\"text/javascript\" src=\"$wstatprefix/___\"></script>\n");
    return $ret;
}

# Returns HTML of a dynamic tag could given passed in data
# Requires hash-ref of tag => { url => url, value => value }
sub tag_cloud {
    my ($tags, $opts) = @_;

    # find sizes of tags, sorted
    my @sizes = sort { $a <=> $b } map { $tags->{$_}->{'value'} } keys %$tags;

    # remove duplicates:
    my %sizes = map { $_, 1 } @sizes;
    @sizes = sort { $a <=> $b } keys %sizes;

    my @tag_names = sort keys %$tags;

    my $percentile = sub {
        my $n = shift;
        my $total = scalar @sizes;
        for (my $i = 0; $i < $total; $i++) {
            next if $n > $sizes[$i];
            return $i / $total;
        }
    };

    my $base_font_size = 8;
    my $font_size_range = $opts->{font_size_range} || 25;
    my $ret .= "<div id='tagcloud' class='tagcloud'>";
    my %tagdata = ();
    foreach my $tag (@tag_names) {
        my $tagurl = $tags->{$tag}->{'url'};
        my $ct     = $tags->{$tag}->{'value'};
        my $pt     = int($base_font_size + $percentile->($ct) * $font_size_range);
        $ret .= "<a ";
        $ret .= "id='taglink_$tag' " unless $opts->{ignore_ids};
        $ret .= "href='" . LJ::ehtml($tagurl) . "' style='color: <?altcolor2?>; font-size: ${pt}pt; text-decoration: none'><span style='color: <?altcolor2?>'>";
        $ret .= LJ::ehtml($tag) . "</span></a>\n";

        # build hash of tagname => final point size for refresh
        $tagdata{$tag} = $pt;
    }
    $ret .= "</div>";

    return $ret;
}

sub get_next_ad_id {
    return ++$LJ::REQ_GLOBAL{'curr_ad_id'};
}

##
## Function LJ::check_page_ad_block. Return answer (true/false) to question:
## Should we show ad of this type on this page.
## Args: uri of the page and orient of the ad block (e.g. 'App-Confirm')
##
sub check_page_ad_block {
    my $uri = shift;
    my $orient = shift;

    # The AD_MAPPING hash may contain code refs
    # This allows us to choose an ad based on some logic
    # Example: If LJ::did_post() show 'App-Confirm' type ad
    my $ad_mapping = LJ::run_hook('get_ad_uri_mapping', $uri) ||
        LJ::conf_test($LJ::AD_MAPPING{$uri});

    return 1 if $ad_mapping eq $orient;
    return 1 if ref($ad_mapping) eq 'HASH' && $ad_mapping->{$orient};
    return;
}

# returns a hash with keys "layout" and "theme"
# "theme" is empty for S1 users
sub get_style_for_ads {
    my $u = shift;

    my %ret;
    $ret{layout} = "";
    $ret{theme} = "";

    # Values for custom layers, default themes, and S1 styles
    my $custom_layout = "custom_layout";
    my $custom_theme = "custom_theme";
    my $default_theme = "default_theme";
    my $s1_prefix = "s1_";

    if ($u->prop('stylesys') == 2) {
        my %style = LJ::S2::get_style($u);
        my $public = LJ::S2::get_public_layers();

        # get layout
        my $layout = $public->{$style{layout}}->{uniq}; # e.g. generator/layout
        $layout =~ s/\/\w+$//;

        # get theme
        # if the theme id == 0, then we have no theme for this layout (i.e. default theme)
        my $theme;
        if ($style{theme} == 0) {
            $theme = $default_theme;
        } else {
            $theme = $public->{$style{theme}}->{uniq}; # e.g. generator/mintchoc
            $theme =~ s/^\w+\///;
        }

        $ret{layout} = $layout ? $layout : $custom_layout;
        $ret{theme} = $theme ? $theme : $custom_theme;
    } else {
        my $view = Apache->request->notes->{view};
        $view = "lastn" if $view eq "";

        if ($view =~ /^(?:friends|day|calendar|lastn)$/) {
            my $pubstyles = LJ::S1::get_public_styles();
            my $styleid = $u->prop("s1_${view}_style");

            my $layout = "";
            if ($pubstyles->{$styleid}) {
                $layout = $pubstyles->{$styleid}->{styledes}; # e.g. Clean and Simple
                $layout =~ s/\W//g;
                $layout =~ s/\s//g;
                $layout = lc $layout;
                $layout = $s1_prefix . $layout;
            }

            $ret{layout} = $layout ? $layout : $s1_prefix . $custom_layout;
        }
    }

    return %ret;
}

sub get_search_term {
    my $uri = shift;
    my $search_arg = shift;

    my %search_pages = (
        '/interests.bml' => 1,
        '/directory.bml' => 1,
        '/multisearch.bml' => 1,
    );

    return "" unless $search_pages{$uri};

    my $term = "";
    my $args = Apache->request->args;
    if ($uri eq '/interests.bml') {
        if ($args =~ /int=([^&]+)/) {
            $term = $1;
        }
    } elsif ($uri eq '/directory.bml') {
        if ($args =~ /int_like=([^&]+)/) {
            $term = $1;
        }
    } elsif ($uri eq '/multisearch.bml') {
        $term = $search_arg;
    }

    # change +'s to spaces
    $term =~ s/\+/ /;

    return $term;
}


sub email_ads {
    my %opts = @_;

    my $channel = $opts{channel};
    my $from_email = $opts{from_email};
    my $to_u = $opts{to_u};

    return '' unless LJ::run_hook('should_show_ad', {
        ctx  => 'app',
        user => $to_u,
        remote => $to_u,
        type => $channel,
    });

    return '' unless LJ::run_hook('should_show_email_ad', $to_u);

    my $adid = get_next_ad_id();
    my $divid = "ad_$adid";

    my %adcall = (
                  r  => rand(),
                  p  => 'lj',
                  channel => $channel,
                  type => 'user',
                  user => $to_u->id,
                  gender => $to_u->gender_for_adcall,
                  hR => Digest::MD5::md5_hex(lc($from_email)),
                  hS => Digest::MD5::md5_hex(lc($to_u->email_raw)),
                  site => "lj.email",
                  );

    my $age = $to_u->age_for_adcall;
    $adcall{age} = $age if $age;

    my $adparams = LJ::encode_url_string(\%adcall, 
                                         [ sort { length $adcall{$a} <=> length $adcall{$b} } 
                                           grep { length $adcall{$_} } 
                                           keys %adcall ] );

    # allow 24 bytes for escaping overhead
    $adparams = substr($adparams, 0, 1_000);

    my $image_url = $LJ::ADSERVER . '/image/?' . $adparams;
    my $click_url = $LJ::ADSERVER . '/click/?' . $adparams;

    my $adhtml = "<a href='$click_url'><img src='$image_url' /></a>";

    return $adhtml;
}

# this returns ad html given a search string
sub search_ads {
    my %opts = @_;

    return '' if LJ::conf_test($LJ::DISABLED{content_ads});

    # FIXME: this isn't the standard JS adcall we're doing, it's a special Google one,
    #        so should probably have a different disable flag
    return '' unless $LJ::USE_JS_ADCALL;

    my $remote = LJ::get_remote();

    return '' unless LJ::run_hook('should_show_ad', {
        ctx  => 'app',
        user => $remote,
        type => '',
    });

    return '' unless LJ::run_hook('should_show_search_ad');

    my $query = delete $opts{query} or croak "No search query specified in call to search_ads";
    my $count = int(delete $opts{count} || 1);
    my $adcount = int(delete $opts{adcount} || 3);

    my $adid = get_next_ad_id();
    my $divid = "ad_$adid";

    my @divids = map { "ad_$_" } (1 .. $count);

    my %adcall = (
                  u  => join(',', map { $adcount } @divids), # how many ads to show in each
                  r  => rand(),
                  q  => $query,
                  id => join(',', @divids),
                  f  => 'LiveJournal.insertAdsMulti',
                  p  => 'lj',
                  );

    if ($remote) {
        $adcall{user} = $remote->id;
    }

    my $adparams = LJ::encode_url_string(\%adcall, 
                                         [ sort { length $adcall{$a} <=> length $adcall{$b} } 
                                           grep { length $adcall{$_} } 
                                           keys %adcall ] );

    # allow 24 bytes for escaping overhead
    $adparams = substr($adparams, 0, 1_000);

    my $url = $LJ::ADSERVER . '/google/?' . $adparams;

    my $adhtml;

    my $adcall = '';
    $adcall = qq { <script charset="utf-8" id="ad${adid}s" defersrc="$url"></script> } if ++$LJ::REQ_GLOBAL{'curr_search_ad_id'} == $count;

    $adhtml = qq {
        <div class="lj_inactive_ad">
            <div class="adtitle">Sponsored Links</div>
            <div id="$divid" style="clear: left;">
              $adcall
            </div>
            <div class='clear'>&nbsp;</div>
        </div>
    };

    return $adhtml;
}

sub ads {
    my %opts = @_;

    return "" unless $LJ::USE_ADS;

    my $adcall_url = LJ::run_hook('construct_adcall', %opts);
    my $hook_did_adurl = $adcall_url ? 1 : 0;

    # WARNING: $ctx is terribly named and not an S2 context
    my $ctx      = $opts{'type'};
    my $orient   = $opts{'orient'};
    my $user     = $opts{'user'};
    my $pubtext  = $opts{'pubtext'};
    my $tags     = $opts{'tags'};
    my $colors   = $opts{'colors'};
    my $position = $opts{'position'};
    my $search_arg = $opts{'search_arg'};
    my $interests_extra = $opts{'interests_extra'};
    my $vertical = $opts{'vertical'};
    my $page     = $opts{'page'};

    ##
    ## Some BML files contains calls to LJ::ads inside them.
    ## When LJ::ads is called from BML files, special prefix 'BML-' is used.
    ## $pagetype is essentially $orient without leading 'BML-' prefix.
    ## E.g. $orient = 'BML-App-Confirm', $pagetype = 'App-Confirm'
    ## Prefix 'BML-' is also used in the ad config file (%LJ::AD_MAPPING).
    ##
    my $pagetype = $orient;
    $pagetype =~ s/^BML-//;

    # first 500 words
    $pubtext =~ s/<.+?>//g;
    $pubtext = text_trim($pubtext, 1000);
    my @words = grep { $_ } split(/\s+/, $pubtext);
    my $max_words = 500;
    @words = @words[0..$max_words-1] if @words > $max_words;
    $pubtext = join(' ', @words);

    # first 15 tags
    my $max_tags = 15;
    my @tag_names;
    if ($tags) {
        @tag_names = scalar @$tags > $max_tags ? @$tags[0..$max_tags-1] : @$tags;
    }
    my $tag_list = join(',', @tag_names);

    my $debug = $LJ::DEBUG{'ads'};

    # are we constructing JavaScript adcalls?
    my $use_js_adcall = LJ::conf_test($LJ::USE_JS_ADCALL) ? 1 : 0;

    # Don't show an ad unless we're in debug mode, or our hook says so.
    return '' unless $debug || LJ::run_hook('should_show_ad', {
        ctx  => $ctx,
        user => $user,
        type => $pagetype,
    });

    # If we don't know about this page type, can't do much of anything
    my $ad_page_mapping = LJ::run_hook('get_page_mapping', $pagetype) || $LJ::AD_PAGE_MAPPING{$pagetype};
    unless ($ad_page_mapping) {
        warn "No mapping for page type $pagetype"
            if $LJ::IS_DEV_SERVER && $LJ::AD_DEBUG;

        return '';
    }

    my $r = Apache->request;
    my %adcall = ();

    # Make sure this mapping is correct for app ads, journal ads only call this function
    # once when they directly want a specific type of ads.  App ads on the other hand
    # are called via the site scheme, so this function may be called half a dozen times
    # on each page creation.
    if ($ctx eq "app") {
        my $uri = BML::get_uri();
        $uri = $uri =~ /\/$/ ? "$uri/index.bml" : $uri;

        # Try making the uri from request notes if it doesn't match
        # and uri ends in .html
        if (!LJ::check_page_ad_block($uri,$orient) && $r->header_in('Host') ne $LJ::DOMAIN_WEB) {
            if ($uri = $r->notes('bml_filename')) {
                $uri =~ s!$LJ::HOME/(?:ssldocs|htdocs)!!;
                $uri = $uri =~ /\/$/ ? "$uri/index.bml" : $uri;
            }
        }

        # Make sure that the page type passed in is what the config says this
        # page actually is.
        return '' unless LJ::check_page_ad_block($uri,$orient) || $opts{'force'};

        # If it was a search provide the query to the targeting engine
        # for more relevant results
        $adcall{search_term} = LJ::get_search_term($uri, $search_arg);

        # Special case talkpost.bml and talkpost_do.bml as user pages
        if ($uri =~ /^\/talkpost(?:_do)?\.bml$/) {
            $adcall{type} = 'user';
        }
    }

    $adcall{adunit}  = $ad_page_mapping->{adunit};      # ie skyscraper, FIXME: this is ignored by adserver now
    my $addetails    = LJ::run_hook('get_ad_details', $adcall{adunit}) || $LJ::AD_TYPE{$adcall{adunit}};   # hashref of meta-data or scalar to directly serve

    return '' unless $addetails;

    $adcall{channel} = $pagetype;
    $adcall{type}    = $adcall{type} || $ad_page_mapping->{target}; # user|content


    $adcall{url}     = 'http://' . $r->header_in('Host') . $r->uri;

    $adcall{contents} = $pubtext;
    $adcall{tags} = $tag_list;
    $adcall{pos} = $position;

    $adcall{cbg} = $colors->{bgcolor};
    $adcall{ctext} = $colors->{fgcolor};
    $adcall{cborder} = $colors->{bordercolor};
    $adcall{clink} = $colors->{linkcolor};
    $adcall{curl} = $colors->{linkcolor};

    unless (ref $addetails eq "HASH") {
        LJ::run_hooks('notify_ad_block', $addetails);
        $LJ::ADV_PER_PAGE++;
        return $addetails;
    }

    # addetails is a hashref now:
    $adcall{width}   = $addetails->{width};
    $adcall{height}  = $addetails->{height};

    $adcall{vc} = $vertical;
    $adcall{pn} = $page;

    my $remote = LJ::get_remote();
    if ($remote) {

        # pass userid
        $adcall{user} = $remote->id;

        # Pass age to targeting engine
        my $age = $remote->age_for_adcall;
        $adcall{age} = $age if $age;

        # Pass country to targeting engine if user shares this information
        if ($remote->can_show_location) {
            $adcall{country} = $remote->prop('country');
        }

        # Pass gender to targeting engine
        $adcall{gender} = $remote->gender_for_adcall;

        # User selected ad content categories
        $adcall{categories} = $remote->prop('ad_categories');

        # User's notable interests
        $adcall{interests} = LJ::interests_for_adcall($remote, extra => $interests_extra);

        # Pass email address domain
        my $email = $remote->email_raw;
        $email =~ /\.([^\.]+)$/;
        $adcall{ed} = $1;
    }
    $adcall{gender} ||= "unknown"; # for logged-out users

    if ($ctx eq 'journal') {
        my $u = $opts{user} ? LJ::load_user($opts{user}) : LJ::load_userid($r->notes("journalid"));
        $opts{entry} = LJ::Entry->new_from_url($adcall{url});

        if ($u) {
            if (!$adcall{categories} && !$adcall{interests}) {
                # If we have neither categories or interests, load the content author's
                $adcall{categories} = $u->prop('ad_categories');
                $adcall{interests} = LJ::interests_for_adcall($u, extra => $interests_extra);
            }

            # set the country to the content author's
            # if it's not set, and default the language to the author's language
            $adcall{country} ||= $u->prop('country') if $u->can_show_location;
            $adcall{language} = $u->prop('browselang');

            # pass style info

            my %GET = Apache->request->args;
            my $styleu = $GET{style} eq "mine" && $remote ? $remote : $u;
            my %style = LJ::get_style_for_ads($styleu);
            $adcall{layout} = defined $style{layout} ? $style{layout} : "";
            $adcall{theme} = defined $style{theme} ? $style{theme} : "";

            # pass ad placement info
            $adcall{adplacement} = LJ::S2::current_box_type($u);
        }
    }

    # Language this page is displayed in
    # set the language to the current user's preferences if they are logged in
    $adcall{language} = $r->notes('langpref') if $remote;
    $adcall{language} =~ s/_LJ//; # Trim _LJ postfixJ

    # What type of account level do they have?
    if ($remote) {
        # Logged in? This is either a plus user or a basic user.
        $adcall{accttype} = $remote->in_class('plus') ? 'ADS' : 'FREE';
    } else {
        # aNONymous user
        $adcall{accttype} = 'NON';
    }
    $adcall{accttype} = $remote ?
        $remote->in_class('plus') ? 'ADS' : 'FREE' :   # Ads or Free if logged in
        'NON';                                         # Not logged in

    # incremental Ad ID within this page
    my $adid = get_next_ad_id();

    # specific params for SixApart adserver
    $adcall{p}  = 'lj';
    if ($use_js_adcall) {
        $adcall{f}  = 'AdEngine.insertAdResponse';
        $adcall{id} = "ad$adid";
    }

    # cache busting and unique-ad logic
    my $pageview_uniq = LJ::pageview_unique_string();
    $adcall{r} = "$pageview_uniq:$adid"; # cache buster
    $adcall{pagenum} = $pageview_uniq;   # unique ads

    LJ::run_hook("transform_adcall", \%opts, \%adcall);

    # Build up escaped query string of adcall parameters
    my $adparams = LJ::encode_url_string(\%adcall, 
                                         [ sort { length $adcall{$a} <=> length $adcall{$b} } 
                                           grep { length $adcall{$_} } 
                                           keys %adcall ] );

    # ghetto, but allow 24 bytes for escaping overhead
    $adparams = substr($adparams, 0, 1_000);

    my $adhtml;
    $adhtml .= "\n<div class=\"ljad ljad$adcall{adunit}\" id=\"\">\n";

    my $ad_url = my $advertising_url = LJ::run_hook("get_advertising_url") || "http://www.sixapart.com/about/advertising/";
    my $label = LJ::Lang::ml('web.ads.advertisement', {aopts=>"href='$ad_url'"});
    $adhtml .= "<h4 style='float: left; margin-bottom: 2px; margin-top: 2px; clear: both;'>$label</h4>\n";

    # use adcall_url from hook if it specified one
    $adcall_url ||= $LJ::ADSERVER;

    # final adcall urls for iframe/js serving types
    my $iframe_url   = $hook_did_adurl ? $adcall_url : "$adcall_url/show?$adparams";
    my $js_url       = $hook_did_adurl ? $adcall_url : "$adcall_url/js/?$adparams";

    # For leaderboards, entryboxes, and box ads, show links on the top right
    if ($adcall{adunit} =~ /^leaderboard/ || $adcall{adunit} =~ /^entrybox/ || $adcall{adunit} =~ /^medrect/) {
        $adhtml .= "<div style='float: right; margin-bottom: 3px; padding-top: 0px; line-height: 1em; white-space: nowrap;'>\n";

        if ($LJ::IS_DEV_SERVER || exists $LJ::DEBUG{'ad_url_markers'}) {
            my $marker = $LJ::DEBUG{'ad_url_markers'} || '#';
            # This is so while working on ad related problems I can easily open the iframe in a new window
            $adhtml .= "<a href=\"$iframe_url\">$marker</a> | \n";
        }
        $adhtml .= "<a href='$LJ::SITEROOT/manage/account/adsettings.bml'>" . LJ::Lang::ml('web.ads.customize') . "</a>\n";
        $adhtml .= "</div>\n";
    }

    if ($debug) {
        my $ehpub = LJ::ehtml($pubtext) || "[no text targeting]";
        $adhtml .= "<div style='width: $adcall{width}px; height: $adcall{height}px; border: 1px solid green; color: #ff0000'>$ehpub</div>\n";
    } else {
        # Iframe with call to ad targeting server
        my $dim_style = join("; ",
                             "width: " . LJ::ehtml($adcall{width}) . "px",
                             "height: " . LJ::ehtml($adcall{height}) . "px" );

        # Call ad via JavaScript or iframe
        if ($use_js_adcall && ! $hook_did_adurl) {
            # TODO: Makes sure these ad calls don't get cached
            $adhtml .= "<div id=\"ad$adid\" style='$dim_style; clear: left'>";
            $adhtml .= "<script id=\"ad${adid}s\" defersrc=\"$js_url\"></script>";
            $adhtml .= "</div>";
        } else {
            $adhtml .= "<iframe src='$iframe_url' frameborder='0' scrolling='no' id='adframe' style='$dim_style'></iframe>";
        }
    }

    # For non-leaderboards, non-entryboxes, and non-box ads, show links on the bottom right
    unless ($adcall{adunit} =~ /^leaderboard/ || $adcall{adunit} =~ /^entrybox/ || $adcall{adunit} =~ /^medrect/) {
        $adhtml .= "<div style='text-align: right; margin-top: 2px; white-space: nowrap;'>\n";
        if ($LJ::IS_DEV_SERVER || exists $LJ::DEBUG{'ad_url_markers'}) {
            my $marker = $LJ::DEBUG{'ad_url_markers'} || '#';
            # This is so while working on ad related problems I can easily open the iframe in a new window
            $adhtml .= "<a href=\"$iframe_url\">$marker</a> | \n";
        }
        $adhtml .= "<a href='$LJ::SITEROOT/manage/account/adsettings.bml'>" . LJ::Lang::ml('web.ads.customize') . "</a>\n";
        $adhtml .= "</div>\n";
    }
    $adhtml .= "</div>\n";

    LJ::run_hooks('notify_ad_block', $adhtml);
    $LJ::ADV_PER_PAGE++;
    return $adhtml;
}

# this function will filter out blocked interests, as well filter out interests which
# cause the 
sub interests_for_adcall {
    my $u = shift;
    my %opts = @_;

    # base ad call is 300-400 bytes, we'll allow interests to be around 600
    # which is unlikely to go over IE's 1k URL limit.
    my $max_len = $opts{max_len} || 600;

    my $int_len = 0;

    my @interest_list = $u->notable_interests(100);

    # pass in special interest if this ad relates to the QotD
    if ($opts{extra} && $opts{extra} eq "qotd") {
        my $extra = LJ::run_hook("qotd_tag", $u);
        unshift @interest_list, $extra if $extra;
    }

    return join(',', 
                grep { 

                    # not a blocked interest
                    ! defined $LJ::AD_BLOCKED_INTERESTS{$_} && 

                    # and we've not already got over 768 bytes of interests
                    # -- +1 is for comma
                    ($int_len += length($_) + 1) <= $max_len;
                        
                    } @interest_list
                );
}

# for use when calling an ad from BML directly
sub ad_display {
    my %opts = @_;

    # can specify whether the wrapper div on the ad is used or not
    my $use_wrapper = defined $opts{use_wrapper} ? $opts{use_wrapper} : 1;

    my $ret = LJ::ads(%opts);

    my $extra;
    if ($ret =~ /"ljad ljad(.+?)"/i) {
        # Add a badge ad above all skyscrapers
        # First, try to print a badge ad in journal context (e.g. S1 comment pages)
        # Then, if it doesn't print, print it in user context (e.g. normal app pages)
        if ($1 eq "skyscraper") {
            $extra = LJ::ads(type => $opts{'type'},
                             orient => 'Journal-Badge',
                             user => $opts{'user'},
                             search_arg => $opts{'search_arg'},
                             force => '1' );
            $extra = LJ::ads(type => $opts{'type'},
                             orient => 'App-Extra',
                             user => $opts{'user'},
                             search_arg => $opts{'search_arg'},
                             force => '1' )
                        unless $extra;
        }
        $ret = $extra . $ret
    }

    my $pagetype = $opts{orient};
    $pagetype =~ s/^BML-//;
    $pagetype = lc $pagetype;

    $ret = $opts{below_ad} ? "$ret<br />$opts{below_ad}" : $ret;
    $ret = $ret && $use_wrapper ? "<div class='ljadwrapper-$pagetype'>$ret</div>" : $ret;

    return $ret;
}

sub control_strip
{
    my %opts = @_;
    my $user = delete $opts{user};

    my $journal = LJ::load_user($user);
    my $show_strip = 1;
    if (LJ::are_hooks("show_control_strip")) {
        $show_strip = LJ::run_hook("show_control_strip", { user => $user });
    }

    return "" unless $show_strip;

    my $remote = LJ::get_remote();

    my $r = Apache->request;
    my $args = scalar $r->args;
    my $querysep = $args ? "?" : "";
    my $uri = "http://" . $r->header_in("Host") . $r->uri . $querysep . $args;
    $uri = LJ::eurl($uri);

    # Build up some common links
    my %links = (
                 'login'             => "<a href='$LJ::SITEROOT/?returnto=$uri'>$BML::ML{'web.controlstrip.links.login'}</a>",
                 'post_journal'      => "<a href='$LJ::SITEROOT/update.bml'>$BML::ML{'web.controlstrip.links.post2'}</a>",
                 'home'              => "<a href='$LJ::SITEROOT/'>" . $BML::ML{'web.controlstrip.links.home'} . "</a>",
                 'recent_comments'   => "<a href='$LJ::SITEROOT/tools/recent_comments.bml'>$BML::ML{'web.controlstrip.links.recentcomments'}</a>",
                 'manage_friends'    => "<a href='$LJ::SITEROOT/friends/'>$BML::ML{'web.controlstrip.links.managefriends'}</a>",
                 'manage_entries'    => "<a href='$LJ::SITEROOT/editjournal.bml'>$BML::ML{'web.controlstrip.links.manageentries'}</a>",
                 'invite_friends'    => "<a href='$LJ::SITEROOT/friends/invite.bml'>$BML::ML{'web.controlstrip.links.invitefriends'}</a>",
                 'create_account'    => "<a href='$LJ::SITEROOT/create.bml'>" . BML::ml('web.controlstrip.links.create', {'sitename' => $LJ::SITENAMESHORT}) . "</a>",
                 'syndicated_list'   => "<a href='$LJ::SITEROOT/syn/list.bml'>$BML::ML{'web.controlstrip.links.popfeeds'}</a>",
                 'learn_more'        => LJ::run_hook('control_strip_learnmore_link') || "<a href='$LJ::SITEROOT/'>$BML::ML{'web.controlstrip.links.learnmore'}</a>",
                 'explore'           => "<a href='$LJ::SITEROOT/explore/'>" . BML::ml('web.controlstrip.links.explore', { sitenameabbrev => $LJ::SITENAMEABBREV }) . "</a>",
                 );

    if ($remote) {
        if ($remote->can_see_content_flag_button( content => $journal )) {
            my $flag_url = LJ::ContentFlag->adult_flag_url($journal);
            $links{'flag'} = "<a href='" . $flag_url . "'>" . LJ::Lang::ml('web.controlstrip.links.flag') . "</a>";
        }

        $links{'view_friends_page'} = "<a href='" . $remote->journal_base . "/friends/'>$BML::ML{'web.controlstrip.links.viewfriendspage2'}</a>";
        $links{'add_friend'} = "<a href='$LJ::SITEROOT/friends/add.bml?user=$journal->{user}'>$BML::ML{'web.controlstrip.links.addfriend'}</a>";
        if ($journal->is_syndicated || $journal->is_news) {
            $links{'add_friend'} = "<a href='$LJ::SITEROOT/friends/add.bml?user=$journal->{user}'>$BML::ML{'web.controlstrip.links.addfeed'}</a>";
            $links{'remove_friend'} = "<a href='$LJ::SITEROOT/friends/add.bml?user=$journal->{user}'>$BML::ML{'web.controlstrip.links.removefeed'}</a>";
        }
        if ($journal->is_community) {
            $links{'join_community'}   = "<a href='$LJ::SITEROOT/community/join.bml?comm=$journal->{user}'>$BML::ML{'web.controlstrip.links.joincomm'}</a>";
            $links{'leave_community'}  = "<a href='$LJ::SITEROOT/community/leave.bml?comm=$journal->{user}'>$BML::ML{'web.controlstrip.links.leavecomm'}</a>";
            $links{'watch_community'}  = "<a href='$LJ::SITEROOT/friends/add.bml?user=$journal->{user}'>$BML::ML{'web.controlstrip.links.watchcomm'}</a>";
            $links{'unwatch_community'}   = "<a href='$LJ::SITEROOT/community/leave.bml?comm=$journal->{user}'>$BML::ML{'web.controlstrip.links.removecomm'}</a>";
            $links{'post_to_community'}   = "<a href='$LJ::SITEROOT/update.bml?usejournal=$journal->{user}'>$BML::ML{'web.controlstrip.links.postcomm'}</a>";
            $links{'edit_community_profile'} = "<a href='$LJ::SITEROOT/manage/profile/?authas=$journal->{user}'>$BML::ML{'web.controlstrip.links.editcommprofile'}</a>";
            $links{'edit_community_invites'} = "<a href='$LJ::SITEROOT/community/sentinvites.bml?comm=$journal->{user}'>$BML::ML{'web.controlstrip.links.managecomminvites'}</a>";
            $links{'edit_community_members'} = "<a href='$LJ::SITEROOT/community/members.bml?comm=$journal->{user}'>$BML::ML{'web.controlstrip.links.editcommmembers'}</a>";
        }
    }
    my $journal_display = LJ::ljuser($journal);
    my %statustext = (
                    'yourjournal'       => $BML::ML{'web.controlstrip.status.yourjournal'},
                    'yourfriendspage'   => $BML::ML{'web.controlstrip.status.yourfriendspage'},
                    'yourfriendsfriendspage' => $BML::ML{'web.controlstrip.status.yourfriendsfriendspage'},
                    'personal'          => BML::ml('web.controlstrip.status.personal', {'user' => $journal_display}),
                    'personalfriendspage' => BML::ml('web.controlstrip.status.personalfriendspage', {'user' => $journal_display}),
                    'personalfriendsfriendspage' => BML::ml('web.controlstrip.status.personalfriendsfriendspage', {'user' => $journal_display}),
                    'community'         => BML::ml('web.controlstrip.status.community', {'user' => $journal_display}),
                    'syn'               => BML::ml('web.controlstrip.status.syn', {'user' => $journal_display}),
                    'news'              => BML::ml('web.controlstrip.status.news', {'user' => $journal_display, 'sitename' => $LJ::SITENAMESHORT}),
                    'other'             => BML::ml('web.controlstrip.status.other', {'user' => $journal_display}),
                    'mutualfriend'      => BML::ml('web.controlstrip.status.mutualfriend', {'user' => $journal_display}),
                    'friend'            => BML::ml('web.controlstrip.status.friend', {'user' => $journal_display}),
                    'friendof'          => BML::ml('web.controlstrip.status.friendof', {'user' => $journal_display}),
                    'maintainer'        => BML::ml('web.controlstrip.status.maintainer', {'user' => $journal_display}),
                    'memberwatcher'     => BML::ml('web.controlstrip.status.memberwatcher', {'user' => $journal_display}),
                    'watcher'           => BML::ml('web.controlstrip.status.watcher', {'user' => $journal_display}),
                    'member'            => BML::ml('web.controlstrip.status.member', {'user' => $journal_display}),
                    );
    # Style the status text
    foreach my $key (keys %statustext) {
        $statustext{$key} = "<span id='lj_controlstrip_statustext'>" . $statustext{$key} . "</span>";
    }

    my $ret;
    if ($remote) {
        my $remote_display  = LJ::ljuser($remote);
        if ($remote->{'defaultpicid'}) {
            my $url = "$LJ::USERPIC_ROOT/$remote->{'defaultpicid'}/$remote->{'userid'}";
            $ret .= "<td id='lj_controlstrip_userpic' style='background-image: none;'><a href='$LJ::SITEROOT/editpics.bml'><img src='$url' alt=\"$BML::ML{'web.controlstrip.userpic.alt'}\" title=\"$BML::ML{'web.controlstrip.userpic.title'}\" height='43' /></a></td>";
        } else {
            my $tinted_nouserpic_img = "";

            if ($journal->prop('stylesys') == 2) {
                my $ctx = $LJ::S2::CURR_CTX;
                my $custom_nav_strip = S2::get_property_value($ctx, "custom_control_strip_colors");

                if ($custom_nav_strip ne "off") {
                    my $linkcolor = S2::get_property_value($ctx, "control_strip_linkcolor");

                    if ($linkcolor ne "") {
                        $tinted_nouserpic_img = S2::Builtin::LJ::palimg_modify($ctx, "controlstrip/nouserpic.gif", [S2::Builtin::LJ::PalItem($ctx, 0, $linkcolor)]);
                    }
                }
            }
            $ret .= "<td id='lj_controlstrip_userpic' style='background-image: none;'><a href='$LJ::SITEROOT/editpics.bml'>";
            if ($tinted_nouserpic_img eq "") {
                $ret .= "<img src='$LJ::IMGPREFIX/controlstrip/nouserpic.gif' alt=\"$BML::ML{'web.controlstrip.nouserpic.alt'}\" title=\"$BML::ML{'web.controlstrip.nouserpic.title'}\" height='43' />";
            } else {
                $ret .= "<img src='$tinted_nouserpic_img' alt=\"$BML::ML{'web.controlstrip.nouserpic.alt'}\" title=\"$BML::ML{'web.controlstrip.nouserpic.title'}\" height='43' />";
            }
            $ret .= "</a></td>";
        }
        $ret .= "<td id='lj_controlstrip_user' nowrap='nowrap'><form id='Greeting' class='nopic' action='$LJ::SITEROOT/logout.bml?ret=1' method='post'><div>";
        $ret .= "<input type='hidden' name='user' value='$remote->{'user'}' />";
        $ret .= "<input type='hidden' name='sessid' value='$remote->{'_session'}->{'sessid'}' />"
            if $remote->session;
        my $logout = "<input type='submit' value=\"$BML::ML{'web.controlstrip.btn.logout'}\" id='Logout' />";
        $ret .= "$remote_display $logout";
        $ret .= "</div></form>\n";
        $ret .= "$links{'home'}&nbsp;&nbsp; $links{'post_journal'}&nbsp;&nbsp; $links{'view_friends_page'}";
        $ret .= "</td>\n";

        $ret .= "<td id='lj_controlstrip_actionlinks' nowrap='nowrap'>";
        if (LJ::u_equals($remote, $journal)) {
            if ($r->notes('view') eq "friends") {
                $ret .= $statustext{'yourfriendspage'};
            } elsif ($r->notes('view') eq "friendsfriends") {
                $ret .= $statustext{'yourfriendsfriendspage'};
            } else {
                $ret .= $statustext{'yourjournal'};
            }
            $ret .= "<br />";
            if ($r->notes('view') eq "friends") {
                my @filters = ("all", $BML::ML{'web.controlstrip.select.friends.all'}, "showpeople", $BML::ML{'web.controlstrip.select.friends.journals'}, "showcommunities", $BML::ML{'web.controlstrip.select.friends.communities'}, "showsyndicated", $BML::ML{'web.controlstrip.select.friends.feeds'});
                my %res;
                # FIXME: make this use LJ::Protocol::do_request
                LJ::do_request({ 'mode' => 'getfriendgroups',
                                 'ver'  => $LJ::PROTOCOL_VER,
                                 'user' => $remote->{'user'}, },
                               \%res, { 'noauth' => 1, 'userid' => $remote->{'userid'} });
                my %group;
                foreach my $k (keys %res) {
                    if ($k =~ /^frgrp_(\d+)_name/) {
                        $group{$1}->{'name'} = $res{$k};
                    }
                    elsif ($k =~ /^frgrp_(\d+)_sortorder/) {
                        $group{$1}->{'sortorder'} = $res{$k};
                    }
                }
                foreach my $g (sort { $group{$a}->{'sortorder'} <=> $group{$b}->{'sortorder'} } keys %group) {
                    push @filters, "filter:" . lc($group{$g}->{'name'}), $group{$g}->{'name'};
                }

                my $selected = "all";
                if ($r->uri eq "/friends" && $r->args ne "") {
                    $selected = "showpeople"      if $r->args eq "show=P&filter=0";
                    $selected = "showcommunities" if $r->args eq "show=C&filter=0";
                    $selected = "showsyndicated"  if $r->args eq "show=Y&filter=0";
                } elsif ($r->uri =~ /^\/friends\/?(.+)?/i) {
                    my $filter = $1 || "default view";
                    $selected = "filter:" . LJ::durl(lc($filter));
                }

                $ret .= "$links{'manage_friends'}&nbsp;&nbsp; ";
                $ret .= "$BML::ML{'web.controlstrip.select.friends.label'} <form method='post' style='display: inline;' action='$LJ::SITEROOT/friends/filter.bml'>\n";
                $ret .= LJ::html_hidden("user", $remote->{'user'}, "mode", "view", "type", "allfilters");
                $ret .= LJ::html_select({'name' => "view", 'selected' => $selected }, @filters) . " ";
                $ret .= LJ::html_submit($BML::ML{'web.controlstrip.btn.view'});
                $ret .= "</form>";
                # drop down for various groups and show values
            } else {
                $ret .= "$links{'recent_comments'}&nbsp;&nbsp; $links{'manage_entries'}&nbsp;&nbsp; $links{'invite_friends'}";
            }
        } elsif ($journal->is_personal || $journal->is_identity) {
            my $friend = LJ::is_friend($remote, $journal);
            my $friendof = LJ::is_friend($journal, $remote);

            if ($friend and $friendof) {
                $ret .= "$statustext{'mutualfriend'}<br />";
                $ret .= "$links{'manage_friends'}";
            } elsif ($friend) {
                $ret .= "$statustext{'friend'}<br />";
                $ret .= "$links{'manage_friends'}";
            } elsif ($friendof) {
                $ret .= "$statustext{'friendof'}<br />";
                $ret .= "$links{'add_friend'}";
            } else {
                if ($r->notes('view') eq "friends") {
                    $ret .= $statustext{'personalfriendspage'};
                } elsif ($r->notes('view') eq "friendsfriends") {
                    $ret .= $statustext{'personalfriendsfriendspage'};
                } else {
                    $ret .= $statustext{'personal'};
                }
                $ret .= "<br />$links{'add_friend'}";
            }
        } elsif ($journal->is_community) {
            my $watching = LJ::is_friend($remote, $journal);
            my $memberof = LJ::is_friend($journal, $remote);
            my $haspostingaccess = LJ::check_rel($journal, $remote, 'P');
            if (LJ::can_manage_other($remote, $journal)) {
                $ret .= "$statustext{'maintainer'}<br />";
                if ($haspostingaccess) {
                    $ret .= "$links{'post_to_community'}&nbsp;&nbsp; ";
                }
                $ret .= "$links{'edit_community_profile'}&nbsp;&nbsp; $links{'edit_community_invites'}&nbsp;&nbsp; $links{'edit_community_members'}";
            } elsif ($watching && $memberof) {
                $ret .= "$statustext{'memberwatcher'}<br />";
                if ($haspostingaccess) {
                    $ret .= "$links{'post_to_community'}&nbsp;&nbsp; ";
                }
                $ret .= $links{'leave_community'};
            } elsif ($watching) {
                $ret .= "$statustext{'watcher'}<br />";
                if ($haspostingaccess) {
                    $ret .= "$links{'post_to_community'}&nbsp;&nbsp; ";
                }
                $ret .= "$links{'join_community'}&nbsp;&nbsp; $links{'unwatch_community'}";
            } elsif ($memberof) {
                $ret .= "$statustext{'member'}<br />";
                if ($haspostingaccess) {
                    $ret .= "$links{'post_to_community'}&nbsp;&nbsp; ";
                }
                $ret .= "$links{'watch_community'}&nbsp;&nbsp; $links{'leave_community'}";
            } else {
                $ret .= "$statustext{'community'}<br />";
                if ($haspostingaccess) {
                    $ret .= "$links{'post_to_community'}&nbsp;&nbsp; ";
                }
                $ret .= "$links{'join_community'}&nbsp;&nbsp; $links{'watch_community'}";
            }
        } elsif ($journal->is_syndicated) {
            $ret .= "$statustext{'syn'}<br />";
            if ($remote && !LJ::is_friend($remote, $journal)) {
                $ret .= "$links{'add_friend'}&nbsp;&nbsp; ";
            } elsif ($remote && LJ::is_friend($remote, $journal)) {
                $ret .= "$links{'remove_friend'}&nbsp;&nbsp; ";
            }
            $ret .= $links{'syndicated_list'};
        } elsif ($journal->is_news) {
            $ret .= "$statustext{'news'}<br />";
            if ($remote && !LJ::is_friend($remote, $journal)) {
                $ret .= $links{'add_friend'};
            } else {
                $ret .= "&nbsp;";
            }
        } else {
            $ret .= "$statustext{'other'}<br />";
            $ret .= "&nbsp;";
        }

        if ($remote->can_see_content_flag_button( content => $journal )) {
            $ret .= "&nbsp;&nbsp; $links{flag}";
        }

        $ret .= LJ::run_hook('control_strip_logo', $remote, $journal);
        $ret .= "</td>";

    } else {

        my $show_login_form = LJ::run_hook("show_control_strip_login_form", $journal);
        $show_login_form = 1 if !defined $show_login_form;

        if ($show_login_form) {
            my $chal = LJ::challenge_generate(300);
            my $contents = LJ::run_hook('control_strip_userpic_contents', $uri) || "&nbsp;";
            $ret .= <<"LOGIN_BAR";
                <td id='lj_controlstrip_userpic'>$contents</td>
                <td id='lj_controlstrip_login' style='background-image: none;' nowrap='nowrap'><form id="login" class="lj_login_form" action="$LJ::SITEROOT/login.bml?ret=1" method="post"><div>
                <input type="hidden" name="mode" value="login" />
                <input type='hidden' name='chal' id='login_chal' class='lj_login_chal' value='$chal' />
                <input type='hidden' name='response' id='login_response' class='lj_login_response' value='' />
                <table cellspacing="0" cellpadding="0" style="margin-right: 1em;"><tr><td>
                <label for="xc_user">$BML::ML{'/login.bml.login.username'}</label> <input type="text" name="user" size="7" maxlength="17" tabindex="1" id="xc_user" value="" />
                </td><td>
                <label style="margin-left: 3px;" for="xc_password">$BML::ML{'/login.bml.login.password'}</label> <input type="password" name="password" size="7" tabindex="2" id="xc_password" class='lj_login_password' />
LOGIN_BAR
            $ret .= "<input type='submit' value=\"$BML::ML{'web.controlstrip.btn.login'}\" tabindex='4' />";
            $ret .= "</td></tr>";

            $ret .= "<tr><td valign='top'>";
            $ret .= "<a href='$LJ::SITEROOT/lostinfo.bml'>$BML::ML{'web.controlstrip.login.forgot'}</a>";
            $ret .= "</td><td style='font: 10px Arial, Helvetica, sans-serif;' valign='top' colspan='2' align='right'>";
            $ret .= "<input type='checkbox' id='xc_remember' name='remember_me' style='height: 10px; width: 10px;' tabindex='3' />";
            $ret .= "<label for='xc_remember'>$BML::ML{'web.controlstrip.login.remember'}</label>";
            $ret .= "</td></tr></table>";

            $ret .= '</div></form></td>';
        } else {
            my $contents = LJ::run_hook('control_strip_loggedout_userpic_contents', $uri) || "&nbsp;";
            $ret .= "<td id='lj_controlstrip_loggedout_userpic'>$contents</td>";
        }

        $ret .= "<td id='lj_controlstrip_actionlinks' nowrap='nowrap'>";

        if ($journal->is_personal || $journal->is_identity) {
            if ($r->notes('view') eq "friends") {
                $ret .= $statustext{'personalfriendspage'};
            } elsif ($r->notes('view') eq "friendsfriends") {
                $ret .= $statustext{'personalfriendsfriendspage'};
            } else {
                $ret .= $statustext{'personal'};
            }
        } elsif ($journal->is_community) {
            $ret .= $statustext{'community'};
        } elsif ($journal->is_syndicated) {
            $ret .= $statustext{'syn'};
        } elsif ($journal->is_news) {
            $ret .= $statustext{'news'};
        } else {
            $ret .= $statustext{'other'};
        }

        $ret .= "<br />";
        $ret .= "$links{'login'}&nbsp;&nbsp; " unless $show_login_form;
        $ret .= "$links{'create_account'}&nbsp;&nbsp; $links{'learn_more'}";
        $ret .= LJ::run_hook('control_strip_logo', $remote, $journal);
        $ret .= "</td>";
    }

    LJ::run_hooks('add_extra_cells_in_controlstrip', \$ret);

    return "<table id='lj_controlstrip' cellpadding='0' cellspacing='0'><tr valign='top'>$ret</tr></table>";
}

sub control_strip_js_inject
{
    my %opts = @_;
    my $user = delete $opts{user};

    my $ret;

    $ret .= "<script src='$LJ::JSPREFIX/core.js' type='text/javascript'></script>\n";
    $ret .= "<script src='$LJ::JSPREFIX/dom.js' type='text/javascript'></script>\n";
    $ret .= "<script src='$LJ::JSPREFIX/httpreq.js' type='text/javascript'></script>\n";

    LJ::need_res(qw(
                    js/livejournal.js
                    js/md5.js
                    js/login.js
                    ));

    $ret .= qq{
<script type='text/javascript'>
    function controlstrip_init() {
        if (! \$('lj_controlstrip') ){
            HTTPReq.getJSON({
              url: "/$user/__rpc_controlstrip?user=$user",
              onData: function (data) {
                  var body = document.getElementsByTagName("body")[0];
                  var div = document.createElement("div");
                  div.innerHTML = data;
                      body.appendChild(div);
              },
              onError: function (msg) { }
            });
        }
    }
    DOM.addEventListener(window, "load", controlstrip_init);
</script>
    };
    return $ret;
}

# For the Rich Text Editor
# Set JS variables for use by the RTE
sub rte_js_vars {
    my ($remote) = @_;

    my $ret = '';
    # The JS var canmakepoll is used by fckplugin.js to change the behaviour
    # of the poll button in the RTE.
    # Also remove any RTE buttons that have been set to disabled.
    my $canmakepoll = "true";
    $canmakepoll = "false" if ($remote && !LJ::get_cap($remote, 'makepoll'));
    $ret .= "<script type='text/javascript'>\n";
    $ret .= "    var RTEdisabled = new Array();\n";
    my $rte_disabled = $LJ::DISABLED{rte_buttons} || {};
    foreach my $key (keys %$rte_disabled) {
        $ret .= "    RTEdisabled['$key'] = true;" if $rte_disabled->{$key};
    }
    $ret .= qq^
        var canmakepoll = $canmakepoll;

        function removeDisabled(ToolbarSet) {
            for (var i=0; i<ToolbarSet.length; i++) {
                for (var j=0; j<ToolbarSet[i].length; j++) {
                    if (RTEdisabled[ToolbarSet[i][j]] == true) ToolbarSet[i].splice(j,1);
                }
            }
        }
    </script>^;

    return $ret;
}

# prints out UI for subscribing to some events
sub subscribe_interface {
    my ($u, %opts) = @_;

    croak "subscribe_interface wants a \$u" unless LJ::isu($u);

    my $catref       = delete $opts{'categories'};
    my $journalu     = delete $opts{'journal'} || LJ::get_remote();
    my $formauth     = delete $opts{'formauth'} || LJ::form_auth();
    my $showtracking = delete $opts{'showtracking'} || 0;
    my $getextra     = delete $opts{'getextra'} || '';
    my $ret_url      = delete $opts{ret_url} || '';
    my $def_notes    = delete $opts{'default_selected_notifications'} || [];

    croak "Invalid user object passed to subscribe_interface" unless LJ::isu($journalu);

    croak "Invalid options passed to subscribe_interface" if (scalar keys %opts);

    LJ::need_res('stc/esn.css');
    LJ::need_res('js/core.js');
    LJ::need_res('js/dom.js');
    LJ::need_res('js/checkallbutton.js');
    LJ::need_res('js/esn.js');

    my @categories = $catref ? @$catref : ();

    my $ret = qq {
            <div id="manageSettings">
            <span class="esnlinks"><a href="$LJ::SITEROOT/inbox/">Inbox</a> | Manage Settings</span>
            <form method='POST' action='$LJ::SITEROOT/manage/subscriptions/$getextra'>
            $formauth
    };

    my $events_table = '<table class="Subscribe" cellpadding="0" cellspacing="0">';

    my @notify_classes = LJ::NotificationMethod->all_classes or return "No notification methods";

    # skip the inbox type; it's always on
    @notify_classes = grep { $_ ne 'LJ::NotificationMethod::Inbox' } @notify_classes;

    my $tracking = [];

    # title of the tracking category
    my $tracking_cat = "Notices";

    # if showtracking, add things the user is tracking to the categories
    if ($showtracking) {
        my @subscriptions = $u->find_subscriptions(method => 'Inbox');

        foreach my $subsc ( sort {$a->id <=> $b->id } @subscriptions ) {
            # if this event class is already being displayed above, skip over it
            my $etypeid = $subsc->etypeid or next;
            my ($evt_class) = (LJ::Event->class($etypeid) =~ /LJ::Event::(.+)/i);
            next unless $evt_class;

            # search for this class in categories
            next if grep { $_ eq $evt_class } map { @$_ } map { values %$_ } @categories;

            push @$tracking, $subsc;
        }
    }

    push @categories, {$tracking_cat => $tracking};

    my @catids;
    my $catid = 0;

    my %shown_subids = ();

    foreach my $cat_hash (@categories) {
        my ($category, $cat_events) = %$cat_hash;

        push @catids, $catid;

        # pending subscription objects
        my $pending = [];

        my $cat_empty = 1;
        my $cat_html = '';

        # is this category the tracking category?
        my $is_tracking_category = $category eq $tracking_cat;

        # build table of subscribeble events
        foreach my $cat_event (@$cat_events) {
            if ((ref $cat_event) =~ /Subscription/) {
                push @$pending, $cat_event;
            } else {
                my $pending_sub = LJ::Subscription::Pending->new($u,
                                                                 event => $cat_event,
                                                                 journal => $journalu);
                push @$pending, $pending_sub;
            }
        }

        $cat_html .= qq {
            <div class="CategoryRow-$catid">
                <tr class="CategoryRow">
                <td>
                <span class="CategoryHeading">$category</span>
                <span class="CategoryHeadingNote">Notify me when...</span>
                </td>
                <td class="Caption">
                By
                </td>
            };

        my @pending_subscriptions;
        # build list of subscriptions to show the user
        {
            unless ($is_tracking_category) {
                foreach my $pending_sub (@$pending) {
                    my %sub_args = $pending_sub->sub_info;
                    delete $sub_args{ntypeid};
                    $sub_args{method} = 'Inbox';

                    my @existing_subs = $u->has_subscription(%sub_args);
                    push @pending_subscriptions, (scalar @existing_subs ? @existing_subs : $pending_sub);
                }
            } else {
                push @pending_subscriptions, @$tracking;
            }
        }

        # add notifytype headings
        foreach my $notify_class (@notify_classes) {
            my $title = eval { $notify_class->title($u) } or next;
            my $ntypeid = $notify_class->ntypeid or next;

            # create the checkall box for this event type.
            my $disabled = ! $notify_class->configured_for_user($u);

            if ($notify_class->disabled_url && $disabled) {
                $title = "<a href='" . $notify_class->disabled_url . "'>$title</a>";
            } elsif ($notify_class->url) {
                $title = "<a href='" . $notify_class->url . "'>$title</a>";
            }

            my $checkall_box = LJ::html_check({
                id       => "CheckAll-$catid-$ntypeid",
                label    => $title,
                class    => "CheckAll",
                noescape => 1,
                disabled => $disabled,
            });

            $cat_html .= qq {
                <td>
                    $checkall_box
                    </td>
                };
        }

        $cat_html .= '</tr>';

        # inbox method
        foreach my $pending_sub (@pending_subscriptions) {
            # print option to subscribe to this event, checked if already subscribed
            my $input_name = $pending_sub->freeze or next;
            my $title      = $pending_sub->as_html or next;
            my $subscribed = ! $pending_sub->pending;

            unless ($pending_sub->enabled) {
                $title = LJ::run_hook("disabled_esn_sub") . $title;
            }
            next if ! $pending_sub->event_class->is_visible && $showtracking;

            my $evt_class = $pending_sub->event_class or next;
            unless ($is_tracking_category) {
                next unless eval { $evt_class->subscription_applicable($pending_sub) };
                next if LJ::u_equals($journalu, $u) && $pending_sub->journalid && $pending_sub->journalid != $u->{userid};
            } else {
                my $no_show = 0;

                foreach my $cat_info_ref (@$catref) {
                    while (my ($_cat_name, $_cat_events) = each %$cat_info_ref) {
                        foreach my $_cat_event (@$_cat_events) {
                            unless (ref $_cat_event) {
                                $_cat_event = LJ::Subscription::Pending->new($u, event => $_cat_event);
                            }
                            next unless $pending_sub->equals($_cat_event);
                            $no_show = 1;
                            last;
                        }
                    }
                }

                next if $no_show;
            }

            my $selected = $pending_sub->default_selected;

            my $inactiveclass = $pending_sub->active ? '' : 'Inactive';
            my $disabledclass = $pending_sub->enabled ? '' : 'Disabled';

            $cat_html  .= "<tr class='$inactiveclass $disabledclass'><td>";

            if ($is_tracking_category && ! $pending_sub->pending) {
                my $subid = $pending_sub->id;
                $cat_html .= qq {
                    <a href='?deletesub_$subid=1'><img src="$LJ::IMGPREFIX/portal/btn_del.gif" /></a>
                };
            }
            my $always_checked = eval { "$evt_class"->always_checked; };
            my $disabled = $always_checked ? 1 : !$pending_sub->enabled;

            $cat_html  .= LJ::html_check({
                id       => $input_name,
                name     => $input_name,
                class    => "SubscriptionInboxCheck",
                selected => $selected,
                noescape => 1,
                label    => $title,
                disabled => $disabled,
            }) .  "</td>";

            unless ($pending_sub->pending) {
                $cat_html .= LJ::html_hidden({
                    name  => "${input_name}-old",
                    value => $subscribed,
                });
            }

            $shown_subids{$pending_sub->id}++ unless $pending_sub->pending;

            $cat_empty = 0;

            # print out notification options for this subscription (hidden if not subscribed)
            $cat_html .= "<td>&nbsp;</td>";
            my $hidden = ($pending_sub->default_selected || ($subscribed && $pending_sub->active)) ? '' : 'style="visibility: hidden;"';

            # is there an inbox notification for this?
            my %sub_args = $pending_sub->sub_info;
            $sub_args{ntypeid} = LJ::NotificationMethod::Inbox->ntypeid;
            delete $sub_args{flags};
            my ($inbox_sub) = $u->find_subscriptions(%sub_args);

            foreach my $note_class (@notify_classes) {
                my $ntypeid = eval { $note_class->ntypeid } or next;

                $sub_args{ntypeid} = $ntypeid;
                my @subs = $u->has_subscription(%sub_args);

                my $note_pending = LJ::Subscription::Pending->new($u, %sub_args);
                if (@subs) {
                    $note_pending = $subs[0];
                }

                if (($is_tracking_category || $pending_sub->is_tracking_category) && $note_pending->pending) {
                    # flag this as a "tracking" subscription
                    $note_pending->set_tracking;
                }

                my $notify_input_name = $note_pending->freeze;

                # select email method by default
                my $note_selected = (scalar @subs) ? 1 : (!$selected && $note_class eq 'LJ::NotificationMethod::Email');

                # check the box if it's marked as being selected by default UNLESS
                # there exists an inbox subscription and no email subscription
                $note_selected = 1 if (! $inbox_sub || scalar @subs) && $selected && grep { $note_class eq $_ } @$def_notes;
                $note_selected &&= $note_pending->active && $note_pending->enabled;

                my $disabled = ! $pending_sub->enabled;
                $disabled = 1 unless $note_class->configured_for_user($u);

                $cat_html .= qq {
                    <td class='NotificationOptions' $hidden>
                    } . LJ::html_check({
                        id       => $notify_input_name,
                        name     => $notify_input_name,
                        class    => "SubscribeCheckbox-$catid-$ntypeid",
                        selected => $note_selected,
                        noescape => 1,
                        disabled => $disabled,
                    }) . '</td>';

                unless ($note_pending->pending) {
                    $cat_html .= LJ::html_hidden({
                        name  => "${notify_input_name}-old",
                        value => (scalar @subs) ? 1 : 0,
                    });
                }
            }
        }

        # show blurb if not tracking anything
        if ($cat_empty && $is_tracking_category) {
            my $blurb = qq {
                <?p To start getting notices, click on the
                    <img src="$LJ::SITEROOT/img/btn_track.gif" width="22" height="20" valign="absmiddle" alt="Notify Me"/>
                    icon when you are
                    browsing $LJ::SITENAMESHORT. You can use notices to keep an eye on comment threads,
                    user updates and new posts. p?>

            };

            my $cols = 2 + (scalar @notify_classes);
            $cat_html .= "<td colspan='$cols'>$blurb</td>";
        }

        $cat_html .= '</tr></div>';
        $events_table .= $cat_html unless ($is_tracking_category && !$showtracking);

        $catid++;
    }

    $events_table .= '</table>';

    # pass some info to javascript
    my $catids = LJ::html_hidden({
        'id'  => 'catids',
        'value' => join(',', @catids),
    });
    my $ntypeids = LJ::html_hidden({
        'id'  => 'ntypeids',
        'value' => join(',', map { $_->ntypeid } LJ::NotificationMethod->all_classes),
    });

    $ret .= qq {
        $ntypeids
            $catids
            $events_table
        };

    $ret .= LJ::html_hidden({name => 'mode', value => 'save_subscriptions'});
    $ret .= LJ::html_hidden({name => 'ret_url', value => $ret_url});

    # print info stuff
    my $extra_sub_status = LJ::run_hook("sub_status_extra", $u) || '';

    # print buttons
    my $referer = BML::get_client_header('Referer');
    my $uri = $LJ::SITEROOT . Apache->request->uri;

    # normalize the URLs -- ../index.bml doesn't make it a different page.
    $uri =~ s/index\.bml//;
    $referer =~ s/index\.bml//;

    $ret .= $extra_sub_status;

    $ret .= '<?standout ' .
        LJ::html_submit('Save') . ' ' .
        ($referer && $referer ne $uri ? "<input type='button' value='Cancel' onclick='window.location=\"$referer\"' />" : '')
        . '';

    $ret .= "standout?> </div></form>";
}

# returns a placeholder link
sub placeholder_link {
    my (%opts) = @_;

    my $placeholder_html = LJ::ejs_all(delete $opts{placeholder_html} || '');
    my $width  = delete $opts{width}  || 100;
    my $height = delete $opts{height} || 100;
    my $link   = delete $opts{link}   || '';
    my $img    = delete $opts{img}    || "$LJ::IMGPREFIX/videoplaceholder.png";

    return qq {
            <div class="LJ_Placeholder_Container" style="width: ${width}px; height: ${height}px;">
                <div class="LJ_Placeholder_HTML" style="display: none;">$placeholder_html</div>
                <div class="LJ_Container"></div>
                <a href="$link" onclick="return false;">
                    <img src="$img" class="LJ_Placeholder" title="Click to show embedded content" />
                </a>
            </div>
        };
}

# Returns replacement for lj-replace tags
sub lj_replace {
    my $key = shift;
    my $attr = shift;

    # Return hook if hook output not undef
    if (LJ::are_hooks("lj-replace_$key")) {
        my $replace = LJ::run_hook("lj-replace_$key");
        return $replace if defined $replace;
    }

    # Return value of coderef if key defined
    my %valid_keys = ( 'first_post' => \&lj_replace_first_post );

    if (my $cb = $valid_keys{$key}) {
        die "$cb is not a valid coderef" unless ref $cb eq 'CODE';
        return $cb->($attr);
    }

    return undef;
}

# Replace for lj-replace name="first_post"
sub lj_replace_first_post {
    return unless LJ::is_web_context();
    return BML::ml('web.lj-replace.first_post', {
                   'update_link' => "href='$LJ::SITEROOT/update.bml'",
                   });
}

# this returns the right max length for a VARCHAR(255) database
# column.  but in HTML, the maxlength is characters, not bytes, so we
# have to assume 3-byte chars and return 80 instead of 255.  (80*3 ==
# 240, approximately 255).  However, we special-case Russian where
# they often need just a little bit more, and make that 100.  because
# their bytes are only 2, so 100 * 2 == 200.  as long as russians
# don't enter, say, 100 characters of japanese... but then it'd get
# truncated or throw an error.  we'll risk that and give them 20 more
# characters.
sub std_max_length {
    my $lang = eval { BML::get_language() };
    return 80  if !$lang || $lang =~ /^en/;
    return 100 if $lang =~ /\b(hy|az|be|et|ka|ky|kk|lt|lv|mo|ru|tg|tk|uk|uz)\b/i;
    return 80;
}

# Common challenge/response JavaScript, needed by both login pages and comment pages alike.
# Forms that use this should onclick='return sendForm()' in the submit button.
# Returns true to let the submit continue.
$LJ::COMMON_CODE{'chalresp_js'} = qq{
<script type="text/javascript" src="$LJ::JSPREFIX/md5.js"></script>
<script language="JavaScript" type="text/javascript">
    <!--
function sendForm (formid, checkuser)
{
    if (formid == null) formid = 'login';
    // 'checkuser' is the element id name of the username textfield.
    // only use it if you care to verify a username exists before hashing.

    if (! document.getElementById) return true;
    var loginform = document.getElementById(formid);
    if (! loginform) return true;

    // Avoid accessing the password field if there is no username.
    // This works around Opera < 7 complaints when commenting.
    if (checkuser) {
        var username = null;
        for (var i = 0; username == null && i < loginform.elements.length; i++) {
            if (loginform.elements[i].id == checkuser) username = loginform.elements[i];
        }
        if (username != null && username.value == "") return true;
    }

    if (! loginform.password || ! loginform.login_chal || ! loginform.login_response) return true;
    var pass = loginform.password.value;
    var chal = loginform.login_chal.value;
    var res = MD5(chal + MD5(pass));
    loginform.login_response.value = res;
    loginform.password.value = "";  // dont send clear-text password!
    return true;
}
// -->
</script>
};

# Common JavaScript function for auto-checking radio buttons on form
# input field data changes
$LJ::COMMON_CODE{'autoradio_check'} = q{
<script language="JavaScript" type="text/javascript">
    <!--
    /* If radioid exists, check the radio button. */
    function checkRadioButton(radioid) {
        if (!document.getElementById) return;
        var radio = document.getElementById(radioid);
        if (!radio) return;
        radio.checked = true;
    }
// -->
</script>
};

# returns HTML which should appear before </body>
sub final_body_html {
    my $before_body_close = "";
    LJ::run_hooks('insert_html_before_body_close', \$before_body_close);

    my $r = Apache->request;
    if ($r->notes('codepath') eq "bml.talkread" || $r->notes('codepath') eq "bml.talkpost") {
        my $journalu = LJ::load_userid($r->notes('journalid'));
        my $graphicpreviews_obj = LJ::graphicpreviews_obj();
        $before_body_close .= $graphicpreviews_obj->render($journalu);
    }

    return $before_body_close;
}

# return a unique per pageview string based on the remote's unique cookie
sub pageview_unique_string {
    my $cached_uniq = $LJ::REQ_GLOBAL{pageview_unique_string};
    return $cached_uniq if $cached_uniq;

    my $uniq = LJ::UniqCookie->current_uniq . time() . LJ::rand_chars(8);
    $uniq = Digest::SHA1::sha1_hex($uniq);

    $LJ::REQ_GLOBAL{pageview_unique_string} = $uniq;
    return $uniq;
}

# <LJFUNC>
# name: LJ::site_schemes
# class: web
# des: Returns a list of available BML schemes.
# args: none
# return: array
# </LJFUNC>
sub site_schemes {
    my @schemes = @LJ::SCHEMES;
    LJ::run_hooks('modify_scheme_list', \@schemes);
    return @schemes;
}

# returns a random value between 0 and $num_choices-1 for a particular uniq
# if no uniq available, just returns a random value between 0 and $num_choices-1
sub ab_testing_value {
    my %opts = @_;

    return $LJ::DEBUG{ab_testing_value} if defined $LJ::DEBUG{ab_testing_value};

    my $num_choices = $opts{num_choices} || 2;
    my $uniq = LJ::UniqCookie->current_uniq;

    my $val;
    if ($uniq) {
        $val = unpack("I", $uniq);
        $val %= $num_choices;
    } else {
        $val = int(rand($num_choices));
    }

    return $val;
}

1;
