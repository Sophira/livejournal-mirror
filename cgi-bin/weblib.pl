#!/usr/bin/perl
#

package LJ;
use strict;

# load the bread crumb hash
require "$ENV{'LJHOME'}/cgi-bin/crumbs.pl";

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
    if (@list > 1) {
        return ($opts->{'label'} || 'Work as user:') . " " . 
               LJ::html_select({ 'name' => 'authas',
                                 'selected' => $opts->{'authas'} || $u->{'user'}},
                                 map { $_, $_ } @list) . " " .
               LJ::html_submit(undef, $opts->{'button'} || 'Switch');
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
    foreach (@errors) {
        $ret .= "<li>$_</li>\n";
    }
    $ret .= "</ul>\n";
    return $ret;
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

# <LJFUNC>
# name: LJ::set_interests
# des: Change a user's interests
# args: dbarg?, u, old, new
# arg-old: hashref of old interests (hashing being interest => intid)
# arg-new: listref of new interests
# returns: 1
# </LJFUNC>
sub set_interests
{
    my ($u, $old, $new) = @_;

    $u = ref $u eq 'HASH' ? $u : LJ::load_userid($u);
    my $userid = $u->{'userid'};
    return unless $userid;

    my $dbh = LJ::get_db_writer();
    my %int_new = ();
    my %int_del = %$old;  # assume deleting everything, unless in @$new

    # user interests go in a different table than user interests,
    # though the schemas are the same so we can run the same queries on them
    my $uitable = $u->{'journaltype'} eq 'C' ? 'comminterests' : 'userinterests';

    # track if we made changes to refresh memcache later.
    my $did_mod = 0;

    foreach my $int (@$new)
    {
        $int = lc($int);       # FIXME: use utf8?
        $int =~ s/^i like //;  # *sigh*
        next unless $int;
        next if $int =~ / .+ .+ .+ /;  # prevent sentences
        next if $int =~ /[\<\>]/;
        my ($bl, $cl) = LJ::text_length($int);
        next if $bl > LJ::BMAX_INTEREST or $cl > LJ::CMAX_INTEREST;
        $int_new{$int} = 1 unless $old->{$int};
        delete $int_del{$int};
    }

    ### were interests removed?
    if (%int_del)
    {
        ## easy, we know their IDs, so delete them en masse
        my $intid_in = join(", ", values %int_del);
        $dbh->do("DELETE FROM $uitable WHERE userid=$userid AND intid IN ($intid_in)");
        $dbh->do("UPDATE interests SET intcount=intcount-1 WHERE intid IN ($intid_in)");
        $did_mod = 1;
    }

    ### do we have new interests to add?
    if (%int_new)
    {
        $did_mod = 1;

        ## difficult, have to find intids of interests, and create new ints for interests
        ## that nobody has ever entered before
        my $int_in = join(", ", map { $dbh->quote($_); } keys %int_new);
        my %int_exist;
        my @new_intids = ();  ## existing IDs we'll add for this user

        ## find existing IDs
        my $sth = $dbh->prepare("SELECT interest, intid FROM interests WHERE interest IN ($int_in)");
        $sth->execute;
        while (my ($intr, $intid) = $sth->fetchrow_array) {
            push @new_intids, $intid;       # - we'll add this later.
            delete $int_new{$intr};         # - so we don't have to make a new intid for
                                            #   this next pass.
        }

        if (@new_intids) {
            my $sql = "";
            foreach my $newid (@new_intids) {
                if ($sql) { $sql .= ", "; }
                else { $sql = "REPLACE INTO $uitable (userid, intid) VALUES "; }
                $sql .= "($userid, $newid)";
            }
            $dbh->do($sql);

            my $intid_in = join(", ", @new_intids);
            $dbh->do("UPDATE interests SET intcount=intcount+1 WHERE intid IN ($intid_in)");
        }
    }

    ### do we STILL have interests to add?  (must make new intids)
    if (%int_new)
    {
        foreach my $int (keys %int_new)
        {
            my $intid;
            my $qint = $dbh->quote($int);

            $dbh->do("INSERT INTO interests (intid, intcount, interest) ".
                     "VALUES (NULL, 1, $qint)");
            if ($dbh->err) {
                # somebody beat us to creating it.  find its id.
                $intid = $dbh->selectrow_array("SELECT intid FROM interests WHERE interest=$qint");
                $dbh->do("UPDATE interests SET intcount=intcount+1 WHERE intid=$intid");
            } else {
                # newly created
                $intid = $dbh->{'mysql_insertid'};
            }
            if ($intid) {
                ## now we can actually insert it into the userinterests table:
                $dbh->do("INSERT INTO $uitable (userid, intid) ".
                         "VALUES ($userid, $intid)");
            }
        }
    }

    ### if journaltype is community, clean their old userinterests from 'userinterests'
    if ($u->{'journaltype'} eq 'C') {
        $dbh->do("DELETE FROM userinterests WHERE userid=?", undef, $u->{'userid'});
    }

    LJ::memcache_kill($u, "intids") if $did_mod;
    return 1;
}

# $opts is optional, with keys:
#    forceids => 1   : don't use memcache for loading the intids
#    forceints => 1   : don't use memcache for loading the interest rows
#    justids => 1 : return arrayref of intids only, not names/counts
# returns otherwise an arrayref of interest rows, sorted by interest name
sub get_interests
{
    my ($u, $opts) = @_;
    $opts ||= {};
    return undef unless $u;
    my $uid = $u->{userid};
    my $uitable = $u->{'journaltype'} eq 'C' ? 'comminterests' : 'userinterests';

    # load the ids
    my $ids;
    my $mk_ids = [$uid, "intids:$uid"];
    $ids = LJ::MemCache::get($mk_ids) unless $opts->{'forceids'};
    unless ($ids && ref $ids eq "ARRAY") {
        $ids = [];
        my $dbh = LJ::get_db_writer();
        my $sth = $dbh->prepare("SELECT intid FROM $uitable WHERE userid=?");
        $sth->execute($uid);
        push @$ids, $_ while $_ = $sth->fetchrow_array;
        LJ::MemCache::add($mk_ids, $ids, 3600*12);
    }
    return $ids if $opts->{'justids'};

    # load interest rows
    my %need;
    $need{$_} = 1 foreach @$ids;
    my @ret;

    unless ($opts->{'forceints'}) {
        if (my $mc = LJ::MemCache::get_multi(map { [$_, "introw:$_"] } @$ids)) {
            while (my ($k, $v) = each %$mc) {
                next unless $k =~ /^introw:(\d+)/;
                delete $need{$1};
                push @ret, $v;
            }
        }
    }

    if (%need) {
        my $ids = join(",", map { $_+0 } keys %need);
        my $dbr = LJ::get_db_reader();
        my $sth = $dbr->prepare("SELECT intid, interest, intcount FROM interests ".
                                "WHERE intid IN ($ids)");
        $sth->execute;
        my $memc_store = 0;
        while (my ($intid, $int, $count) = $sth->fetchrow_array) {
            # minimize latency... only store 25 into memcache at a time
            # (too bad we don't have set_multi.... hmmmm)
            my $aref = [$intid, $int, $count];
            if ($memc_store++ < 25) {
                # if the count is fairly high, keep item in memcache longer,
                # since count's not so important.
                my $expire = $count < 10 ? 3600*12 : 3600*48;
                LJ::MemCache::add([$intid, "introw:$intid"], $aref, $expire);
            }
            push @ret, $aref;
        }
    }

    @ret = sort { $a->[1] cmp $b->[1] } @ret;
    return \@ret;
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

# Common challenge/response javascript, needed by both login pages and comment pages alike.
$LJ::COMMON_CODE{'chalresp_js'} = q{
<script type="text/javascript" src="/js/md5.js"></script>
<script language="JavaScript">
    <!--
function sendForm (formid)
{
    if (formid == null) formid = 'login';

    if (! document.getElementById) return true;
    var loginform = document.getElementById(formid);
    if (! loginform || ! loginform.password ||
        ! loginform.login_chal || !  loginform.login_response) return true;
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

1;
