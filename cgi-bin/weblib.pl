#!/usr/bin/perl
#

package LJ;
use strict;

# load the bread crumb hash
require "$ENV{'LJHOME'}/cgi-bin/crumbs.pl";

use Class::Autouse qw(LJ::Event LJ::Subscription::Pending);

# <LJFUNC>
# name: LJ::img
# des: Returns an HTML &lt;img&gt; or &lt;input&gt; tag to an named image
#      code, which each site may define with a different image file with
#      its own dimensions.  This prevents hard-coding filenames & sizes
#      into the source.  The real image data is stored in LJ::Img, which
#      has default values provided in cgi-bin/imageconf.pl but can be
#      overridden in cgi-bin/ljconfig.pl.
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
    if ($type eq "") {
        return "<img src=\"$LJ::IMGPREFIX$i->{'src'}\" width=\"$i->{'width'}\" ".
            "height=\"$i->{'height'}\" alt=\"$i->{'alt'}\" title=\"$i->{'alt'}\" ".
            "border='0'$attrs />";
    }
    if ($type eq "input") {
        return "<input type=\"image\" src=\"$LJ::IMGPREFIX$i->{'src'}\" ".
            "width=\"$i->{'width'}\" height=\"$i->{'height'}\" title=\"$i->{'alt'}\" ".
            "alt=\"$i->{'alt'}\" border='0'$attrs />";
    }
    return "<b>XXX</b>";
}

# <LJFUNC>
# name: LJ::date_to_view_links
# class: component
# des: Returns HTML of date with links to user's journal.
# args: u, date
# des-date: date in yyyy-mm-dd form.
# returns: HTML with yyy, mm, and dd all links to respective views.
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
# des: Takes a plain-text string and changes URLs into <a href> tags (auto-linkification)
# args: str
# arg-str: The string to perform auto-linkification on.
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
# returns: string of html elements
# args: u, opts?
# des-opts: Optional.  Valid keys are:
#           'authas' - current user, gets selected in drop-down
#           'label' - label to go before form elements
#           'button' - button label for submit button
#           others - arguments to pass to LJ::get_authas_list
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
# returns: string of html elements
# args: u, opts?
# des-opts: Optional.  Valid keys are:
#           'postto' - current user, gets selected in drop-down
#           'label' - label to go before form elements
#           'button' - button label for submit button
#           others - arguments to pass to LJ::get_postto_list
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
# des-topic: Help topic key.  See doc/ljconfig.pl.txt for examples.
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
    return "$pre<a href=\"$url\" class=\"helplink\"><img src=\"$LJ::IMGPREFIX/help.gif\" alt=\"Help\" title=\"Help\" width='14' height='14' border='0' /></a>$post";
}

# <LJFUNC>
# name: LJ::bad_input
# des: Returns common BML for reporting form validation errors in
#      a bulletted list.
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
# des: Returns an error bar with bulleted list of errors
# returns: BML showing errors
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
# des: Returns an error telling the user to log in
# returns: Translation string "error.notloggedin"
# </LJFUNC>
sub error_noremote
{
    return BML::ml('error.notloggedin', {'aopts' => "href='$LJ::SITEROOT/login.bml?ret=1'"});
}


# <LJFUNC>
# name: LJ::warning_list
# des: Returns a warning bar with bulleted list of warnings
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
# des: When web pages using cookie authentication, you can't just trust that
#      the remote user wants to do the action they're requesting.  It's way too
#      easy for people to force other people into making GET requests to
#      a server.  What if a user requested http://server/delete_all_journal.bml
#      and that URL checked the remote user and immediately deleted the whole
#      journal.  Now anybody has to do is embed that address in an image
#      tag and a lot of people's journals will be deleted without them knowing.
#      Cookies should only show pages which make no action.  When an action is
#      being made, check that it's a POST request.
# returns: true if REQUEST_METHOD == "POST"
# </LJFUNC>
sub did_post
{
    return (BML::get_method() eq "POST");
}

# <LJFUNC>
# name: LJ::robot_meta_tags
# des: Returns meta tags to block a robot from indexing or following links
# returns: A string with appropriate meta tags
# </LJFUNC>
sub robot_meta_tags
{
    return "<meta name=\"robots\" content=\"noindex, nofollow, noarchive\" />\n" .
           "<meta name=\"googlebot\" content=\"nosnippet\" />\n";
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
# des-uri: string; the URI we want the user to come from
# des-referer: string; the location the user is posting from.  if not supplied,
#   will be retrieved with BML::get_client_header.  in general, you don't want to
#   pass this yourself unless you already have it or know we can't get it from BML.
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
#   submission came from a particular user.
# args: raw?
# des-raw: boolean; If true, returns only the token (no HTML)
# returns: HTML hidden field to be inserted into the output of a page.
# </LJFUNC>
sub form_auth {
    my $raw = shift;
    my $remote = LJ::get_remote()    or return "";
    my $sess = $remote->{'_session'} or return "";
    my $auth = join('-',
                    LJ::rand_chars(10),
                    $remote->{userid},
                    $sess->{auth});
    my $chal = LJ::challenge_generate(86400, $auth);
    return $raw? $chal : LJ::html_hidden("lj_form_auth", $chal);
}

# <LJFUNC>
# name: LJ::check_form_auth
# class: web
# des: Verifies form authentication created with LJ::form_auth.
# returns: Boolean; true if the current data in %POST is a valid form submitted
#   by the user in $remote using the current session, false if the user has changed,
#   the challenge has expired, or the user has changed session (logged out and in
#   again, or something).
# </LJFUNC>
sub check_form_auth {
    my $remote = LJ::get_remote()    or return 0;
    my $sess = $remote->{'_session'} or return 0;
    my $formauth = $BMLCodeBlock::POST{'lj_form_auth'} or return 0;

    # check the attributes are as they should be
    my $attr = LJ::get_challenge_attributes($formauth);
    my ($randchars, $userid, $sessauth) = split(/\-/, $attr);
    return 0 unless $userid == $remote->{userid} &&
        $sessauth eq $sess->{auth};

    # check the signature is good and not expired
    my $opts = { dont_check_count => 1 };  # in/out
    LJ::challenge_check($formauth, $opts);
    return $opts->{valid} && ! $opts->{expired};
}

# <LJFUNC>
# name: LJ::create_qr_div
# class: web
# des: Creates the hidden div that stores the Quick Reply form
# returns: undef upon failure or HTML for the div upon success
# args: user, remote, ditemid, stylemine, userpic
# des-u: user object or userid for journal reply in
# des-ditemid: ditemid for this comment
# des-stylemine: if the user has specified style=mine for this page
# des-userpic: alternate default userpic
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

    # here we create some seperate fields for saving the quickreply entry
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
# JavaScript is not enabled, then forwards the user through
# to replyurl.
# returns: undef upon failure or HTML for the link
# args: dtid, basesubject, linktext, replyurl
# des-dtid: dtalkid for this comment
# des-basesubject: parent comment's subject
# des-linktext: text for the user to click
# des-replyurl: URL to forward user to if their browser
# does not support QR
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
# des: Looks up the last talkid and journal the remote user posted in
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
# des: Returns a div usable for Quick Reply boxes
# returns: HMTML for the div
# args:
# </LJFUNC>
sub make_qr_target {
    my $name = shift;

    return "<div id='ljqrt$name' name='ljqrt$name'></div>";
}

# <LJFUNC>
# name: LJ::set_lastcomment
# class: web
# des: Sets the lastcomm Memcache key for this user's last comment
# returns: undef on failure
# args: u, remote, dtalkid, life?
# des-u: Journal they just posted in, either u or userid
# des-remote: Remote user
# des-dtalkid: Talkid for the comment they just posted
# des-life: How long, in seconds, the Memcache key should live
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
# des: Returns a properly formatted form for creating/editing entries
# args: opts, head
# des-head: string reference for the <head> section (javascript previews, etc)
# des-onload: string reference for javascript functions to be called on page load
# des-opts: hashref of keys/values:
#   mode: either "update" or "edit", depending on context
#   datetime: date and time, formatted yyyy-mm-dd hh:mm
#   remote: remote u object
#   subject: entry subject
#   event: entry text
#   richtext: allow rich text formatting
#   auth_as_remote: bool option to authenticate as remote user, prefilling pic/friend groups/etc
# return: form to include in BML pages
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

    # 15 minute auth token, should be adequate
    my $chal = LJ::challenge_generate(900);
    $out .= "\n<input type='hidden' name='chal' id='login_chal' value='$chal' />\n";
    $out .= "<input type='hidden' name='response' id='login_response' value='' />\n\n";

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
   
    $out .= "<div id='userpic' class='js-req'>";
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
                $$head .= qq {
                    <script type="text/javascript" language="JavaScript"><!--
                        if (document.getElementById) {
                            var userpics = new Array();
                            $userpics
                            function userpic_preview() {
                                if (! document.getElementById) return false;
                                var userpic_select          = document.getElementById('prop_picture_keyword');
                                var userpic_preview         = document.getElementById('userpic_preview');
                                var userpic_preview_image   = document.getElementById('userpic_preview_image');

                                if (userpics[userpic_select.selectedIndex] != "") {
                                    userpic_preview.style.display = "block";
                                    userpic_preview_image.src = userpics[userpic_select.selectedIndex];
                                }
                            }
                        }
                    //--></script>
                    };

                $$head .= qq {
                    <script type="text/javascript" language="JavaScript">
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
                        if (ups_btn) {
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

                $out .= "\n";

                $userpic_preview = "<p id='userpic_preview' class='js-req' style='display: none'>" .
                                    "<a href='javascript:void(0);' id='lj_userpicselect_img'><img src='' alt='selected userpic' id='userpic_preview_image' /><span id='lj_userpicselect_img_txt'>" . BML::ml('entryform.userpic.choose') . "</span></a></p>\n";
            }
            if ($userpic_preview ne "") { $out .= "$userpic_preview"; }


    $out .= "</div><!-- end #userpic -->\n\n";
    
    
    ### Meta Information Column 1
    {
        $out .= "<div id='metainfo'>\n\n";
        $out .= $opts->{'auth'};
        if ($opts->{'mode'} eq "update") {
            # communities the user can post in
            my $usejournal = $opts->{'usejournal'};
            if ($usejournal) {
                $out .= "<p class='pkg'>\n";
                $out .= "<label for='usejournal' class='left'>" . BML::ml('entryform.postto') . "</label>\n";
                $out .= LJ::ljuser($usejournal);
                $out .= LJ::html_hidden('usejournal' => $usejournal, 'usejournal_set' => 'true');
                $out .= "</p>\n";
            } elsif ($res && ref $res->{'usejournals'} eq 'ARRAY') {
                my $submitprefix = BML::ml('entryform.update3');
                $out .= "<p class='pkg'>\n";
                $out .= "<label for='usejournal' class='left'>" . BML::ml('entryform.postto') . "</label>\n";
                $out .= LJ::html_select({ 'name' => 'usejournal', 'id' => 'usejournal', 'selected' => $usejournal,
                                    'tabindex' => $tabindex->(), 
                                    "onchange" => "changeSubmit('".$submitprefix."','".$remote->{'user'}."')" },
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
            $datetime .= LJ::html_hidden(hour_old => $hour, min_old => $min);
            $datetime .= '<span class="ljhidden" style="display:none">' . LJ::html_datetime({'name' => "date_ymd_old", 'notime' => 1, 'default' => "$year-$mon-$mday"}) . '</span>';
            $out .= "<p class='pkg'>\n";
            $out .= "<label for='modifydate' class='left'>" . BML::ml('entryform.date') . "</label>\n";
            $out .= "<span id='currentdate' class='float-left js-req'><span id='currentdate-date'>$monthlong $mday, $year, $hour" . ":" . "$min</span> <a href='javascript:void(0)' onclick='editdate();' id='currentdate-edit'>Edit</a></span>\n";
            $out .= "<span id='modifydate' style='display:none'>$datetime <?de " . BML::ml('entryform.date.24hournote') . " de?><br />\n";
            $out .= LJ::html_check({ 'type' => "check", 'id' => "prop_opt_backdated",
                    'name' => "prop_opt_backdated", "value" => 1,
                    'selected' => $opts->{'prop_opt_backdated'},
                    'tabindex' => $tabindex->() });
            $out .= "<label for='prop_opt_backdated' class='right'>" . BML::ml('entryform.backdated3') . "</label>\n";
            $out .= LJ::help_icon_html("backdate", "", "") . "\n";
            $out .= "</span><!-- end #modifydate -->\n";
            $out .= "<noscript>$datetime</noscript>\n"; # this doesn't validate. may need to change.
            $out .= "</p>\n";
            $out .= "<noscript><p class='small'>" . BML::ml('entryform.nojstime.note') . "</p></noscript>\n";
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
                $out .= "<p class='pkg'>\n";
                $out .= "<label for='prop_picture_keyword' class='left'>" . BML::ml('entryform.userpic') . "</label>\n" ;
                $out .= LJ::html_select({'name' => 'prop_picture_keyword', 'id' => 'prop_picture_keyword',
                                         'selected' => $opts->{'prop_picture_keyword'}, 'onchange' => "userpic_preview()",
                                         'tabindex' => $tabindex->() },
                                        "", BML::ml('entryform.opt.defpic'),
                                        @pickws) . "\n";

                # userpic browse button
                $out .= "<a href='javascript:void(0)' id='lj_userpicselect' class='js-req'>View Thumbnails</a>" if ! $LJ::DISABLED{userpicselect} && $remote->get_cap('userpicselect');
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
        $out .= "<label class='left' for='subject'>" . BML::ml('entryform.subject') . "</label>\n";
        if (!$opts->{'subject'}) {
            $opts->{'subject'} = BML::ml('entryform.subject.hint');
        }
        $out .= LJ::html_text({ 'name' => 'subject', 'value' => $opts->{'subject'},
                                'class' => 'text', 'id' => 'subject', 'size' => '43', 'maxlength' => '100', 
                                'tabindex' => $tabindex->(),  
                                'disabled' => $opts->{'disabled_save'}}) . "\n";
        $$onload .= " insertFormHints();"; 
        $out .= "<input type='hidden' id='formhint-subject' value='" . BML::ml('entryform.subject.hint') . "' />";
        $out .= "<ul id='entry-tabs' class='js-req'>\n";
        $out .= "<li id='jrich'>" . BML::ml("entryform.htmlokay.rich4", { 'opts' => 'href="javascript:void(0);" onclick="return useRichText(\'draft\', \'' . $LJ::WSTATPREFIX. '\');"' })  . "</li>\n";
        $out .= "<li id='jplain' class='on'>" . BML::ml("entryform.plainswitch2", { 'aopts' => 'href="javascript:void(0);" onclick="return usePlainText(\'draft\');"' }) . "</li>\n";
        $out .= "</ul>";
        $out .= "</div><!-- end #entry -->\n\n";
        $out .= "<div id='draftstatus'></div>\n\n";
        }

        ### Display Spell Check Results:
        $out .= "<p><b>" . BML::ml('entryform.spellchecked') . "</b><br />$opts->{'spellcheck_html'}</p>\n"
            if $opts->{'spellcheck_html'};
        $out .= "<p><?inerr " . BML::ml('Error') . " inerr?><br />$errors->{'entry'}</p>\n"
            if $errors->{'entry'};

    ### Event Text Area:
    my $insobjout;
    if ($remote && ($LJ::UPDATE_INSERT_OBJECT || $opts->{'include_insert_object'})) {
        my $show;

        $show .= "<select name='insobjsel' id='insobjsel' onchange='InOb.handleInsertSelect()'>\n";
        $show .= "<option value='insert' style='padding-left: 20px'>$BML::ML{'entryform.insert.header'}</option>\n";
        $show .= "<option value='image' style='background: url($LJ::IMGPREFIX/insobj_image.gif) no-repeat; background-color: #fff; background-position: 0px 1px; padding-left: 20px;'>$BML::ML{'entryform.insert.image'}</option>\n";
        # $show .= "<option value='image' style='background: url($LJ::IMGPREFIX/insobj_poll.gif) no-repeat; background-color: #fff; background-position: 0px 1px; padding-left: 20px;'>$BML::ML{'entryform.insert.poll'}</option>";
        $show .= "</select>\n\n";

        $insobjout = "<script> if (document.getElementById) { document.write(\"" . LJ::ejs($show) . "\"); } </script>\n";
    }

    $out .= "<div id='htmltools' class='pkg'>\n";
    $out .= "<ul class='pkg'>\n";
    $out .= "<li class='image'><a href='javascript:void(0);' onclick='InOb.handleInsertImage();'>Image</a></li>\n";
    $out .= "<li class='movie'><a href='javascript:void(0);' onclick='InOb.handleInsertVideo();'>Video</a></li>\n";
    $out .= "</ul>\n";
    my $format_selected = $opts->{'prop_opt_preformatted'} ? "" : "checked='checked'";
    $format_selected ||= $opts->{'event_format'};
    $out .= "<span id='linebreaks'><input type='checkbox' class='check' name='event_format' id='event_format' $format_selected  /> 
            <label for='event_format''>" . BML::ml('entryform.format2') . "</label>$opts->{'event_format'}</span>\n";
    $out .= "</div>\n\n";

    ### Draft Status Area
    {
        my $insobj = "<span id='insobj'>$insobjout</span>";

        # hide the insert object
        # $out .= "$draft&nbsp;&nbsp;$insobj";
# $out .= "$draft";
    }
    
    $out .= "<div id='draft-container' class='pkg'>\n";
    $out .= "<div id='draftstatus'></div>";
    $out .= LJ::html_textarea({ 'name' => 'event', 'value' => $opts->{'event'},
                                'rows' => '20', 'cols' => '50', 'style' => '',
                                'tabindex' => $tabindex->(),
                                'disabled' => $opts->{'disabled_save'},
                                'id' => 'draft'}) . "\n";  
    $out .= "<input type='hidden' id='drafthint' value='" . BML::ml('entryform.entry.hint') . "' />";
    $out .= "</div><!-- end #draft-container -->\n\n";
    LJ::need_res('js/rte.js', 'stc/fck/fckeditor.js', 'stc/display_none.css');
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
    $out .= "FCKLang.LJVideo = \"".LJ::ejs(BML::ml('fcklang.ljvideo'))."\";\n";
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
# $out .= "\t\tdocument.write(\"<div id='jrich'>$jrich</div>\");\n";

            my $jplain = LJ::ejs(LJ::deemp(
                                           BML::ml("entryform.plainswitch", { 'aopts' => 'href="javascript:void(0);" onclick="return usePlainText(\'draft\');"' })));
# $out .= "\t\tdocument.write(\"<div id='jplain' class='display_none'>$jplain</div>\");\n";
        }

        $out .= <<RTE;
        } else {
            document.getElementById('entry-tabs').style.display = 'none';
            document.getElementById('htmltools').style.display = 'none';
            document.write("$jnorich");
        }
        //-->
            </script>
RTE

        $out .= '<noscript><?de ' . BML::ml('entryform.htmlokay.norich2') . ' de?></noscript>';
    }
    $out .= LJ::html_hidden({ name => 'switched_rte_on', id => 'switched_rte_on', value => '0'});
    $out .= '<br />';

    $out .= "<div id='options' class='pkg'>";
    if (!$opts->{'disabled_save'}) {
        ### Options

            # Text Formatting
#            my $format_selected = $opts->{'prop_opt_preformatted'} ? "preformatted" : "";
#            $format_selected ||= $opts->{'event_format'};

#            $out .= "<tr valign='top' id='event_format_tr'><th><label for='event_format'>" . BML::ml('entryform.format') . "</label></th><td>";

#            $out .= LJ::html_select({ 'name' => "event_format", 'id' => "event_format",
#            'selected' => $format_selected, 'tabindex' => $tabindex->() },
#            "auto", BML::ml('entryform.format.auto'), "preformatted", BML::ml('entryform.format.preformatted'));
#            $out .= "</td></tr>";

            # Tag labeling
            unless ($LJ::DISABLED{tags}) {
                $out .= "<p class='pkg'>";
                $out .= "<label for='prop_taglist' class='left'>" . BML::ml('entryform.tags') . "</label>";
                $out .= LJ::html_text(
                    {
                        'name'      => 'prop_taglist',
                        'id'        => 'prop_taglist',
                        'class'     => 'text',
                        'size'      => '35',
                        'value'     => $opts->{'prop_taglist'},
                        'maxlength' => '255',
                        'tabindex'  => $tabindex->()
                    }
                );
                $out .= LJ::help_icon_html('addtags');
                $out .= "</p>";
            }

            $out .= "<p class='pkg'>\n";
            $out .= "<span class='inputgroup-left'>\n";
            $out .= "<label for='prop_current_moodid' class='left'>" . BML::ml('entryform.mood') . "</label>";
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
    function mood_preview() {
        if (! document.getElementById) return false;
        var mood_preview = document.getElementById('mood_preview');
        var mood_list  = document.getElementById('prop_current_moodid');
        var moodid = mood_list[mood_list.selectedIndex].value;
        if (moodid == "") {
            mood_preview.style.display = "none";
        } else {
            mood_preview.style.display = "block";
            var mood_image_preview = document.getElementById('mood_image_preview');
            mood_image_preview.src = moodpics[moodid];

            var mood_text_preview = document.getElementById('mood_text_preview');
            var mood_custom_text  = document.getElementById('prop_current_mood').value;
            mood_text_preview.innerHTML = mood_custom_text == "" ? moods[moodid] : mood_custom_text;
            \$('prop_current_music').className = \$('prop_current_music').className + ' narrow';
            \$('prop_current_location').className = \$('prop_current_location').className + ' narrow';
        }
    }
}
//--></script>
MOODS
                }

                $out .= LJ::html_select({ 'name' => 'prop_current_moodid', 'id' => 'prop_current_moodid',
                                          'selected' => $sel, 'onchange' => "mood_preview()",
                                          'tabindex' => $tabindex->() }, @moodlist);
                $out .= " " . LJ::html_text({ 'name' => 'prop_current_mood', 'id' => 'prop_current_mood', 'class' => 'text',
                                              'value' => $opts->{'prop_current_mood'}, 'onchange' => "mood_preview()",
                                              'size' => '15', 'maxlength' => '30',
                                              'tabindex' => $tabindex->() });
                my $mood_preview = LJ::ejs("<span id='mood_preview'><img src='javascript:true' alt='' id='mood_image_preview' /> <span id='mood_text_preview'></span></span>");
            $out .= "<script type='text/javascript' language='JavaScript'>\n<!--\ndocument.write(\"$mood_preview\");\n//-->\n</script>" if $remote;
            }
            $out .= "</span>\n";
            $out .= "<span class='inputgroup-right'>\n";
            $out .= "<label for='comment_settings' class='left'>" . BML::ml('entryform.comment.settings2') . "</label>\n";
            # BML::ml('entryform.comment.settings') 
            # Comment Settings
            my $comment_settings_selected = $opts->{'prop_opt_noemail'} ? "noemail" :
                $opts->{'prop_opt_nocomments'} ? "nocomments" : "";
            $comment_settings_selected  ||= $opts->{'comment_settings'};
            $out .= LJ::html_select({ 'name' => "comment_settings", 'id' => 'comment_settings', 'selected' => $comment_settings_selected,
                                  'tabindex' => $tabindex->() },
                                "", BML::ml('entryform.comment.settings.default2'), "noemail", BML::ml('entryform.comment.settings.noemail'), "nocomments", BML::ml('entryform.comment.settings.nocomments'));
            $out .= LJ::help_icon_html("comment", "", " "); 
            $out .= "\n";
            
            $out .= "</span>\n";
            $out .= "</p>\n";
            
            # Current Location
            unless ($LJ::DISABLED{'web_current_location'}) {
                $out .= "<p class='pkg'>";
                $out .= "<span class='inputgroup-left'>";
                $out .= "<label for='prop_current_location' class='left'>" . BML::ml('entryform.location') . "</label>";
                $out .= LJ::html_text({ 'name' => 'prop_current_location', 'value' => $opts->{'prop_current_location'}, 'id' => 'prop_current_location',
                                        'class' => 'text', 'size' => '35', 'maxlength' => '60', 'tabindex' => $tabindex->() }) . "\n";
                $out .= "</span>";
                $out .= "<span class='inputgroup-right'>\n";
                $out .= "<label for='prop_opt_screening' class='left'>" . BML::ml('entryform.comment.screening2') . "</label>\n";
                # BML::ml('entryform.comment.screening')
                # Comment Screening settings
                my @levels = ('', BML::ml('label.screening.default2'), 'N', BML::ml('label.screening.none'),
                          'R', BML::ml('label.screening.anonymous'), 'F', BML::ml('label.screening.nonfriends'),
                          'A', BML::ml('label.screening.all'));
                $out .= LJ::html_select({ 'name' => 'prop_opt_screening', 'id' => 'prop_opt_screening', 'selected' => $opts->{'prop_opt_screening'},
                          'tabindex' => $tabindex->() }, @levels);
                $out .= LJ::help_icon_html("screening", "", " ");
                $out .= "</span>\n";
                $out .= "</p>\n";
            }

            # Current Music
            $out .= "<p class='pkg'>\n";
            $out .= "<span class='inputgroup-left'>\n";
            $out .= "<label for='prop_current_music' class='left'>" . BML::ml('entryform.music') . "</label>\n";
            # BML::ml('entryform.music')
            $out .= LJ::html_text({ 'name' => 'prop_current_music', 'value' => $opts->{'prop_current_music'}, 'id' => 'prop_current_music',
                                    'class' => 'text', 'size' => '35', 'maxlength' => '60', 'tabindex' => $tabindex->() }) . "\n";
            $out .= "</span>\n";
            $out .= "<span class='inputgroup-right'>"; 

            my $preview = "var f=this.form; var action=f.action; f.action='/preview/entry.bml'; f.target='preview'; ";
            $preview   .= "window.open('','preview','width=760,height=600,resizable=yes,status=yes,toolbar=no,location=no,menubar=no,scrollbars=yes'); ";
            $preview   .= "f.submit(); f.action=action; f.target='_self'; return false; ";
            $preview    = LJ::ejs(LJ::html_submit('action:preview', BML::ml('entryform.preview'), { 'onclick' => $preview,
                                                                                                'tabindex' => $tabindex->() }));
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
                my @secs = ("public", BML::ml('label.security.public2'), "private", BML::ml('label.security.private2'),
                            "friends", BML::ml('label.security.friends'));

                my @secopts;
                if ($res && ref $res->{'friendgroups'} eq 'ARRAY' && scalar @{$res->{'friendgroups'}} && !$opts->{'usejournal'}) {
                    push @secs, ("custom", BML::ml('label.security.custom'));
                    push @secopts, ("onchange" => "customboxes()");
                }

                $out .= LJ::help_icon("security", "<span id='security-help'>\n", "\n</span>\n");
                $out .= LJ::html_select({ 'id' => "security", 'name' => 'security', 'include_ids' => 1,
                                          'selected' => $opts->{'security'},
                                          'tabindex' => $tabindex->(), @secopts }, @secs) . "\n";

                # if custom security groups available, show them in a hideable div
                if ($res && ref $res->{'friendgroups'} eq 'ARRAY' && scalar @{$res->{'friendgroups'}}) {
                    my $display = $opts->{'security'} eq "custom" ? "block" : "none";
                    my $groupcount = @{$res->{'friendgroups'}};
                    my ($groupcolumns,$percolumn);
                    if ($groupcount < 6) {
                        $groupcolumns = 1;
                    } elsif ($groupcount < 11) {
                        $groupcolumns = 2;
                    } elsif ($groupcount < 16) {
                        $groupcolumns = 3;
                    } else {
                        $groupcolumns = 4;
                    }
                    $percolumn = $groupcount / $groupcolumns;
                    $percolumn = POSIX::ceil($percolumn);
                    my $fgloopcount = 0;
                    $out .= "<div id='custom_boxes' class='cb_$groupcolumns' style='display: $display;'>\n";
                    $out .= "<div class='custom_boxes_col'>";
                    foreach my $fg (@{$res->{'friendgroups'}}) {
                        $fgloopcount++;
                        $out .= "<p>";
                        $out .= LJ::html_check({ 'name' => "custom_bit_$fg->{'id'}",
                                                 'id' => "custom_bit_$fg->{'id'}",
                                                 'selected' => $opts->{"custom_bit_$fg->{'id'}"} || $opts->{'security_mask'}+0 & 1 << $fg->{'id'} }) . " ";
                        $out .= "<label for='custom_bit_$fg->{'id'}'>" . LJ::ehtml($fg->{'name'}) . "</label>\n";
                        $out .= "</p>";
                        if (($fgloopcount %  $percolumn) eq 0 && $groupcount != $fgloopcount) {
                            $out .= "</div>\n";
                            $out .= "<div class='custom_boxes_col'>";
                        }
                    }
                    $out .= "</div>\n";
                    $out .= "</div><!-- end #custom_boxes -->\n";
                }
            }

        if ($opts->{'mode'} eq "update") {
            my $onclick = "";
            $onclick .= "return sendForm('updateForm');" if ! $LJ::IS_SSL;
            $out .= LJ::html_submit('action:update', BML::ml('entryform.update3') . " " . $remote->{user}, 
                    { 'onclick' => $onclick, 'class' => 'submit', 'id' => 'formsubmit',
                      'tabindex' => $tabindex->() }) . "&nbsp;\n"; }

        if ($opts->{'mode'} eq "edit") {
            $out .= LJ::html_submit('action:save', BML::ml('entryform.save'),
                                    { 'disabled' => $opts->{'disabled_save'},
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
    }
# $out .= "</div><!-- end # -->\n\n";
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
    return LJ::html_hidden({'name' => 'year', 'value' => $year, 'id' => 'update_year'},
                           {'name' => 'day', 'value'  => $mday, 'id' => 'update_day'},
                           {'name' => 'mon', 'value'  => $mon,  'id' => 'update_mon'},
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
# des: Decodes an entry_form into a protocol compatible hash
# info: Generate form with [func[entry_form]].
# args: req, post
# des-req: protocol request hash to build
# des-post: entry_form POST contents
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

    my $date_old = LJ::html_datetime_decode({ 'name' => "date_ymd_old", }, $POST);
    my ($year_old, $mon_old, $day_old) = split( /\D/, $date_old);

    $req->{'year'} = $year if $year ne $year_old;
    $req->{'mon'} = $mon if $mon ne $mon_old;
    $req->{'day'} = $day if $day ne $day_old;

    foreach (qw(hour min)) {
        $req->{$_} = $POST->{$_} if $POST->{$_} ne ""
            && $POST->{$_ . '_old'} ne $POST->{$_};
    }

    # copy some things from %POST
    foreach (qw(subject
                prop_picture_keyword prop_current_moodid
                prop_current_mood prop_current_music
                prop_opt_screening prop_opt_noemail
                prop_opt_preformatted prop_opt_nocomments
                prop_current_location prop_current_coords
                prop_taglist)) {
        $req->{$_} = $POST->{$_};
    }

    if ($POST->{"subject"} eq BML::ml('entryform.subject.hint')) {
        $req->{"subject"} = "";
    }
    $req->{"prop_opt_preformatted"} ||= $POST->{'switched_rte_on'} ? 1 :
        $POST->{'event_format'} eq "preformatted" ? 1 : 0;
    $req->{"prop_opt_nocomments"}   ||= $POST->{'comment_settings'} eq "nocomments" ? 1 : 0;
    $req->{"prop_opt_noemail"}      ||= $POST->{'comment_settings'} eq "noemail" ? 1 : 0;
    $req->{'prop_opt_backdated'}      = $POST->{'prop_opt_backdated'} ? 1 : 0;

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
    my $hasremote = $remote ? 'true' : 'false';

    # ctxpopup prop
    my $ctxpopup = $remote && $remote->prop("opt_ctxpopup") ? 'true' : 'false';

    # poll for esn inbox updates?
    my $inbox_update_poll = $LJ::DISABLED{inbox_update_poll} ? 'false' : 'true';

    # include standard JS info
    $ret .= qq {
        <script language="JavaScript" type="text/javascript">
        var LJVAR;
        if (!LJVAR) LJVAR = {};
        LJVAR.imgprefix = "$imgprefix";
        LJVAR.siteroot = "$siteroot";
        LJVAR.statprefix = "$statprefix";
        LJVAR.currentJournalBase = "$journal_base";
        LJVAR.currentJournal = "$journal";
        LJVAR.has_remote = $hasremote;
        LJVAR.ctx_popup = $ctxpopup;
        LJVAR.inbox_update_poll = $inbox_update_poll;
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

    my $ret .= "<div id='tagcloud' class='tagcloud'>";
    my %tagdata = ();
    foreach my $tag (@tag_names) {
        my $tagurl = $tags->{$tag}->{'url'};
        my $ct     = $tags->{$tag}->{'value'};
        my $pt     = int(8 + $percentile->($ct) * 25);
        $ret .= "<a ";
        $ret .= "id='taglink_$tag' " unless $opts->{ignore_ids};
        $ret .= "href='" . LJ::ehtml($tagurl) . "' style='color: <?altcolor2?>; font-size: ${pt}pt;'>";
        $ret .= LJ::ehtml($tag) . "</a>\n";

        # build hash of tagname => final point size for refresh
        $tagdata{$tag} = $pt;
    }
    $ret .= "</div>";

    return $ret;
}

sub ads {
    my %opts = @_;

    # WARNING: $ctx is terribly named and not an S2 context
    my $ctx      = delete $opts{'type'};
    my $pagetype = delete $opts{'orient'};
    my $user     = delete $opts{'user'};
    my $pubtext  = delete $opts{'pubtext'};

    # first 500 words
    $pubtext =~ s/<.+?>//g;
    $pubtext = text_trim($pubtext, 1000);
    my @words = grep { $_ } split(/\s+/, $pubtext);
    my $max_words = 500;
    @words = @words[0..$max_words-1] if @words > $max_words;
    $pubtext = join(' ', @words);

    my $debug = $LJ::DEBUG{'ads'};

    # TODO Make this an if call, bad style
    return '' unless $debug || LJ::run_hook('should_show_ad', {
        ctx  => $ctx,
        user => $user,
        type => $pagetype,
    });

    # If we don't know about this page type, can't do much of anything
    if (!defined $LJ::AD_PAGE_MAPPING{$pagetype}) {
        die("No mapping for page type $pagetype")
            if $LJ::IS_DEV_SERVER;

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
        if ($LJ::AD_MAPPING{$uri} ne $pagetype && $r->header_in('Host') ne $LJ::DOMAIN_WEB) {
            if ($uri = $r->notes('bml_filename')) {
                $uri =~ s!$LJ::HOME/(?:ssldocs|htdocs)!!;
                $uri = $uri =~ /\/$/ ? "$uri/index.bml" : $uri;
            }
        }

        # Make sure that the page type passed in is what the config says this
        # page actually is.
        return '' if $LJ::AD_MAPPING{$uri} ne $pagetype && !$opts{'force'};

        # If it was an interest search provide the query to the targetting engine
        # for more relevant results
        if ($uri eq '/interests.bml') {
            my $args = $r->args;
            if ($args =~ /int=(.+)$/) {
                my $term = $1;
                $term =~ s/\+/ /;
                $term =~ s/&page=\d+//i;
                $adcall{search_term} = $term;
            }
        }

        # Special case talkpost.bml and talkpost_do.bml as user pages
        if ($uri =~ /^\/talkpost(?:_do)?\.bml$/) {
            $adcall{type} = 'user';
        }
    }

    $adcall{adunit}  = $LJ::AD_PAGE_MAPPING{$pagetype}->{adunit}; # ie skyscraper
    my $addetails    = $LJ::AD_TYPE{$adcall{adunit}};             # hashref of meta-data or scalar to directly serve

    $adcall{channel} = $pagetype;
    $adcall{type}    = $adcall{type} || $LJ::AD_PAGE_MAPPING{$pagetype}->{target}; # user|content


    $adcall{url}     = 'http://' . $r->header_in('Host') . $r->uri;

    $adcall{contents} = $pubtext;

    return $addetails unless ref $addetails eq "HASH";

    # addetails is a hashref now:
    $adcall{width}   = $addetails->{width};
    $adcall{height}  = $addetails->{height};

    my $remote = LJ::get_remote();
    if ($remote) {
        # Pass age to targetting engine
        unless ($remote->underage) {
            my $age = eval {$remote->init_age || $remote->age};
            $adcall{age} = $age if ($age);
        }

        # Pass country to targetting engine if user shares this information
        if ($remote->can_show_location) {
            $adcall{country} = $remote->prop('country');
        }

        # Pass gender to targetting engine
        if ($adcall{gender} = $remote->prop('gender')) {
            $adcall{gender} = uc(substr($adcall{gender}, 0, 1)); # M|F|U
            $adcall{gender} = undef if $adcall{gender} eq 'U';
        }

        # User selected ad content categories
        $adcall{categories} = $remote->prop('ad_categories');

        # User's notable interests
        $adcall{interests} = join(',', grep { !defined $LJ::AD_BLOCKED_INTERESTS{$_} } $remote->notable_interests(150));
    }

    # If we have neither categories or interests, load the content author's
    # if we're in journal context
    if ($ctx eq 'journal'  && !($adcall{categories} && !$adcall{interests})) {
        my $u = $opts{user} ? LJ::load_user($opts{user}) : LJ::load_userid($r->notes("journalid"));

        if ($u) {
            $adcall{categories} = $u->prop('ad_categories');
            $adcall{interests} = join(',', grep { !defined $LJ::AD_BLOCKED_INTERESTS{$_} } $u->notable_interests(150));
        }
    }

    # Language this page is displayed in
    $adcall{language} = $r->notes('langpref');
    $adcall{language} =~ s/_LJ//; # Trim _LJ postfixJ

    # TODO rewrite this as an expanded if/else
    # What type of account level do they have?
    $adcall{accttype} = $remote ?
        $remote->in_class('plus') ? 'ADS' : 'FREE' :   # Ads or Free if logged in
        'NON';                                         # Not logged in

    # Build up escaped query string of adcall parameters
    my $adparams = join('&', map { LJ::eurl($_) . '=' . LJ::eurl($adcall{$_}) } keys %adcall);

    my $adhtml;
    $adhtml .= "<div class=\"ljad ljad$adcall{adunit}\" id=\"\">";

    my $label = $pagetype eq 'Journal-5LinkUnit' ? 'Sponsored Search Links' : 'Advertisement';
    $adhtml .= "<h4 style='float: left; margin-bottom: 2px; margin-top: 2px; clear: both;'>$label</h4>";

    # Customize and feedback links
    my $eadcall = LJ::eurl($adparams);
    my $echannel = LJ::eurl($adcall{channel});
    my $euri = LJ::eurl($r->uri);
    # For leaderboards show links on the top right
    if ($adcall{adunit} =~ /^leaderboard/) {
        $adhtml .= "<div style='float: right; margin-bottom: 3px; padding-top: 0px; line-height: 1em; white-space: nowrap;'>";
        if ($LJ::IS_DEV_SERVER || exists $LJ::DEBUG{'ad_url_markers'}) {
            my $marker = $LJ::DEBUG{'ad_url_markers'} || '#';
            # This is so while working on ad related problems I can easily open the iframe in a new window
            $adhtml .= "<a href=\"${LJ::ADSERVER}?$adparams\">$marker</a> | ";
        }
        $adhtml .= "<a href='$LJ::SITEROOT/manage/payments/adsettings.bml'>Customize</a> | ";
        $adhtml .= "<a href=\"$LJ::SITEROOT/feedback/ads.bml?adcall=$eadcall&channel=$echannel&uri=$euri\">Feedback</a>";
        $adhtml .= "</div>";
    }

    if ($debug) {
        my $ehpub = LJ::ehtml($pubtext) || "[no text targetting]";
        $adhtml .= "<div style='width: $adcall{width}px; height: $adcall{height}px; border: 1px solid green; color: #ff0000'>$ehpub</div>";
    } else {
        # Iframe with call to ad targetting server
        if ($opts{inline} and my $ad_engine = LJ::run_hook('ad_engine', {pagetype => $adcall{channel}})) {
            $adhtml .= eval {$ad_engine->process(map { $_ => $adcall{$_} } qw(
                                                                           url
                                                                           width height type channel age
                                                                           gender country language categories
                                                                           interests search_term accttype
                                                                           contents
                                                                           ));};
            warn "Inline ad call failed with error: $@" if $@;
        }
        else {
            $adhtml .= "<iframe src='${LJ::ADSERVER}?$adparams' frameborder='0' scrolling='no' id='adframe' ";
            $adhtml .= "width='" . LJ::ehtml($adcall{width}) . "' ";
            $adhtml .= "height='" . LJ::ehtml($adcall{height}) . "' ";
            $adhtml .= "></iframe>";
        }
    }

    # For non-leaderboards show links on the bottom right
    unless ($adcall{adunit} =~ /^leaderboard/) {
        $adhtml .= "<div style='text-align: right; margin-top: 2px; white-space: nowrap;'>";
        if ($LJ::IS_DEV_SERVER || exists $LJ::DEBUG{'ad_url_markers'}) {
            my $marker = $LJ::DEBUG{'ad_url_markers'} || '#';
            # This is so while working on ad related problems I can easily open the iframe in a new window
            $adhtml .= "<a href=\"${LJ::ADSERVER}?$adparams\">$marker</a> | ";
        }
        $adhtml .= "<a href='$LJ::SITEROOT/manage/payments/adsettings.bml'>Customize</a> | ";
        $adhtml .= "<a href=\"$LJ::SITEROOT/feedback/ads.bml?adcall=$eadcall&channel=$echannel&uri=$euri\">Feedback</a>";
        $adhtml .= "</div>";
    }
    $adhtml .= "</div>\n";

    return $adhtml;
}

sub control_strip
{
    my %opts = @_;
    my $user = delete $opts{user};

    my $journal = LJ::load_user($user);
    my $show_strip = LJ::run_hook("show_control_strip", { user => $user });

    return "" unless $show_strip;

    my $remote = LJ::get_remote();
    my $r = Apache->request;
    # Build up some common links
    my %links = (
                 'post_journal'      => "<a href='$LJ::SITEROOT/update.bml'>$BML::ML{'web.controlstrip.links.post'}</a>",
                 'portal'            => "<a href='$LJ::SITEROOT/portal/'>" . BML::ml('web.controlstrip.links.mylj', {'siteabbrev' => $LJ::SITENAMEABBREV}) . "</a>",
                 'recent_comments'   => "<a href='$LJ::SITEROOT/tools/recent_comments.bml'>$BML::ML{'web.controlstrip.links.recentcomments'}</a>",
                 'manage_friends'    => "<a href='$LJ::SITEROOT/friends/'>$BML::ML{'web.controlstrip.links.managefriends'}</a>",
                 'manage_entries'    => "<a href='$LJ::SITEROOT/editjournal.bml'>$BML::ML{'web.controlstrip.links.manageentries'}</a>",
                 'invite_friends'    => "<a href='$LJ::SITEROOT/friends/invite.bml'>$BML::ML{'web.controlstrip.links.invitefriends'}</a>",
                 'create_account'    => "<a href='$LJ::SITEROOT/create.bml'>" . BML::ml('web.controlstrip.links.create', {'sitename' => $LJ::SITENAMESHORT}) . "</a>",
                 'syndicated_list'   => "<a href='$LJ::SITEROOT/syn/list.bml'>$BML::ML{'web.controlstrip.links.popfeeds'}</a>",
                 'learn_more'        => "<a href='$LJ::SITEROOT/'>$BML::ML{'web.controlstrip.links.learnmore'}</a>",
                 );

    if ($remote) {
        $links{'view_friends_page'} = "<a href='" . $remote->journal_base() . "/friends/'>$BML::ML{'web.controlstrip.links.viewfriendspage'}</a>";
        $links{'add_friend'} = "<a href='$LJ::SITEROOT/friends/add.bml?user=$journal->{user}'>$BML::ML{'web.controlstrip.links.addfriend'}</a>";
        if ($journal->{journaltype} eq "Y" || $journal->{journaltype} eq "N") {
            $links{'add_friend'} = "<a href='$LJ::SITEROOT/friends/add.bml?user=$journal->{user}'>$BML::ML{'web.controlstrip.links.addfeed'}</a>";
            $links{'remove_friend'} = "<a href='$LJ::SITEROOT/friends/add.bml?user=$journal->{user}'>$BML::ML{'web.controlstrip.links.removefeed'}</a>";
        }
        if ($journal->{journaltype} eq "C") {
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
        $ret .= "<td id='lj_controlstrip_user'><form id='Greeting' class='nopic' action='$LJ::SITEROOT/logout.bml?ret=1' method='post'><div>";
        $ret .= "<input type='hidden' name='user' value='$remote->{'user'}' />";
        $ret .= "<input type='hidden' name='sessid' value='$remote->{'_session'}->{'sessid'}' />";
        my $logout = "<input type='submit' value=\"$BML::ML{'web.controlstrip.btn.logout'}\" id='Logout' />";
        $ret .= "$remote_display<br />$logout";
        $ret .= "</div></form>\n";
        $ret .= "</td>\n";

        $ret .= "<td id='lj_controlstrip_userlinks'>";
        $ret .= "$links{'post_journal'}&nbsp;&nbsp; $links{'portal'}<br />$links{'view_friends_page'}";
        $ret .= "</td>";

        $ret .= "<td id='lj_controlstrip_actionlinks'>";
        if ($remote && $remote->{userid} == $journal->{userid}) {
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
                    push @filters, "filter:" . $group{$g}->{'name'}, $group{$g}->{'name'};
                }

                my $selected = "all";
                if ($r->uri eq "/friends" && $r->args ne "") {
                    $selected = "showpeople"      if $r->args eq "show=P&filter=0";
                    $selected = "showcommunities" if $r->args eq "show=C&filter=0";
                    $selected = "showsyndicated"  if $r->args eq "show=Y&filter=0";
                } elsif ($r->uri =~ /^\/friends\/(.+)?/i) {
                    $selected = "filter:" . LJ::durl($1);
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
        } elsif ($journal->{journaltype} eq "P" || $journal->{journaltype} eq "I") {
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
        } elsif ($journal->{journaltype} eq "C") {
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
        } elsif ($journal->{journaltype} eq "Y") {
            $ret .= "$statustext{'syn'}<br />";
            if ($remote && !LJ::is_friend($remote, $journal)) {
                $ret .= "$links{'add_friend'}&nbsp;&nbsp; ";
            } elsif ($remote && LJ::is_friend($remote, $journal)) {
                $ret .= "$links{'remove_friend'}&nbsp;&nbsp; ";
            }
            $ret .= $links{'syndicated_list'};
        } elsif ($journal->{journaltype} eq "N") {
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
        $ret .= LJ::run_hook('control_strip_logo', $remote, $journal);
        $ret .= "</td>";

    } else {
        my $method = Apache->request->method();

        my $chal = LJ::challenge_generate(300);
        $ret .= <<"LOGIN_BAR";
            <td id='lj_controlstrip_userpic'>&nbsp;</td>
            <td id='lj_controlstrip_login'><form id="login" action="$LJ::SITEROOT/login.bml?ret=1" method="post"><div>
            <input type="hidden" name="mode" value="login" />
            <input type='hidden' name='chal' id='login_chal' value='$chal' />
            <input type='hidden' name='response' id='login_response' value='' />
            <table cellspacing="0" cellpadding="0"><tr><td>
            <label for="xc_user">$BML::ML{'/login.bml.login.username'}</label> <input type="text" name="user" size="7" maxlength="17" tabindex="1" id="xc_user" value="" />
            </td><td>
            <label style="margin-left: 3px;" for="xc_password">$BML::ML{'/login.bml.login.password'}</label> <input type="password" name="password" size="7" tabindex="2" id="xc_password" />
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
        $ret .= "<td id='lj_controlstrip_actionlinks'>";

        my $jtype = $journal->{journaltype};
        if ($jtype eq "P" || $jtype eq "I") {
            if ($r->notes('view') eq "friends") {
                $ret .= $statustext{'personalfriendspage'};
            } elsif ($r->notes('view') eq "friendsfriends") {
                $ret .= $statustext{'personalfriendsfriendspage'};
            } else {
                $ret .= $statustext{'personal'};
            }
        } elsif ($jtype eq "C") {
            $ret .= $statustext{'community'};
        } elsif ($jtype eq "Y") {
            $ret .= $statustext{'syn'};
        } elsif ($jtype eq "N") {
            $ret .= $statustext{'news'};
        } else {
            $ret .= $statustext{'other'};
        }

        $ret .= "<br />";
        $ret .= "$links{'create_account'}&nbsp;&nbsp; $links{'learn_more'}";
        $ret .= LJ::run_hook('control_strip_logo', $remote, $journal);
        $ret .= "</td>";
    }

    return "<table id='lj_controlstrip' cellpadding='0' cellspacing='0'><tr valign='top'>$ret</tr></table>";
}

sub control_strip_js_inject
{
    my %opts = @_;
    my $user = delete $opts{user};

    my $ret;
    $ret .= "<script src='$LJ::JSPREFIX/core.js' type='text/javascript'></script>\n";
    $ret .= "<script src='$LJ::JSPREFIX/dom.js'  type='text/javascript'></script>\n";
    $ret .= "<script src='$LJ::JSPREFIX/httpreq.js'  type='text/javascript'></script>\n";
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
            <span class="esnlinks"><a href="$LJ::SITEROOT/inbox/">Message Center</a> | Manage Settings</span>
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

            if ($showtracking) {
                # add this class to the tracking category
                push @$tracking, $subsc;
            }
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

            # if all the $notify_class are enabled in this category, have
            # the checkall button be checked by default
            my $subscribed_count = 0;
            foreach my $subscr (@pending_subscriptions) {
                my %subscr_args = $subscr->sub_info;
                $subscr_args{ntypeid} = $ntypeid;
                $subscribed_count++ if scalar $u->find_subscriptions(%subscr_args);
            }

            my $checkall_checked = $subscribed_count == scalar @pending_subscriptions;

            my $disabled = ! $notify_class->configured_for_user($u);

            $title = "<a href='" . $notify_class->disabled_url . "'>$title</a>"
                if $notify_class->disabled_url && $disabled;

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

            $cat_html  .= LJ::html_check({
                id       => $input_name,
                name     => $input_name,
                class    => "SubscriptionInboxCheck",
                selected => $selected,
                noescape => 1,
                label    => $title,
                disabled => ! $pending_sub->enabled,
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

            foreach my $note_class (@notify_classes) {
                my $ntypeid = eval { $note_class->ntypeid } or next;

                my %sub_args = $pending_sub->sub_info;
                $sub_args{ntypeid} = $ntypeid;
                delete $sub_args{flags};

                my @subs = $u->has_subscription(%sub_args);

                my $note_pending = scalar @subs ? $subs[0] : LJ::Subscription::Pending->new($u, %sub_args);
                next unless $note_pending;

                if (($is_tracking_category || $pending_sub->is_tracking_category) && $note_pending->pending) {
                    # flag this as a "tracking" subscription
                    $note_pending->set_tracking;
                }

                my $notify_input_name = $note_pending->freeze;

                # select email method by default
                my $note_selected = (scalar @subs) ? 1 : (!$selected && $note_class eq 'LJ::NotificationMethod::Email');
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
            $cat_html .= "<td colspan='3'>$blurb</td>";
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

    my $placeholder_html = LJ::ehtml(delete $opts{placeholder_html} || '');
    my $width  = delete $opts{width}  || 100;
    my $height = delete $opts{height} || 100;
    my $link   = delete $opts{link}   || '';
    my $img    = delete $opts{img}    || "$LJ::IMGPREFIX/videoplaceholder.png";

    return qq {
            <div class="LJ_Placeholder_Container" style="width: ${width}px; height: ${height}px;">
                <div class="LJ_Container" lj_placeholder_html="$placeholder_html"></div>
                <a href="$link" onclick="return false;">
                    <img src="$img" class="LJ_Placeholder" title="Click to show embedded content" />
                </a>
            </div>
        };
}

# Common challenge/response javascript, needed by both login pages and comment pages alike.
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

# Common Javascript function for auto-checking radio buttons on form
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

1;
