#!/usr/bin/perl
#
# <LJDEP>
# lib: DBI::, Digest::MD5, URI::URL, HTML::TokeParser
# lib: cgi-bin/ljconfig.pl, cgi-bin/ljlang.pl, cgi-bin/ljpoll.pl
# link: htdocs/paidaccounts/index.bml, htdocs/users, htdocs/view/index.bml
# hook: canonicalize_url, name_caps, name_caps_short, post_create
# hook: validate_get_remote
# </LJDEP>

use strict;
use DBI;
use Digest::MD5 qw(md5_hex);
use Text::Wrap;
use MIME::Lite;
use HTTP::Date qw();

require "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljlang.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljpoll.pl";

# constants
$LJ::EndOfTime = 2147483647;

# declare views (calls into ljviews.pl)
@LJ::views = qw(lastn friends calendar day);
%LJ::viewinfo = (
		 "lastn" => {
		     "creator" => \&create_view_lastn,
		     "des" => "Most Recent Events",
		 },
		 "calendar" => {
		     "creator" => \&create_view_calendar,
		     "des" => "Calendar",
		 },
		 "day" => { 
		     "creator" => \&create_view_day,
		     "des" => "Day View",
		 },
		 "friends" => { 
		     "creator" => \&create_view_friends,
		     "des" => "Friends View",
		 },
		 "rss" => { 
		     "creator" => \&create_view_rss,
		     "des" => "RSS View (XML)",
		     "nostyle" => 1,
		 },
		 "info" => {
		     # just a redirect to userinfo.bml for now. 
		     # in S2, will be a real view.
		     "des" => "Profile Page",
		 }
		 );

## we want to set this right away, so when we get a HUP signal later
## and our signal handler sets it to true, perl doesn't need to malloc,
## since malloc may not be thread-safe and we could core dump.
## see LJ::clear_caches and LJ::handle_caches
$LJ::CLEAR_CACHES = 0;

## if this library is used in a BML page, we don't want to destroy BML's
## HUP signal handler.
if ($SIG{'HUP'}) {
    my $oldsig = $SIG{'HUP'};
    $SIG{'HUP'} = sub {
	&{$oldsig};
        LJ::clear_caches();
    };
} else {
    $SIG{'HUP'} = \&LJ::clear_caches;    
}


package LJ;

# interface to oldids table (URL compatability)
sub get_newids
{
    my $dbarg = shift;
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $sth;

    my $area = $dbh->quote(shift);
    my $oldid = $dbh->quote(shift);

    return $dbr->selectrow_arrayref("SELECT userid, newid FROM oldids ".
				    "WHERE area=$area AND oldid=$oldid");
}

# takes a dbset and query.  will try query on slave first, then master if not in slave yet.
sub dbs_selectrow_array
{
    my $dbs = shift;
    my $query = shift;

    my @dbl = ($dbs->{'dbh'});
    if ($dbs->{'has_slave'}) { unshift @dbl, $dbs->{'dbr'}; }
    foreach my $db (@dbl) {
	my $ans = $db->selectrow_arrayref($query);
	return wantarray() ? @$ans : $ans->[0] if defined $ans;
    }
    return undef;
}

sub get_friend_items
{
    my $dbarg = shift;
    my $opts = shift;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $sth;

    my $userid = $opts->{'userid'}+0;

    # 'remote' opt takes precendence, then 'remoteid'    
    my $remote = $opts->{'remote'};
    LJ::load_remote($dbs, $remote);
    my $remoteid = $remote ? $remote->{'userid'} : 0;
    if ($remoteid == 0 && $opts->{'remoteid'}) {
	$remoteid = $opts->{'remoteid'} + 0;
	$remote = LJ::load_userid($dbs, $remoteid);
    }

    my @items = ();
    my $itemshow = $opts->{'itemshow'}+0;
    my $skip = $opts->{'skip'}+0;
    my $getitems = $itemshow + $skip;

    my $owners_ref = (ref $opts->{'owners'} eq "HASH") ? $opts->{'owners'} : {};
    my $filter = $opts->{'filter'}+0;

    # sanity check:
    $skip = 0 if ($skip < 0);

    # what do your friends think of remote viewer?  what security level?
    # but only if the remote viewer is a person, not a community/shared journal.
    my $gmask_from = {};
    if ($remote && $remote->{'journaltype'} eq "P") {
	$sth = $dbr->prepare("SELECT ff.userid, ff.groupmask FROM friends fu, friends ff WHERE fu.userid=$userid AND fu.friendid=ff.userid AND ff.friendid=$remoteid");
	$sth->execute;
	while (my ($friendid, $mask) = $sth->fetchrow_array) { 
	    $gmask_from->{$friendid} = $mask; 
	}
	$sth->finish;
    }

    my $filtersql;
    if ($filter) {
	if ($remoteid == $userid) {
	    $filtersql = "AND f.groupmask & $filter";
	}
    }

    my @friends_buffer = ();
    my $total_loaded = 0;
    my $buffer_unit = int($getitems * 1.5);  # load a bit more first to avoid 2nd load

    my $get_next_friend = sub 
    {
	# return one if we already have some loaded.
	if (@friends_buffer) {
	    return $friends_buffer[0];
	}

	# load another batch if we just started or
	# if we just finished a batch.
	if ($total_loaded % $buffer_unit == 0) 
	{
	    my $sth = $dbr->prepare("SELECT u.userid, $LJ::EndOfTime-UNIX_TIMESTAMP(uu.timeupdate), u.clusterid FROM friends f, userusage uu, user u WHERE f.userid=$userid AND f.friendid=uu.userid AND f.friendid=u.userid $filtersql AND u.statusvis='V' AND uu.timeupdate IS NOT NULL ORDER BY 2 LIMIT $total_loaded, $buffer_unit");
	    $sth->execute;

	    while (my ($userid, $update, $clusterid) = $sth->fetchrow_array) {
		push @friends_buffer, [ $userid, $update, $clusterid ];
		$total_loaded++;
	    }

	    # return one if we just found some fine, else we're all
	    # out and there's nobody else to load.
	    if (@friends_buffer) {
		return $friends_buffer[0];
	    } else {
		return undef;
	    }
	}

	# otherwise we must've run out.
	return undef;
    };
    
    my $loop = 1;
    my $max_age = $LJ::MAX_FRIENDS_VIEW_AGE || 3600*24*14;  # 2 week default.
    my $lastmax = $LJ::EndOfTime - time() + $max_age;
    my $itemsleft = $getitems;
    my $fr;

    while ($loop && ($fr = $get_next_friend->()))
    {
	shift @friends_buffer;

	# load the next recent updating friend's recent items
	my $friendid = $fr->[0];

	my @newitems = LJ::get_recent_items($dbs, {
	    'clustersource' => 'slave',  # no effect for cluster 0
	    'clusterid' => $fr->[2],
	    'userid' => $friendid,
	    'remote' => $remote,
	    'itemshow' => $itemsleft,
	    'skip' => 0,
	    'gmask_from' => $gmask_from,
	    'friendsview' => 1,
	    'notafter' => $lastmax,
	});
	
	# stamp each with clusterid if from cluster, so ljviews and other
	# callers will know which items are old (no/0 clusterid) and which
	# are new
	if ($fr->[2]) {
	    foreach (@newitems) { $_->{'clusterid'} = $fr->[2]; }
	}
	
	if (@newitems)
	{
	    push @items, @newitems;

	    $opts->{'owners'}->{$friendid} = 1;

	    $itemsleft--; # we'll need at least one less for the next friend
	    
	    # sort all the total items by rlogtime (recent at beginning)
	    @items = sort { $a->{'rlogtime'} <=> $b->{'rlogtime'} } @items;

	    # cut the list down to what we need.
	    @items = splice(@items, 0, $getitems) if (@items > $getitems);
	} 

	if (@items == $getitems) 
	{
	    $lastmax = $items[-1]->{'rlogtime'};

	    # stop looping if we know the next friend's newest entry
	    # is greater (older) than the oldest one we've already
	    # loaded.
	    my $nextfr = $get_next_friend->();
	    $loop = 0 if ($nextfr && $nextfr->[1] > $lastmax);
	}
    }

    # remove skipped ones
    splice(@items, 0, $skip) if $skip;

    # TODO: KILL! this knows nothing about clusters.
    # return the itemids for them if they wanted them 
    if (ref $opts->{'itemids'} eq "ARRAY") {
	@{$opts->{'itemids'}} = map { $_->{'itemid'} } @items;
    }

    # return the itemids grouped by clusters, if callers wants it.
    if (ref $opts->{'idsbycluster'} eq "HASH") {
	foreach (@items) {
	    if ($_->{'clusterid'}) {
		push @{$opts->{'idsbycluster'}->{$_->{'clusterid'}}}, 
		[ $_->{'ownerid'}, $_->{'itemid'} ];
	    } else {
		push @{$opts->{'idsbycluster'}->{'0'}}, $_->{'itemid'};
	    }
	}
    }
    
    return @items;
}

sub get_recent_items
{
    my $dbarg = shift;
    my $opts = shift;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $sth;

    my @items = ();		# what we'll return

    my $userid = $opts->{'userid'}+0;
    
    # 'remote' opt takes precendence, then 'remoteid'
    my $remote = $opts->{'remote'};
    LJ::load_remote($dbs, $remote);
    my $remoteid = $remote ? $remote->{'userid'} : 0;
    if ($remoteid == 0 && $opts->{'remoteid'}) {
	$remoteid = $opts->{'remoteid'} + 0;
	$remote = LJ::load_userid($dbs, $remoteid);
    }

    my $max_hints = $LJ::MAX_HINTS_LASTN;  # temporary
    my $sort_key = "revttime";

    my $clusterid = $opts->{'clusterid'}+0;
    my $logdb = $dbr;

    if ($clusterid) {
	my $source = $opts->{'clustersource'} eq "slave" ? "slave" : "";
	$logdb = LJ::get_dbh("cluster${clusterid}$source");
    }

    # community/friend views need to post by log time, not event time
    $sort_key = "rlogtime" if ($opts->{'order'} eq "logtime" ||
			       $opts->{'friendsview'});

    # 'notafter':
    #   the friends view doesn't want to load things that it knows it
    #   won't be able to use.  if this argument is zero or undefined,
    #   then we'll load everything less than or equal to 1 second from
    #   the end of time.  we don't include the last end of time second
    #   because that's what backdated entries are set to.  (so for one
    #   second at the end of time we'll have a flashback of all those
    #   backdated entries... but then the world explodes and everybody
    #   with 32 bit time_t structs dies)
    my $notafter = $opts->{'notafter'} + 0 || $LJ::EndOfTime - 1;

    my $skip = $opts->{'skip'}+0;
    my $itemshow = $opts->{'itemshow'}+0;
    if ($itemshow > $max_hints) { $itemshow = $max_hints; }
    my $maxskip = $max_hints - $itemshow;
    if ($skip < 0) { $skip = 0; }
    if ($skip > $maxskip) { $skip = $maxskip; }
    my $itemload = $itemshow + $skip;

    # get_friend_items will give us this data structure all at once so
    # we don't have to load each friendof mask one by one, but for 
    # a single lastn view, it's okay to just do it once.
    my $gmask_from = $opts->{'gmask_from'};
    unless (ref $gmask_from eq "HASH") {
	$gmask_from = {};
	if ($remote && $remote->{'journaltype'} eq "P") {
	    ## then we need to load the group mask for this friend
	    $sth = $dbr->prepare("SELECT groupmask FROM friends WHERE userid=$userid ".
				 "AND friendid=$remoteid");
	    $sth->execute;
	    my ($mask) = $sth->fetchrow_array;
	    $gmask_from->{$userid} = $mask;
	}
    }

    # what mask can the remote user see?
    my $mask = $gmask_from->{$userid} + 0;

    # decide what level of security the remote user can see
    my $secwhere = "";
    if ($userid == $remoteid || $opts->{'viewall'}) {
	# no extra where restrictions... user can see all their own stuff
	# alternatively, if 'viewall' opt flag is set, security is off.
    } elsif ($mask) {
	# can see public or things with them in the mask
	$secwhere = "AND (security='public' OR (security='usemask' AND allowmask & $mask != 0))";
    } else {
	# not a friend?  only see public.
	$secwhere = "AND security='public' ";
    }

    # because LJ::get_friend_items needs rlogtime for sorting.
    my $extra_sql;
    if ($opts->{'friendsview'}) {
	if ($clusterid) {
	    $extra_sql .= "journalid AS 'ownerid', rlogtime, ";
	} else {
	    $extra_sql .= "ownerid, rlogtime, ";
	}
    }

    my $sql;

    if ($clusterid) {
	$sql = ("SELECT jitemid AS 'itemid', posterid, security, replycount, $extra_sql ".
		"DATE_FORMAT(eventtime, \"%a %W %b %M %y %Y %c %m %e %d %D %p %i ".
		"%l %h %k %H\") AS 'alldatepart' ".
		"FROM log2 WHERE journalid=$userid AND $sort_key <= $notafter $secwhere ".
		"ORDER BY journalid, $sort_key ".
		"LIMIT $skip,$itemshow");
    } else {
	# old tables ("cluster 0")
	$sql = ("SELECT itemid, posterid, security, replycount, $extra_sql ".
		"DATE_FORMAT(eventtime, \"%a %W %b %M %y %Y %c %m %e %d %D %p %i ".
		"%l %h %k %H\") AS 'alldatepart' ".
		"FROM log WHERE ownerid=$userid AND $sort_key <= $notafter $secwhere ".
		"ORDER BY ownerid, $sort_key ".
		"LIMIT $skip,$itemshow");
    }

    $sth = $logdb->prepare($sql);
    $sth->execute;
    if ($logdb->err) { die $logdb->errstr; }
    while (my $li = $sth->fetchrow_hashref) {
	push @items, $li;
	push @{$opts->{'itemids'}}, $li->{'itemid'};
    }
    return @items;
}

# <LJFUNC>
# name: LJ::set_userprop
# des: Sets a userprop by name for a user.
# args: userid, propname, value
# des-userid: The userid of the user.
# des-propname: The name of the property.
# des-value: The value to set to the property.
# </LJFUNC>
sub set_userprop
{
    my ($dbarg, $userid, $propname, $value) = @_;
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    
    my $p;

    if ($LJ::CACHE_USERPROP{$propname}) {
	$p = $LJ::CACHE_USERPROP{$propname};
    } else {
	my $qpropname = $dbh->quote($propname);
	$userid += 0;
	my $propid;
	my $sth;
	
	$sth = $dbh->prepare("SELECT upropid, indexed FROM userproplist WHERE name=$qpropname");
	$sth->execute;
	$p = $sth->fetchrow_hashref;
	return unless ($p);
	$LJ::CACHE_USERPROP{$propname} = $p;
    }

    my $table = $p->{'indexed'} ? "userprop" : "userproplite";
    if (defined $value && $value ne "") {
	$value = $dbh->quote($value);
	$dbh->do("REPLACE INTO $table (userid, upropid, value) VALUES ($userid, $p->{'upropid'}, $value)");
    } else {
	$dbh->do("DELETE FROM $table WHERE userid=$userid AND upropid=$p->{'upropid'}");
    }
}

sub register_authaction
{
    my $dbarg = shift;
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};

    my $userid = shift;  $userid += 0;
    my $action = $dbh->quote(shift);
    my $arg1 = $dbh->quote(shift);
    
    # make the authcode
    my $authcode = LJ::make_auth_code(15);
    my $qauthcode = $dbh->quote($authcode);

    my $sth = $dbh->prepare("INSERT INTO authactions (aaid, userid, datecreate, authcode, action, arg1) VALUES (NULL, $userid, NOW(), $qauthcode, $action, $arg1)");
    $sth->execute;

    if ($dbh->err) {
	return 0;
    } else {
	return { 'aaid' => $dbh->{'mysql_insertid'},
		 'authcode' => $authcode,
	     };
    }
}

# <LJFUNC>
# name: LJ::make_cookie
# des: Prepares cookie header lines.
# returns: An array of cookie lines.
# args: name, value, expires, path, domain
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
# name: LJ::statushistory_add
# des: Adds a row to a user's statushistory
# returns: boolean; 1 on success, 0 on failure
# args: dbarg, userid, adminid, shtype, notes
# des-userid: The user getting acted on.
# des-adminid: The site admin doing the action.
# des-shtype: The status history type code.
# des-notes: Optional notes associated with this action.
# </LJFUNC>
sub statushistory_add
{
    my $dbarg = shift;
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};

    my $userid = shift;  $userid += 0;
    my $actid  = shift;  $actid  += 0;

    my $qshtype = $dbh->quote(shift);
    my $qnotes  = $dbh->quote(shift);
    
    $dbh->do("INSERT INTO statushistory (userid, adminid, shtype, notes) ".
	     "VALUES ($userid, $actid, $qshtype, $qnotes)");
    return $dbh->err ? 0 : 1;
}

# <LJFUNC>
# name: LJ::make_link
# des: Takes a group of key=value pairs to append to a url
# returns: The finished url
# args: url, vars
# des-url: A string with the url to append to.
# des-vars: A hash of the key=value pairs to append with.
# </LJFUNC>
sub make_link
{
    my $url = shift;
    my $vars = shift;
    my $append = "?";
    foreach (keys %$vars) {
	next if ($vars->{$_} eq "");
	$url .= "${append}${_}=$vars->{$_}";
	$append = "&";
    }
    return $url;
}

# <LJFUNC>
# name: LJ::ago_text
# des: Turns a number of seconds into the largest possible unit of
#      time. "2 weeks", "4 days", or "20 hours".
# returns: A string with the number of largest units found
# args: secondsold
# des-secondsold: The number of seconds from now something was made.
# </LJFUNC>
sub ago_text
{
    my $secondsold = shift;
    return "Never." unless ($secondsold);
    my $num;
    my $unit;
    if ($secondsold > 60*60*24*7) {
	$num = int($secondsold / (60*60*24*7));
	$unit = "week";
    } elsif ($secondsold > 60*60*24) {
	$num = int($secondsold / (60*60*24));
	$unit = "day";
    } elsif ($secondsold > 60*60) {
	$num = int($secondsold / (60*60));
	$unit = "hour";
    } elsif ($secondsold > 60) {
	$num = int($secondsold / (60));
	$unit = "minute";
    } else {
	$num = $secondsold;
	$unit = "second";
    }
    return "$num $unit" . ($num==1?"":"s") . " ago";
}

# <LJFUNC>
# name: LJ::auth_fields
# des: Returns a form for either submitting username/password to a script or
#      entering a new username/password.
# returns: The built form
# args: form, opts?
# des-form: The hash of form information, which is used to determine whether to
#           get the current login info and display a concise form, or to display
#           a login form.
# des-opts: hashref containing 'user' key to force (finds/makes the hpassword)
# </LJFUNC>
sub auth_fields
{
    my $form = shift;
    my $opts = shift;

    my $remote = LJ::get_remote_noauth();
    my $ret = "";
    if ((!$form->{'altlogin'} && $remote) || $opts->{'user'}) 
    {
	my $hpass;
	my $luser = $opts->{'user'} || $remote->{'user'};
	if ($opts->{'user'}) {
	    $hpass = $form->{'hpassword'} || LJ::hash_password($form->{'password'});
	} elsif ($remote && $BMLClient::COOKIE{"ljhpass"} =~ /^$luser:(.+)/) {
	    $hpass = $1;
	}

	my $alturl = $ENV{'REQUEST_URI'};
	$alturl .= ($alturl =~ /\?/) ? "&amp;" : "?";
	$alturl .= "altlogin=1";

	$ret .= "<tr align='left'><td colspan='2' align='left'>You are currently logged in as <b>$luser</b>.";
	$ret .= "<br />If this is not you, <a href='$alturl'>click here</a>.\n"
	    unless $opts->{'noalt'};
	$ret .= "<input type='hidden' name='user' value='$luser'>\n";
	$ret .= "<input type='hidden' name='hpassword' value='$hpass'><br />&nbsp;\n";
	$ret .= "</td></tr>\n";
    } else {
	$ret .= "<tr align='left'><td>Username:</td><td align='left'><input type='text' name='user' size='15' maxlength='15' value='";
	my $user = $form->{'user'};
	unless ($user || $ENV{'QUERY_STRING'} =~ /=/) { $user=$ENV{'QUERY_STRING'}; }
	$ret .= BMLUtil::escapeall($user) unless ($form->{'altlogin'});
	$ret .= "'></td></tr>\n";
	$ret .= "<tr><td>Password:</td><td align='left'>\n";
	my $epass = LJ::ehtml($form->{'password'});
	$ret .= "<input type='password' name='password' size='15' maxlength='30' value='$epass'>";
	$ret .= "</td></tr>\n";
    }
    return $ret;
}


sub auth_fields_2
{
    my $dbs = shift;
    my $form = shift;
    my $opts = shift;
    my $remote = LJ::get_remote($dbs);
    my $ret = "";

    # text box mode
    if ($form->{'authas'} eq "(other)" || $form->{'altlogin'} || 
	$form->{'user'} || ! $remote)
    {
	$ret .= "<tr><td align='right'><u>U</u>sername:</td><td align='left'><input type=\"text\" name='user' size='15' maxlength='15' accesskey='u' value=\"";
	my $user = $form->{'user'};
	unless ($user || $ENV{'QUERY_STRING'} =~ /=/) { $user=$ENV{'QUERY_STRING'}; }
	$ret .= BMLUtil::escapeall($user) unless ($form->{'altlogin'});
	$ret .= "\"></td></tr>\n";
	$ret .= "<tr><td align='right'><u>P</u>assword:</td><td align='left'>\n";
	$ret .= "<input type='password' name='password' size='15' maxlength='30' accesskey='p' value=\"" . LJ::ehtml($opts->{'password'}) . "\">";
	$ret .= "</td></tr>\n";
	return $ret;
    }

    # logged in mode
    $ret .= "<tr><td align='right'><u>U</u>sername:</td><td align='left'>";

    my $alturl = LJ::self_link($form, { 'altlogin' => 1 });
    my @shared = ($remote->{'user'});

    my $sopts = {};
    $sopts->{'notshared'} = 1 unless $opts->{'shared'};
    $sopts->{'getother'} = $opts->{'getother'};

    $ret .= LJ::make_shared_select($dbs, $remote, $form, $sopts);

    if ($sopts->{'getother'}) {
	my $alturl = LJ::self_link($form, { 'altlogin' => 1 });
	$ret .= "&nbsp;(<a href='$alturl'>Other</a>)";
    }

    $ret .= "</td></tr>\n";
    return $ret;
}

sub make_shared_select
{
    my ($dbs, $u, $form, $opts) = @_;

    my %u2k;
    $u2k{$u->{'user'}} = "(remote)";

    my @choices = ("(remote)", $u->{'user'});
    unless ($opts->{'notshared'}) {
	foreach (LJ::get_shared_journals($dbs, $u)) {
	    push @choices, $_, $_;
	    $u2k{$_} = $_;
	}
    }
    unless ($opts->{'getother'}) {
	push @choices, "(other)", "Other...";
    }
    
    if (@choices > 2) {
	my $sel;
	if ($form->{'user'}) {
	    $sel = $u2k{$form->{'user'}} || "(other)";
	} else {
	    $sel = $form->{'authas'};	    
	}
	return LJ::html_select({ 
	    'name' => 'authas', 
	    'raw' => "accesskey='u'",
	    'selected' => $sel,
	}, @choices);
    } else {
	return "<b>$u->{'user'}</b>";
    }
}

sub get_shared_journals
{
    my $dbs = shift;
    my $u = shift;
    LJ::load_user_privs($dbs, $u, "sharedjournal");
    return sort keys %{$u->{'_priv'}->{'sharedjournal'}};
}

sub get_effective_user
{
    my $dbs = shift;
    my $opts = shift;
    my $f = $opts->{'form'};
    my $refu = $opts->{'out_u'};
    my $referr = $opts->{'out_err'};
    my $remote = $opts->{'remote'};
    
    $$referr = "";

    # presence of 'altlogin' means user is probably logged in but
    # wants to act as somebody else, so ignore their cookie and just
    # fail right away, which'll cause the form to be loaded where they
    # can enter manually a username.
    if ($f->{'altlogin'}) { return ""; }

    # this means the same, and is used by LJ::make_shared_select:
    if ($f->{'authas'} eq "(other)") { return ""; }

    # an explicit 'user' argument overrides the remote setting.  if
    # the password is correct, the user they requested is the
    # effective one, else we have no effective yet.
    if ($f->{'user'}) {
	my $u = LJ::load_user($dbs, $f->{'user'});
	unless ($u) {
	    $$referr = "Invalid user.";
	    return;
	}

	# if password present, check it.
	if ($f->{'password'} || $f->{'hpassword'}) {
	    if (LJ::auth_okay($u, $f->{'password'}, $f->{'hpassword'}, $u->{'password'})) {
		$$refu = $u;
		return $f->{'user'};
	    } else {
		$$referr = "Invalid password.";
		return;
	    }
	}

	# otherwise don't check it and return nothing (to prevent the
	# remote setting from taking place... this forces the
	# user/password boxes to appear)
	return;
    }
    
    # not logged in?
    return unless $remote;

    # logged in. use self identity unless they're requesting to act as
    # a community.
    return $remote->{'user'} 
    unless ($f->{'authas'} && $f->{'authas'} ne "(remote)");

    # if they have the privs, let them be that community
    return $f->{'authas'}
    if (LJ::check_priv($dbs, $remote, "sharedjournal", $f->{'authas'}));

    # else, complain.
    $$referr = "Invalid privileges to act as requested community.";
    return;
}

# <LJFUNC>
# name: LJ::self_link
# des: Takes the URI of the current page, and adds the current form data
#      to the url, then adds any additional data to the url.
# returns: The full url
# args: form, newvars
# des-form: A hashref of the form information from the page.
# des-newvars: A hashref of information to add to the link which is not in
#              the form hash.
# </LJFUNC>
sub self_link
{
    my $form = shift;
    my $newvars = shift;
    my $link = $ENV{'REQUEST_URI'};
    $link =~ s/\?.+//;
    $link .= "?";
    foreach (keys %$newvars) {
	if (! exists $form->{$_}) { $form->{$_} = ""; }
    }
    foreach (sort keys %$form) {
	if (defined $newvars->{$_} && ! $newvars->{$_}) { next; }
	my $val = $newvars->{$_} || $form->{$_};
	next unless $val;
	$link .= LJ::eurl($_) . "=" . LJ::eurl($val) . "&";
    }
    chop $link;
    return $link;
}

# <LJFUNC>
# name: LJ::get_query_string
# des: Returns the query string, which can be in a number of spots
#      depending on the webserver & configuration, sadly.
# returns: String; query string.
# </LJFUNC>
sub get_query_string
{
    my $q = $ENV{'QUERY_STRING'} || $ENV{'REDIRECT_QUERY_STRING'};
    if ($q eq "" && $ENV{'REQUEST_URI'} =~ /\?(.+)/) {
	$q = $1;
    }
    return $q;
}

# <LJFUNC>
# name: LJ::get_form_data
# des: Loads a hashref with form data from a GET or POST request.
# args: hashref, type?
# des-hashref: Hashref to populate with form data.
# des-type: If "GET", will ignore POST data.
# </LJFUNC>
sub get_form_data 
{
    my $hashref = shift;
    my $type = shift;
    my $buffer;

    if ($ENV{'REQUEST_METHOD'} eq 'POST' && $type ne "GET") {
        read(STDIN, $buffer, $ENV{'CONTENT_LENGTH'});
    } else {
        $buffer = $ENV{'QUERY_STRING'} || $ENV{'REDIRECT_QUERY_STRING'};
	if ($buffer eq "" && $ENV{'REQUEST_URI'} =~ /\?(.+)/) {
	    $buffer = $1;
	}
    }
    
    # Split the name-value pairs
    my $pair;
    my @pairs = split(/&/, $buffer);
    my ($name, $value);
    foreach $pair (@pairs)
    {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $hashref->{$name} .= $hashref->{$name} ? "\0$value" : $value;
    }
}

# <LJFUNC>
# name: LJ::is_valid_authaction
# des: Validates a shared secret (authid/authcode pair)
# returns: Hashref of authaction row from database.
# args: dbarg, aaid, auth
# des-aaid: Integer; the authaction ID.
# des-auth: String; the auth string. (random chars the client already got)
# </LJFUNC>
sub is_valid_authaction
{
    my $dbarg = shift;
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    
    # TODO: make this use slave if available (low usage/priority)
    my ($aaid, $auth) = map { $dbh->quote($_) } @_;
    my $sth = $dbh->prepare("SELECT aaid, userid, datecreate, authcode, action, arg1 FROM authactions WHERE aaid=$aaid AND authcode=$auth");
    $sth->execute;
    return $sth->fetchrow_hashref;
}

# <LJFUNC>
# name: LJ::fill_var_props
# args: vars, key, hashref
# des: S1 utility function to interpolate %%variables%% in a variable.  If
#      a modifier is given like %%foo:var%%, then [func[LJ::fvp_transform]]
#      is called.
# des-vars: hashref with keys being S1 vars
# des-key: the variable in the vars hashref we're expanding
# des-hashref: hashref of values that could interpolate.
# returns: Expanded string.
# </LJFUNC>
sub fill_var_props
{
    my ($vars, $key, $hashref) = @_;
    my $data = $vars->{$key};
    $data =~ s/%%(?:([\w:]+:))?(\S+?)%%/$1 ? LJ::fvp_transform(lc($1), $vars, $hashref, $2) : $hashref->{$2}/eg;
    return $data;
}

# <LJFUNC>
# name: LJ::fvp_transform
# des: Called from [func[LJ::fill_var_props]] to do trasformations.
# args: transform, vars, hashref, attr
# des-transform: The transformation type.
# des-vars: hashref with keys being S1 vars
# des-hashref: hashref of values that could interpolate. (see 
#              [func[LJ::fill_var_props]])
# des-attr: the attribute name that's being interpolated.
# returns: Transformed interpolated variable.
# </LJFUNC>
sub fvp_transform
{
    my ($transform, $vars, $hashref, $attr) = @_;
    my $ret = $hashref->{$attr};
    while ($transform =~ s/(\w+):$//) {
	my $trans = $1;
	if ($trans eq "ue") {
	    $ret = LJ::eurl($ret);
	}
	elsif ($trans eq "xe") {
	    $ret = LJ::exml($ret);
	}
	elsif ($trans eq "lc") {
	    $ret = lc($ret);
	}
	elsif ($trans eq "uc") {
	    $ret = uc($ret);
	}  
	elsif ($trans eq "color") {
	    $ret = $vars->{"color-$attr"};
	}
	elsif ($trans eq "cons") {
	    if ($attr eq "siteroot") { return $LJ::SITEROOT; }
	    if ($attr eq "sitename") { return $LJ::SITENAME; }
	    if ($attr eq "img") { return $LJ::IMGPREFIX; }
	}
    }
    return $ret;
}

# <LJFUNC>
# name: LJ::get_mood_picture
# des: Loads a mood icon hashref given a themeid and moodid.
# args: themeid, moodid, ref
# des-themeid: Integer; mood themeid.
# des-moodid: Integer; mood id.
# des-ref: Hashref to load mood icon data into.
# returns: Boolean; 1 on success, 0 otherwise.
# </LJFUNC>
sub get_mood_picture
{
    my ($themeid, $moodid, $ref) = @_;
    do 
    {
	if ($LJ::CACHE_MOOD_THEME{$themeid}->{$moodid}) {
	    %{$ref} = %{$LJ::CACHE_MOOD_THEME{$themeid}->{$moodid}};
	    if ($ref->{'pic'} =~ m!^/!) {
		$ref->{'pic'} =~ s!^/img!!;
		$ref->{'pic'} = $LJ::IMGPREFIX . $ref->{'pic'};
	    }
	    $ref->{'moodid'} = $moodid;
	    return 1;
	} else {
	    $moodid = $LJ::CACHE_MOODS{$moodid}->{'parent'};
	}
    } 
    while ($moodid);
    return 0;
}


# <LJFUNC>
# name: LJ::prepare_currents
# des: do all the current music/mood/weather/whatever stuff.  only used by ljviews.pl.
# args: dbarg, args
# des-args: hashref with keys: 'props' (a hashref with itemid keys), 'vars' hashref with
#           keys being S1 variables.
# </LJFUNC>
sub prepare_currents
{
    my $dbarg = shift;
    my $args = shift;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $datakey = $args->{'datakey'} || $args->{'itemid'}; # new || old

    my %currents = ();
    my $val;
    if ($val = $args->{'props'}->{$datakey}->{'current_music'}) {
	$currents{'Music'} = $val;
    }
    if ($val = $args->{'props'}->{$datakey}->{'current_mood'}) {
	$currents{'Mood'} = $val;
    }
    if ($val = $args->{'props'}->{$datakey}->{'current_moodid'}) {
	my $theme = $args->{'user'}->{'moodthemeid'};
	LJ::load_mood_theme($dbs, $theme);
	my %pic;
	if (LJ::get_mood_picture($theme, $val, \%pic)) {
	    $currents{'Mood'} = "<IMG SRC=\"$pic{'pic'}\" ALIGN=ABSMIDDLE WIDTH=$pic{'w'} HEIGHT=$pic{'h'} VSPACE=1> $LJ::CACHE_MOODS{$val}->{'name'}";
	} else {
	    $currents{'Mood'} = $LJ::CACHE_MOODS{$val}->{'name'};
	}
    }
    if (%currents) {
	if ($args->{'vars'}->{$args->{'prefix'}.'_CURRENTS'}) 
	{
	    ### PREFIX_CURRENTS is defined, so use the correct style vars

	    my $fvp = { 'currents' => "" };
	    foreach (sort keys %currents) {
		$fvp->{'currents'} .= LJ::fill_var_props($args->{'vars'}, $args->{'prefix'}.'_CURRENT', {
		    'what' => $_,
		    'value' => $currents{$_},
		});
	    }
	    $args->{'event'}->{'currents'} = 
		LJ::fill_var_props($args->{'vars'}, $args->{'prefix'}.'_CURRENTS', $fvp);
	} else 
	{
	    ### PREFIX_CURRENTS is not defined, so just add to %%events%%
	    $args->{'event'}->{'event'} .= "<BR>&nbsp;";
	    foreach (sort keys %currents) {
		$args->{'event'}->{'event'} .= "<BR><B>Current $_</B>: " . $currents{$_} . "\n";
	    }
	}
    }
}


# <LJFUNC>
# name: LJ::http_to_time
# des: Wrapper around HTTP::Date::str2time.  Converts an HTTP
#      date to a Unix time.  See also [func[LJ::time_to_http]].
# args: string
# des-string: HTTP Date.  See RFC 2616 for format.
# returns: integer; Unix time.
# </LJFUNC>
sub http_to_time {
    my $string = shift;
    return HTTP::Date::str2time($string);
}

# <LJFUNC>
# name: LJ::time_to_http
# des: Wrapper around HTTP::Date::time2str.  Converts a Unix time
#      to an HTTP date (RFC 1123 format)  See also [func[LJ::http_to_time]].
# args: time
# des-time: Integer; Unix time.
# returns: String; RFC 1123 date.
# </LJFUNC>
sub time_to_http {
    my $time = shift;
    return HTTP::Date::time2str($time);
}

# <LJFUNC>
# name: LJ::ljuser
# des: Returns the HTML for an userinfo/journal link pair for a given user 
#      name, just like LJUSER does in BML.  But files like cleanhtml.pl
#      and ljpoll.pl need to do that too, but they aren't run as BML.
# args: user, opts?
# des-user: Username to link to.
# des-opts: Optional hashref to control output.  Currently only recognized key
#           is 'full' which when true causes a link to the mode=full userinfo.
# returns: HTML with a little head image & bold text link.
# </LJFUNC>
sub ljuser
{
    my $user = shift;
    my $opts = shift;
    my $andfull = $opts->{'full'} ? "&amp;mode=full" : "";
    return "<a href=\"$LJ::SITEROOT/userinfo.bml?user=$user$andfull\"><img src=\"$LJ::IMGPREFIX/userinfo.gif\" width=\"17\" height=\"17\" align=\"absmiddle\" border=\"0\"></a><b><a href=\"$LJ::SITEROOT/users/$user/\">$user</a></b>";
}

# <LJFUNC>
# name: LJ::get_urls
# des: Returns a list of all referenced URLs from a string
# args: text
# des-text: Text to extra URLs from
# returns: list of URLs
# </LJFUNC>
sub get_urls
{
    my $text = shift;
    my @urls;
    while ($text =~ s!http://[^\s\"\'\<\>]+!!) {
	push @urls, $&;
    }
    return @urls;
}

# <LJFUNC>
# name: LJ::record_meme
# des: Records a URL reference from a journal entry to the meme table.
# args: dbarg, url, posterid, itemid, journalid?
# des-url: URL to log
# des-posterid: Userid of person posting
# des-itemid: Itemid URL appears in
# des-journalid: Optional, journal id of item, if item is clustered.  Otherwise
#                this should be zero or undef.
# </LJFUNC>
sub record_meme
{
    my ($dbarg, $url, $posterid, $itemid, $jid) = @_;
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};

    $url =~ s!/$!!;  # strip / at end
    LJ::run_hooks("canonicalize_url", \$url);
    
    # canonicalize_url hook might just erase it, so
    # we don't want to record it.
    return unless $url;

    my $qurl = $dbh->quote($url);
    $posterid += 0;
    $itemid += 0;
    $jid += 0;
    LJ::query_buffer_add($dbs, "meme",
			 "REPLACE INTO meme (url, posterid, journalid, itemid) " .
			 "VALUES ($qurl, $posterid, $jid, $itemid)");
}

# <LJFUNC>
# name: LJ::name_caps
# des: Given a user's capability class bit mask, returns a
#      site-specific string representing the capability class name.
# args: caps
# des-caps: 16 bit capability bitmask
# </LJFUNC>
sub name_caps
{
    return undef unless LJ::are_hooks("name_caps");
    my $caps = shift;
    my @r = LJ::run_hooks("name_caps", $caps);
    return $r[0]->[0];
}

# <LJFUNC>
# name: LJ::name_caps_short
# des: Given a user's capability class bit mask, returns a
#      site-specific short string code.
# args: caps
# des-caps: 16 bit capability bitmask
# </LJFUNC>
sub name_caps_short
{
    return undef unless LJ::are_hooks("name_caps_short");
    my $caps = shift;
    my @r = LJ::run_hooks("name_caps_short", $caps);
    return $r[0]->[0];
}

# <LJFUNC>
# name: LJ::get_cap
# des: Given a user object or capability class bit mask and a capability/limit name,
#      returns the maximum value allowed for given user or class, considering 
#      all the limits in each class the user is a part of.
# args: u_cap, capname
# des-u_cap: 16 bit capability bitmask or a user object from which the
#            bitmask could be obtained
# des-capname: the name of a limit, defined in doc/capabilities.txt
# </LJFUNC>
sub get_cap
{
    my $caps = shift;   # capability bitmask (16 bits), or user object
    my $cname = shift;  # capability limit name
    if (! defined $caps) { $caps = 0; }
    elsif (ref $caps eq "HASH") { $caps = $caps->{'caps'}; }
    my $max = undef;
    foreach my $bit (keys %LJ::CAP) {
	next unless ($caps & (1 << $bit));
	my $v = $LJ::CAP{$bit}->{$cname};
	next unless (defined $v);
	next if (defined $max && $max > $v);
	$max = $v;
    }
    return defined $max ? $max : $LJ::CAP_DEF{$cname};
}

# <LJFUNC>
# name: LJ::get_cap_min
# des: Just like [func[LJ::get_cap]], but returns the minimum value.
#      Although it might not make sense at first, some things are 
#      better when they're low, like the minimum amount of time
#      a user might have to wait between getting updates or being
#      allowed to refresh a page.
# args: u_cap, capname
# des-u_cap: 16 bit capability bitmask or a user object from which the
#            bitmask could be obtained
# des-capname: the name of a limit, defined in doc/capabilities.txt
# </LJFUNC>
sub get_cap_min
{
    my $caps = shift;   # capability bitmask (16 bits), or user object
    my $cname = shift;  # capability name
    if (! defined $caps) { $caps = 0; }
    elsif (ref $caps eq "HASH") { $caps = $caps->{'caps'}; }
    my $min = undef;
    foreach my $bit (keys %LJ::CAP) {
	next unless ($caps & (1 << $bit));
	my $v = $LJ::CAP{$bit}->{$cname};
	next unless (defined $v);
	next if (defined $min && $min < $v);
	$min = $v;
    }
    return defined $min ? $min : $LJ::CAP_DEF{$cname};
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
    return "$pre(=HELP $LJ::HELPURL{$topic} HELP=)$post";
}

# <LJFUNC>
# name: LJ::are_hooks
# des: Returns true if the site has one or more hooks installed for
#      the given hookname.
# args: hookname
# </LJFUNC>
sub are_hooks
{
    my $hookname = shift;
    return defined $LJ::HOOKS{$hookname};
}

# <LJFUNC>
# name: LJ::clear_hooks
# des: Removes all hooks.
# </LJFUNC>
sub clear_hooks
{
    %LJ::HOOKS = ();
}

# <LJFUNC>
# name: LJ::run_hooks
# des: Runs all the site-specific hooks of the given name.
# returns: list of arrayrefs, one for each hook ran, their
#          contents being their own return values.
# args: hookname, args*
# des-args: Arguments to be passed to hook.
# </LJFUNC>
sub run_hooks
{
    my $hookname = shift;
    my @args = shift;
    my @ret;
    foreach my $hook (@{$LJ::HOOKS{$hookname}}) {
	push @ret, [ $hook->(@args) ];
    }
    return @ret;
}

# <LJFUNC>
# name: LJ::register_hook
# des: Installs a site-specific hook.  Installing multiple hooks per hookname
#      is valid.  They're run later in the order they're registered.
# args: hookname, subref
# des-subref: Subroutine reference to run later.
# </LJFUNC>
sub register_hook
{
    my $hookname = shift;
    my $subref = shift;
    push @{$LJ::HOOKS{$hookname}}, $subref;
}

# <LJFUNC>
# name: LJ::make_auth_code
# des: Makes a random string of characters of a given length.
# returns: string of random characters, from an alphabet of 30
#          letters & numbers which aren't easily confused.
# args: length
# des-length: length of auth code to return
# </LJFUNC>
sub make_auth_code
{
    my $length = shift;
    my $digits = "abcdefghjkmnpqrstvwxyz23456789";
    my $auth;
    for (1..$length) { $auth .= substr($digits, int(rand(30)), 1); }
    return $auth;
}

# <LJFUNC>
# name: LJ::acid_encode
# des: Given a decimal number, returns base 30 encoding
#      using an alphabet of letters & numbers that are
#      not easily mistaken for each other.
# returns: Base 30 encoding, alwyas 7 characters long.
# args: number
# des-number: Number to encode in base 30.
# </LJFUNC>
sub acid_encode
{
    my $num = shift;
    my $acid = "";
    my $digits = "abcdefghjkmnpqrstvwxyz23456789";
    while ($num) {
	my $dig = $num % 30;
	$acid = substr($digits, $dig, 1) . $acid;
	$num = ($num - $dig) / 30;
    }
    return ("a"x(7-length($acid)) . $acid);
}

# <LJFUNC>
# name: LJ::acid_decode
# des: Given an acid encoding from [func[LJ::acid_encode]], 
#      returns the original decimal number.
# returns: Integer.
# args: acid
# des-acid: base 30 number from [func[LJ::acid_encode]].
# </LJFUNC>
sub acid_decode
{
    my $acid = shift;
    $acid = lc($acid);
    my %val;
    my $digits = "abcdefghjkmnpqrstvwxyz23456789";
    for (0..30) { $val{substr($digits,$_,1)} = $_; }
    my $num = 0;
    my $place = 0;
    while ($acid) {
	return 0 unless ($acid =~ s/[$digits]$//o);
	$num += $val{$&} * (30 ** $place++);	
    }
    return $num;    
}

# <LJFUNC>
# name: LJ::acct_code_generate
# des: Creates an invitation code from an optional userid
#      for use by anybody.
# returns: Account/Invite code.
# args: dbarg, userid?
# des-userid: Userid to make the invitation code from,
#             else the code will be from userid 0 (system)
# </LJFUNC>
sub acct_code_generate
{
    my $dbarg = shift;
    my $userid = shift;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $auth = LJ::make_auth_code(5);
    $userid = int($userid);
    $dbh->do("INSERT INTO acctcode (acid, userid, rcptid, auth) ".
	     "VALUES (NULL, $userid, 0, \"$auth\")");
    my $acid = $dbh->{'mysql_insertid'};
    return undef unless $acid;
    return acct_code_encode($acid, $auth);
}

# <LJFUNC>
# name: LJ::acct_code_encode
# des: Given an account ID integer and a 5 digit auth code, returns
#      a 12 digit account code.
# returns: 12 digit account code.
# args: acid, auth
# des-acid: account ID, a 4 byte unsigned integer
# des-auth: 5 random characters from base 30 alphabet.
# </LJFUNC>
sub acct_code_encode
{
    my $acid = shift;
    my $auth = shift;
    return lc($auth) . acid_encode($acid);
}

# <LJFUNC>
# name: LJ::acct_code_decode
# des: Breaks an account code down into its two parts
# returns: list of (account ID, auth code)
# args: code
# des-code: 12 digit account code
# </LJFUNC>
sub acct_code_decode
{
    my $code = shift;
    return (acid_decode(substr($code, 5, 7)), lc(substr($code, 0, 5)));
}

# <LJFUNC>
# name: LJ::acct_code_check
# des: Checks the validity of a given account code
# returns: boolean; 0 on failure, 1 on validity. sets $$err on failure.
# args: dbarg, code, err?, userid?
# des-code: account code to check
# des-err: optional scalar ref to put error message into on failure
# des-userid: optional userid which is allowed in the rcptid field,
#             to allow for htdocs/create.bml case when people double
#             click the submit button.
# </LJFUNC>
sub acct_code_check
{
    my $dbarg = shift;
    my $code = shift;
    my $err = shift;     # optional; scalar ref
    my $userid = shift;  # optional; acceptable userid (double-click proof)
    
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    unless (length($code) == 12) {
	$$err = "Malformed code; not 12 characters.";
	return 0;	 
    }

    my ($acid, $auth) = acct_code_decode($code);

    # are we sure this is what the master has?  if we have a slave, could be behind.
    my $definitive = ! $dbs->{'has_slave'};

    # try to load from slave
    my $ac = $dbr->selectrow_hashref("SELECT userid, rcptid, auth FROM acctcode WHERE acid=$acid");

    # if we loaded something, and that code's used, it must be what master has
    if ($ac && $ac->{'rcptid'}) {
	$definitive = 1;
    }

    # unless we're sure we have a clean record, load from master:
    unless ($definitive) {
	$ac = $dbh->selectrow_hashref("SELECT userid, rcptid, auth FROM acctcode WHERE acid=$acid");
    }

    unless ($ac && $ac->{'auth'} eq $auth) {
	$$err = "Invalid account code.";
	return 0;
    }
    
    if ($ac->{'rcptid'} && $ac->{'rcptid'} != $userid) {
	$$err = "This code has already been used.";
	return 0;
    }
    
    return 1;
}

# <LJFUNC>
# name: LJ::load_mood_theme
# des: Loads and caches a mood theme, or returns immediately if already loaded.
# args: dbarg, themeid
# des-themeid: the mood theme ID to load
# </LJFUNC>
sub load_mood_theme
{
    my $dbarg = shift;
    my $themeid = shift;
    return if ($LJ::CACHE_MOOD_THEME{$themeid});

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbr = $dbs->{'reader'};

    $themeid += 0;
    my $sth = $dbr->prepare("SELECT moodid, picurl, width, height FROM moodthemedata WHERE moodthemeid=$themeid");
    $sth->execute;
    while (my ($id, $pic, $w, $h) = $sth->fetchrow_array) {
	$LJ::CACHE_MOOD_THEME{$themeid}->{$id} = { 'pic' => $pic, 'w' => $w, 'h' => $h };
    }
    $sth->finish;
}

# <LJFUNC>
# name: LJ::load_props
# des: Loads and caches one or more of the various *proplist tables:
#      logproplist, talkproplist, and userproplist, which describe
#      the various meta-data that can be stored on log (journal) items,
#      comments, and users, respectively.
# args: dbarg, table*
# des-table: a list of tables' proplists to load.  can be one of
#            "log", "talk", or "user".
# </LJFUNC>
sub load_props
{
    my $dbarg = shift;
    my @tables = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbr = $dbs->{'reader'};

    my %keyname = qw(log  propid
		     talk tpropid
		     user upropid);

    foreach my $t (@tables) {
	next unless defined $keyname{$t};
	next if (defined $LJ::CACHE_PROP{$t});
	my $sth = $dbr->prepare("SELECT * FROM ${t}proplist");
	$sth->execute;
	while (my $p = $sth->fetchrow_hashref) {
	    $p->{'id'} = $p->{$keyname{$t}};
	    $LJ::CACHE_PROP{$t}->{$p->{'name'}} = $p;
	    $LJ::CACHE_PROPID{$t}->{$p->{'id'}} = $p;
	}
	$sth->finish;
    }
}

# <LJFUNC>
# name: LJ::get_prop
# des: This is used after [func[LJ::load_props]] is called to retrieve
#      a hashref of a row from the given tablename's proplist table.
#      One difference from getting it straight from the database is
#      that the 'id' key is always present, as a copy of the real
#      proplist unique id for that table.
# args: table, name
# returns: hashref of proplist row from db
# des-table: the tables to get a proplist hashref from.  can be one of
#            "log", "talk", or "user".
# des-name: the name of the prop to get the hashref of.
# </LJFUNC>
sub get_prop
{
    my $table = shift;
    my $name = shift;
    return 0 unless defined $LJ::CACHE_PROP{$table};
    return $LJ::CACHE_PROP{$table}->{$name};
}

# <LJFUNC>
# name: LJ::load_codes
# des: Populates hashrefs with lookup data from the database or from memory,
#      if already loaded in the past.  Examples of such lookup data include
#      state codes, country codes, color name/value mappings, etc.
# args: dbarg, whatwhere
# des-whatwhere: a hashref with keys being the code types you want to load
#                and their associated values being hashrefs to where you
#                want that data to be populated.
# </LJFUNC>
sub load_codes
{
    my $dbarg = shift;
    my $req = shift;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    foreach my $type (keys %{$req})
    {
	unless ($LJ::CACHE_CODES{$type})
	{
	    $LJ::CACHE_CODES{$type} = [];
	    my $qtype = $dbr->quote($type);
	    my $sth = $dbr->prepare("SELECT code, item FROM codes WHERE type=$qtype ORDER BY sortorder");
	    $sth->execute;
	    while (my ($code, $item) = $sth->fetchrow_array)
	    {
		push @{$LJ::CACHE_CODES{$type}}, [ $code, $item ];
	    }
	}

	foreach my $it (@{$LJ::CACHE_CODES{$type}})
	{
	    if (ref $req->{$type} eq "HASH") {
		$req->{$type}->{$it->[0]} = $it->[1];
	    } elsif (ref $req->{$type} eq "ARRAY") {
		push @{$req->{$type}}, { 'code' => $it->[0], 'item' => $it->[1] };
	    }
	}
    }
}

# <LJFUNC>
# name: LJ::img
# des: Returns an HTML &lt;img&gt; or &lt;input&gt; tag to an named image
#      code, which each site may define with a different image file with 
#      its own dimensions.  This prevents hard-coding filenames & sizes
#      into the source.  The real image data is stored in LJ::Img, which
#      has default values provided in cgi-bin/imageconf.pl but can be 
#      overridden in cgi-bin/ljconfig.pl.
# args: imagecode, type?, name?
# des-imagecode: The unique string key to reference the image.  Not a filename,
#                but the purpose or location of the image.
# des-type: By default, the tag returned is an &lt;img&gt; tag, but if 'type'
#           is "input", then an input tag is returned.
# des-name: The name of the input element, if type == "input".
# </LJFUNC>
sub img
{
    my $ic = shift;
    my $type = shift;  # either "" or "input"
    my $name = shift;  # if input

    my $i = $LJ::Img::img{$ic};
    if ($type eq "") {
	return "<img src=\"$LJ::IMGPREFIX$i->{'src'}\" width=\"$i->{'width'}\" height=\"$i->{'height'}\" alt=\"$i->{'alt'}\" border=0>";
    }
    if ($type eq "input") {
	return "<input type=\"image\" src=\"$LJ::IMGPREFIX$i->{'src'}\" width=\"$i->{'width'}\" height=\"$i->{'height'}\" alt=\"$i->{'alt'}\" border=0 name=\"$name\">";
    }
    return "<b>XXX</b>";
}

# <LJFUNC>
# name: LJ::load_user_props
# des: Given a user hashref, loads the values of the given named properties
#      into that user hashref.
# args: dbarg, u, propname*
# des-propname: the name of a property from the userproplist table.
# </LJFUNC>
sub load_user_props
{
    my $dbarg = shift;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    ## user reference
    my ($uref, @props) = @_;
    my $uid = $uref->{'userid'}+0;
    unless ($uid) {
	$uid = LJ::get_userid($dbarg, $uref->{'user'});
    }
    
    my $propname_where;
    if (@props) {
	$propname_where = "AND upl.name IN (" . join(",", map { $dbh->quote($_) } @props) . ")";
    }
    
    my ($sql, $sth);

    # FIXME: right now we read userprops from both tables (indexed and
    # lite).  we always have to do this for cases when we're loading
    # all props, but when loading a subset, we might be able to
    # eliminate one query or the other if we cache somewhere the
    # userproplist and which props are in which table.  For now,
    # though, this works:

    foreach my $table (qw(userprop userproplite))
    {
	$sql = "SELECT upl.name, up.value FROM $table up, userproplist upl WHERE up.userid=$uid AND up.upropid=upl.upropid $propname_where";
	$sth = $dbr->prepare($sql);
	$sth->execute;
	while ($_ = $sth->fetchrow_hashref) {
	    $uref->{$_->{'name'}} = $_->{'value'};
	}
	$sth->finish;
    }

    # Add defaults to user object.

    # If this was called with no @props, then the function tried
    # to load all metadata.  but we don't know what's missing, so
    # try to apply all defaults.
    unless (@props) { @props = keys %LJ::USERPROP_DEF; }

    foreach my $prop (@props) {
	next if (defined $uref->{$prop});
	$uref->{$prop} = $LJ::USERPROP_DEF{$prop};
    }
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
    $ret .= "(=BADCONTENT=)\n<ul>\n";
    foreach (@errors) {
	$ret .= "<li>$_\n";
    }
    $ret .= "</ul>\n";
    return $ret;
}

# <LJFUNC>
# name: LJ::debug
# des: When $LJ::DEBUG is set, logs the given message to 
#      $LJ::VAR/debug.log.  Or, if $LJ::DEBUG is 2, then 
#      prints to STDOUT.
# returns: 1 if logging disabled, 0 on failure to open log, 1 otherwise
# args: message
# des-message: Message to log.
# </LJFUNC>
sub debug 
{
    return 1 unless ($LJ::DEBUG);
    if ($LJ::DEBUG == 2) {
	print $_[0], "\n";
	return 1;
    }
    open (L, ">>$LJ::VAR/debug.log") or return 0;
    print L scalar(time), ": $_[0]\n";
    close L;
    return 1;
}

# <LJFUNC>
# name: LJ::auth_okay
# des: Validates a user's password.  The "clear" or "md5" argument
#      must be present, and either the "actual" argument (the correct
#      password) must be set, or the first argument must be a user
#      object ($u) with the 'password' key set.  Note that this is
#      the preferred way to validate a password (as opposed to doing
#      it by hand) since this function will use a pluggable authenticator
#      if one is defined, so LiveJournal installations can be based
#      off an LDAP server, for example.
# returns: boolean; 1 if authentication succeeded, 0 on failure
# args: user_u, clear, md5, actual?
# des-user_u: Either the user name or a user object.
# des-clear: Clear text password the client is sending. (need this or md5)
# des-md5: MD5 of the password the client is sending. (need this or clear).
#          If this value instead of clear, clear can be anything, as md5
#          validation will take precedence.
# des-actual: The actual password for the user.  Ignored if a pluggable
#             authenticator is being used.  Required unless the first
#             argument is a user object instead of a username scalar.
# </LJFUNC>
sub auth_okay
{
    my $user = shift;
    my $clear = shift;
    my $md5 = shift;
    my $actual = shift;

    # first argument can be a user object instead of a string, in
    # which case the actual password (last argument) is got from the
    # user object.
    if (ref $user eq "HASH") {
	$actual = $user->{'password'};
	$user = $user->{'user'};
    }

    ## custom authorization:
    if (ref $LJ::AUTH_CHECK eq "CODE") {
	my $type = $md5 ? "md5" : "clear";
	my $try = $md5 || $clear;
	return $LJ::AUTH_CHECK->($user, $try, $type);
    }
    
    ## LJ default authorization:
    return 1 if ($md5 && lc($md5) eq LJ::hash_password($actual));
    return 1 if ($clear eq $actual);
    return 0;
}

# <LJFUNC>
# name: LJ::create_account
# des: Creates a new basic account.  <b>Note:</b> This function is
#      not really too useful but should be extended to be useful so
#      htdocs/create.bml can use it, rather than doing the work itself.
# returns: integer of userid created, or 0 on failure.
# args: dbarg, opts
# des-opts: hashref containing keys 'user', 'name', and 'password'
# </LJFUNC>
sub create_account
{
    my $dbarg = shift;
    my $o = shift;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    my $user = LJ::canonical_username($o->{'user'});
    unless ($user)  {
	return 0;
    }
    
    my $quser = $dbr->quote($user);
    my $qpassword = $dbr->quote($o->{'password'});
    my $qname = $dbr->quote($o->{'name'});

    my $sth = $dbh->prepare("INSERT INTO user (user, name, password) VALUES ($quser, $qname, $qpassword)");
    $sth->execute;
    if ($dbh->err) { return 0; }

    my $userid = $sth->{'mysql_insertid'};
    $dbh->do("INSERT INTO useridmap (userid, user) VALUES ($userid, $quser)");
    $dbh->do("INSERT INTO userusage (userid, timecreate) VALUES ($userid, NOW())");

    LJ::run_hooks("post_create", {
	'dbs' => $dbs,
	'userid' => $userid,
	'user' => $user,
	'code' => undef,
    });
    return $userid;
}

# <LJFUNC>
# name: LJ::is_friend
# des: Checks to see if a user is a friend of another user.
# returns: boolean; 1 if user B is a friend of user A or if A == B
# args: dbarg, usera, userb
# des-usera: Source user hashref or userid.
# des-userb: Destination user hashref or userid. (can be undef)
# </LJFUNC>
sub is_friend
{
    my $dbarg = shift;
    my $ua = shift;
    my $ub = shift;
    
    my $uaid = (ref $ua ? $ua->{'userid'} : $ua)+0;
    my $ubid = (ref $ub ? $ub->{'userid'} : $ub)+0;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
		
    return 0 unless $uaid;
    return 0 unless $ubid;
    return 1 if ($uaid == $ubid);

    my $sth = $dbr->prepare("SELECT COUNT(*) FROM friends WHERE ".
			    "userid=$uaid AND friendid=$ubid");
    $sth->execute;
    my ($is_friend) = $sth->fetchrow_array;
    $sth->finish;
    return $is_friend;
}

# <LJFUNC>
# name: LJ::is_banned
# des: Checks to see if a user is banned from a journal.
# returns: boolean; 1 iff user B is banned from journal A
# args: dbarg, user, journal
# des-user: User hashref or userid.
# des-journal: Journal hashref or userid.
# </LJFUNC>
sub is_banned
{
    my $dbarg = shift;
    my $u = shift;
    my $j = shift;
    
    my $uid = (ref $u ? $u->{'userid'} : $u)+0;
    my $jid = (ref $j ? $j->{'userid'} : $j)+0;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
		
    return 1 unless $uid;
    return 1 unless $jid;

    # for speed: common case is non-community posting and replies
    # in own journal.  avoid db hit.
    return 0 if ($uid == $jid);

    my $sth = $dbr->prepare("SELECT COUNT(*) FROM ban WHERE ".
			    "userid=$jid AND banneduserid=$uid");
    $sth->execute;
    my $is_banned = $sth->fetchrow_array;
    $sth->finish;
    return $is_banned;
}

# <LJFUNC>
# name: LJ::can_view
# des: Checks to see if the remote user can view a given journal entry.
#      <b>Note:</b> This is meant for use on single entries at a time,
#      not for calling many times on every entry in a journal.
# returns: boolean; 1 if remote user can see item
# args: dbarg, remote, item
# des-item: Hashref from the 'log' table.
# </LJFUNC>
sub can_view
{
    my $dbarg = shift;
    my $remote = shift;
    my $item = shift;
    
    # public is okay
    return 1 if ($item->{'security'} eq "public");

    # must be logged in otherwise
    return 0 unless $remote;

    my $userid = int($item->{'ownerid'});
    my $remoteid = int($remote->{'userid'});

    # owners can always see their own.
    return 1 if ($userid == $remoteid);

    # other people can't read private
    return 0 if ($item->{'security'} eq "private");

    # should be 'usemask' security from here out, otherwise
    # assume it's something new and return 0
    return 0 unless ($item->{'security'} eq "usemask");

    # usemask
    my $dbs = make_dbs_from_arg($dbarg);
    my $dbr = $dbs->{'reader'};

    my $sth = $dbr->prepare("SELECT groupmask FROM friends WHERE ".
			    "userid=$userid AND friendid=$remoteid");
    $sth->execute;
    my ($gmask) = $sth->fetchrow_array;
    my $allowed = (int($gmask) & int($item->{'allowmask'}));
    return $allowed ? 1 : 0;  # no need to return matching mask
}

# <LJFUNC>
# name: LJ::get_talktext
# des: Efficiently retrieves a large number of comments, trying first
#      slave database servers for recent items, then the master in 
#      cases of old items the slaves have already disposed of.  See also:
#      [func[LJ::get_logtext]].
# args: dbs, talkid*
# returns: hashref with keys being talkids, values being [ $subject, $body ]
# des-talkid: List of talkids to retrieve the subject & text for.
# </LJFUNC>
sub get_talktext
{
    my $dbs = shift;

    # return structure.
    my $lt = {};

    # keep track of itemids we still need to load.
    my %need;
    foreach (@_) { $need{$_+0} = 1; }

    # always consider hitting the master database, but if a slave is 
    # available, hit that first.
    my @sources = ([$dbs->{'dbh'}, "talktext"]);
    if ($dbs->{'has_slave'}) {
        if ($LJ::USE_RECENT_TABLES) {
	    my $dbt = LJ::get_dbh("recenttext");	    
            unshift @sources, [ $dbt || $dbs->{'dbr'}, "recent_talktext" ];
        } else {
            unshift @sources, [ $dbs->{'dbr'}, "talktext" ];
        }
    }

    while (@sources && %need)
    {
        my $s = shift @sources;
        my ($db, $table) = ($s->[0], $s->[1]);
        my $talkid_in = join(", ", keys %need);

        my $sth = $db->prepare("SELECT talkid, subject, body FROM $table ".
                               "WHERE talkid IN ($talkid_in)");
        $sth->execute;
        while (my ($id, $subject, $body) = $sth->fetchrow_array) {
            $lt->{$id} = [ $subject, $body ];
            delete $need{$id};
        }
    }
    return $lt;

}

# <LJFUNC>
# name: LJ::get_logtext
# des: Efficiently retrieves a large number of journal entry text, trying first
#      slave database servers for recent items, then the master in 
#      cases of old items the slaves have already disposed of.  See also:
#      [func[LJ::get_talktext]].
# args: dbs, itemid*
# returns: hashref with keys being itemids, values being [ $subject, $body ]
# des-itemid: List of itemids to retrieve the subject & text for.
# </LJFUNC>
sub get_logtext
{
    my $dbs = shift;

    # return structure.
    my $lt = {};

    # keep track of itemids we still need to load.
    my %need;
    foreach (@_) { $need{$_+0} = 1; }

    # always consider hitting the master database, but if a slave is 
    # available, hit that first.
    my @sources = ([$dbs->{'dbh'}, "logtext"]);
    if ($dbs->{'has_slave'}) { 
	if ($LJ::USE_RECENT_TABLES) {
	    my $dbt = LJ::get_dbh("recenttext");
	    unshift @sources, [ $dbt || $dbs->{'dbr'}, "recent_logtext" ];
	} else {
	    unshift @sources, [ $dbs->{'dbr'}, "logtext" ];
	}
    }

    while (@sources && %need)
    {
	my $s = shift @sources;
	my ($db, $table) = ($s->[0], $s->[1]);
	my $itemid_in = join(", ", keys %need);

	my $sth = $db->prepare("SELECT itemid, subject, event FROM $table ".
			       "WHERE itemid IN ($itemid_in)");
	$sth->execute;
	while (my ($id, $subject, $event) = $sth->fetchrow_array) {
	    $lt->{$id} = [ $subject, $event ];
	    delete $need{$id};
	}
    }
    return $lt;
}

# <LJFUNC>
# name: LJ::get_logtext2
# des: Efficiently retrieves a large number of journal entry text, trying first
#      slave database servers for recent items, then the master in 
#      cases of old items the slaves have already disposed of.  See also:
#      [func[LJ::get_talktext2]].
# args: u, jitemid*
# returns: hashref with keys being jitemids, values being [ $subject, $body ]
# des-itemid: List of jitemids to retrieve the subject & text for.
# </LJFUNC>
sub get_logtext2
{
    my $u = shift;
    my $clusterid = $u->{'clusterid'};
    my $journalid = $u->{'userid'}+0;

    # return structure.
    my $lt = {};
    return $lt unless $clusterid;

    my $dbh = LJ::get_dbh("cluster$clusterid");
    my $dbr = LJ::get_dbh("cluster${clusterid}slave");

    # keep track of itemids we still need to load.
    my %need;
    foreach (@_) { $need{$_+0} = 1; }

    # always consider hitting the master database, but if a slave is 
    # available, hit that first.
    my @sources = ([$dbh, "logtext2"]);
    if ($dbr) { 
	unshift @sources, [ $dbr, $LJ::USE_RECENT_TABLES ? "recent_logtext2" : "logtext2" ];
    }
    
    while (@sources && %need)
    {
	my $s = shift @sources;
	my ($db, $table) = ($s->[0], $s->[1]);
	my $jitemid_in = join(", ", keys %need);

	my $sth = $db->prepare("SELECT jitemid, subject, event FROM $table ".
			       "WHERE journalid=$journalid AND jitemid IN ($jitemid_in)");
	$sth->execute;
	while (my ($id, $subject, $event) = $sth->fetchrow_array) {
	    $lt->{$id} = [ $subject, $event ];
	    delete $need{$id};
	}
    }
    return $lt;
}

sub get_logtext2multi
{
    my ($dbs, $idsbyc) = @_;
    my $sth;

    # return structure.
    my $lt = {};

    # keep track of itemids we still need to load per cluster
    my %need;
    my @needold;
    foreach my $c (keys %$idsbyc) {
	foreach (@{$idsbyc->{$c}}) {
	    if ($c) {
		$need{$c}->{"$_->[0] $_->[1]"} = 1;
	    } else {
		push @needold, $_+0;
	    }
	}
    }

    # don't handle non-cluster stuff ourselves
    if (@needold)
    {
	my $olt = LJ::get_logtext($dbs, @needold);
	foreach (keys %$olt) {
	    $lt->{"0 $_"} = $olt->{$_};
	}
    }

    # pass 1: slave (trying recent), pass 2: master
    foreach my $pass (1, 2) 
    {
	foreach my $c (keys %need) 
	{
	    next unless keys %{$need{$c}}; 
	    my $db;
	    my $table = "logtext2";
	    if ($pass == 1) { 
		$db = LJ::get_dbh("cluster${c}slave");
		$table = "recent_logtext2" if $LJ::USE_RECENT_TABLES;
	    } else {
		$db = LJ::get_dbh("cluster${c}");		
	    }
	    next unless $db;

	    my $fattyin;
	    foreach (keys %{$need{$c}}) {
		$fattyin .= " OR " if $fattyin;
		my ($a, $b) = split(/ /, $_);
		$fattyin .= "(journalid=$a AND jitemid=$b)";
	    }
	    
	    $sth = $db->prepare("SELECT journalid, jitemid, subject, event ".
				"FROM $table WHERE $fattyin");
	    $sth->execute;
	    while (my ($jid, $jitemid, $subject, $event) = $sth->fetchrow_array) {
		delete $need{$c}->{"$jid $jitemid"};
		$lt->{"$jid $jitemid"} = [ $subject, $event ];
	    }
	}
    }

    return $lt;
}

# <LJFUNC>
# name: LJ::make_text_link
# des: The most pathetic function of them all.  AOL's shitty mail
#      reader interprets all incoming mail as HTML formatted, even if
#      the content type says otherwise.  And AOL users are all too often
#      confused by a a URL that isn't clickable, so to make it easier on
#      them (*sigh*) this function takes a URL and an email address, and
#      if the address is @aol.com, then this function wraps the URL in
#      an anchor tag to its own address.  I'm sorry.
# returns: the same URL, or the URL wrapped in an anchor tag for AOLers
# args: url, email
# des-url: URL to return or wrap.
# des-email: Email address this is going to.  If it's @aol.com, the URL
#            will be wrapped.
# </LJFUNC>
sub make_text_link
{
    my ($url, $email) = @_;
    if ($email =~ /\@aol\.com$/i) {
	return "<a href=\"$url\">$url</a>";
    }
    return $url;
}

# <LJFUNC>
# name: LJ::get_remote
# des: authenticates the user at the remote end based on their cookies 
#      and returns a hashref representing them
# returns: hashref containing 'user' and 'userid' if valid user, else
#          undef.
# args: dbarg, criterr?, cgi?
# des-criterr: scalar ref to set critical error flag.  if set, caller
#              should stop processing whatever it's doing and complain
#              about an invalid login with a link to the logout page.
# des-cgi: Optional CGI.pm reference if using in a script which
#          already uses CGI.pm.
# </LJFUNC>
sub get_remote
{
    my $dbarg = shift;	
    my $criterr = shift; 
    my $cgi = shift;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    $$criterr = 0;

    my $cookie = sub {
	return $cgi ? $cgi->cookie($_[0]) : $BMLClient::COOKIE{$_[0]};
    };

    my ($user, $userid, $caps);

    my $validate = sub {
	my $a = shift;
	# let hooks reject credentials, or set criterr true:
	my $hookparam = {
	    'user' => $a->{'user'},
	    'userid' => $a->{'userid'},
	    'dbs' => $dbs,
	    'caps' => $a->{'caps'},
	    'criterr' => $criterr,
	    'cookiesource' => $cookie,
	};
	my @r = LJ::run_hooks("validate_get_remote", $hookparam);
	return undef if grep { ! $_->[0] } @r;
	return 1;
    };

    ### are they logged in?
    unless ($user = $cookie->('ljuser')) {
	$validate->();
	return undef;
    }

    ### does their login password match their login?
    my $hpass = $cookie->('ljhpass');
    unless ($hpass =~ /^$user:(.+)/) {
	$validate->();
	return undef;
    }
    my $remhpass = $1;
    my $correctpass;     # find this out later.

    unless (ref $LJ::AUTH_CHECK eq "CODE") {
	my $quser = $dbr->quote($user);
	($userid, $correctpass, $caps) = 
	    $dbr->selectrow_array("SELECT userid, password, caps ".
				  "FROM user WHERE user=$quser");

	# each handler must return true, else credentials are ignored:
	return undef unless $validate->({
	    'userid' => $userid,
	    'user' => $user,
	    'caps' => $caps,
	});

    } else {
	$userid = LJ::get_userid($dbh, $user);
    }
    
    unless ($userid && LJ::auth_okay($user, undef, $remhpass, $correctpass)) {
	$validate->();
	return undef;
    }

    return { 'user' => $user,
	     'userid' => $userid, };
}

# <LJFUNC>
# name: LJ::load_remote
# des: Given a partial remote user hashref (from [func[LJ::get_remote]]),
#      loads in the rest, unless it's already loaded.
# args: dbarg, remote
# des-remote: Hashref containing 'user' and 'userid' keys at least.  This
#             hashref will be populated with the rest of the 'user' table
#             data.  If undef, does nothing.
# </LJFUNC>
sub load_remote
{
    my $dbarg = shift;
    my $dbs = LJ::get_dbs();
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    my $remote = shift;
    return unless $remote;
    
    # if all three of these are loaded, this hashref is probably full.
    # (don't want to just test for 2 keys, since keys like '_priv' and
    # _privloaded might be present)
    return if (defined $remote->{'email'} && 
	       defined $remote->{'caps'} &&
	       defined $remote->{'status'});
    
    # try to load this remote user's record
    my $ru = LJ::load_userid($dbs, $remote->{'userid'});
    return unless $ru;

    # merge user record (so we preserve underscore key data structures)
    foreach my $k (keys %$ru) {
	$remote->{$k} = $ru->{$k};
    }
}

# <LJFUNC>
# name: LJ::get_remote_noauth
# des: returns who the remote user says they are, but doesn't check
#      their login token.  disadvantage: insecure, only use when
#      you're not doing anything critical.  advantage:  faster.
# returns: hashref containing only key 'user', not 'userid' like
#          [func[LJ::get_remote]].
# </LJFUNC>
sub get_remote_noauth
{
    ### are they logged in?
    my $remuser = $BMLClient::COOKIE{"ljuser"};
    return undef unless ($remuser =~ /^\w{1,15}$/);

    ### does their login password match their login?
    return undef unless ($BMLClient::COOKIE{"ljhpass"} =~ /^$remuser:(.+)/);
    return { 'user' => $remuser, };
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
    return ($ENV{'REQUEST_METHOD'} eq "POST");
}

# <LJFUNC>
# name: LJ::clear_caches
# des: This function is called from a HUP signal handler and is intentionally
#      very very simple (1 line) so we don't core dump on a system without
#      reentrant libraries.  It just sets a flag to clear the caches at the
#      beginning of the next request (see [func[LJ::handle_caches]]).  
#      There should be no need to ever call this function directly.
# </LJFUNC>
sub clear_caches
{
    $LJ::CLEAR_CACHES = 1;
}

# <LJFUNC>
# name: LJ::handle_caches
# des: clears caches if the CLEAR_CACHES flag is set from an earlier
#      HUP signal that called [func[LJ::clear_caches]], otherwise
#      does nothing.
# returns: true (always) so you can use it in a conjunction of
#          statements in a while loop around the application like:
#          while (LJ::handle_caches() && FCGI::accept())
# </LJFUNC>
sub handle_caches
{
    return 1 unless ($LJ::CLEAR_CACHES);
    $LJ::CLEAR_CACHES = 0;

    do "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";
      
    foreach (keys %LJ::DBCACHE) { 
	my $v = $LJ::DBCACHE{$_};
	$v->disconnect;
    }
    %LJ::DBCACHE = ();

    %LJ::CACHE_PROP = ();
    %LJ::CACHE_STYLE = ();
    $LJ::CACHED_MOODS = 0;
    $LJ::CACHED_MOOD_MAX = 0;
    %LJ::CACHE_MOODS = ();
    %LJ::CACHE_MOOD_THEME = ();
    %LJ::CACHE_USERID = ();
    %LJ::CACHE_USERNAME = ();
    %LJ::CACHE_USERPIC_SIZE = ();
    %LJ::CACHE_CODES = ();
    %LJ::CACHE_USERPROP = ();  # {$prop}->{ 'upropid' => ... , 'indexed' => 0|1 };
    return 1;
}

# <LJFUNC>
# name: LJ::start_request
# des: Before a new web request is obtained, this should be called to 
#      determine if process should die or keep working, clean caches,
#      reload config files, etc.
# returns: 1 if a new request is to be processed, 0 if process should die.
# </LJFUNC>
sub start_request
{
    handle_caches();
    # TODO: check process growth size
    # TODO: auto-restat and reload ljconfig.pl if changed.

    # clear %LJ::DBREQCACHE (like DBCACHE, but verified already for
    # this request to be ->ping'able).  
    %LJ::DBREQCACHE = ();

    return 1;
}

# <LJFUNC>
# name: LJ::load_userpics
# des: Loads a bunch of userpic at once.
# args: dbarg, upics, idlist
# des-upics: hashref to load pictures into, keys being the picids
# des-idlist: arrayref of picids to load
# </LJFUNC>
sub load_userpics
{
    my ($dbarg, $upics, $idlist) = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    my @load_list;
    foreach my $id (@{$idlist}) 
    {
	if ($LJ::CACHE_USERPIC_SIZE{$id}) {
	    $upics->{$id}->{'width'} = $LJ::CACHE_USERPIC_SIZE{$id}->{'width'};
	    $upics->{$id}->{'height'} = $LJ::CACHE_USERPIC_SIZE{$id}->{'height'};
	} elsif ($id+0) {
	    push @load_list, ($id+0);
	}
    }
    return unless (@load_list);
    my $picid_in = join(",", @load_list);
    my $sth = $dbr->prepare("SELECT picid, width, height FROM userpic WHERE picid IN ($picid_in)");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	my $id = $_->{'picid'};
	undef $_->{'picid'};	
	$upics->{$id} = $_;
	$LJ::CACHE_USERPIC_SIZE{$id}->{'width'} = $_->{'width'};
	$LJ::CACHE_USERPIC_SIZE{$id}->{'height'} = $_->{'height'};
    }
}

# <LJFUNC>
# name: LJ::send_mail
# des: Sends email.
# args: opt
# des-opt: Hashref of arguments.  <b>Required:</b> to, from, subject, body.
#          <b>Optional:</b> toname, fromname, cc, bcc
# </LJFUNC>
sub send_mail
{
    my $opt = shift;
    open (MAIL, "|$LJ::SENDMAIL");
    my $toname;
    if ($opt->{'toname'}) {
	$opt->{'toname'} =~ s/[\n\t\(\)]//g;
	$toname = " ($opt->{'toname'})";
    }
    print MAIL "To: $opt->{'to'}$toname\n";
    print MAIL "Cc: $opt->{'bcc'}\n" if ($opt->{'cc'});
    print MAIL "Bcc: $opt->{'bcc'}\n" if ($opt->{'bcc'});
    print MAIL "From: $opt->{'from'}";
    if ($opt->{'fromname'}) {
	print MAIL " ($opt->{'fromname'})";
    }
    print MAIL "\nSubject: $opt->{'subject'}\n\n";
    print MAIL $opt->{'body'};
    close MAIL;
}

# TODO: make this just call the HTML cleaner.
sub strip_bad_code
{
    my $data = shift;
    my $newdata;
    use HTML::TokeParser;
    my $p = HTML::TokeParser->new($data);

    while (my $token = $p->get_token)
    {
	my $type = $token->[0];
	if ($type eq "S") {
	    if ($token->[1] eq "script") {
		$p->unget_token($token);
		$p->get_tag("/script");
	    } else {
		my $tag = $token->[1];
		my $hash = $token->[2];
		delete $hash->{'onabort'};
		delete $hash->{'onblur'};
		delete $hash->{'onchange'};
		delete $hash->{'onclick'};
		delete $hash->{'onerror'};
		delete $hash->{'onfocus'};
		delete $hash->{'onload'};
		delete $hash->{'onmouseout'};
		delete $hash->{'onmouseover'};
		delete $hash->{'onreset'};
		delete $hash->{'onselect'};
		delete $hash->{'onsubmit'};
		delete $hash->{'onunload'};
		if ($tag eq "a") {
		    if ($hash->{'href'} =~ /^\s*javascript:/) { $hash->{'href'} = "about:"; }
		} elsif ($tag eq "meta") {
		    if ($hash->{'content'} =~ /javascript:/) { delete $hash->{'content'}; }
		} elsif ($tag eq "img") {
		    if ($hash->{'src'} =~ /javascript:/) { delete $hash->{'src'}; }
		    if ($hash->{'dynsrc'} =~ /javascript:/) { delete $hash->{'dynsrc'}; }
		    if ($hash->{'lowsrc'} =~ /javascript:/) { delete $hash->{'lowsrc'}; }
		}
		$newdata .= "<" . $tag;
		my $slashclose = delete $hash->{'/'};
		foreach (keys %$hash) {
		    $newdata .= " $_=\"$hash->{$_}\"";
		}
		$newdata .= " /" if $slashclose;
		$newdata .= ">";
	    }
	}
	elsif ($type eq "E") {
	    $newdata .= "</" . $token->[1] . ">";
	}
	elsif ($type eq "T" || $type eq "D") {
	    $newdata .= $token->[1];
	} 
	elsif ($type eq "C") {
	    # ignore comments
	}
	elsif ($type eq "PI") {
	    $newdata .= "<?$token->[1]>";
	}
	else {
	    $newdata .= "<!-- OTHER: " . $type . "-->\n";
	}
    } # end while
    $$data = $newdata;
}

sub load_user_theme
{
    # hashref, hashref
    my ($dbarg, $user, $u, $vars) = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
		
    my $sth;
    my $quser = $dbh->quote($user);

    if ($u->{'themeid'} == 0) {
	$sth = $dbr->prepare("SELECT coltype, color FROM themecustom WHERE user=$quser");
    } else {
	my $qtid = $dbh->quote($u->{'themeid'});
	$sth = $dbr->prepare("SELECT coltype, color FROM themedata WHERE themeid=$qtid");
    }
    $sth->execute;
    $vars->{"color-$_->{'coltype'}"} = $_->{'color'} while ($_ = $sth->fetchrow_hashref);
}

sub parse_vars
{
    my ($dataref, $hashref) = @_;
    my @data = split(/\n/, $$dataref);
    my $curitem = "";
    
    foreach (@data)
    {
        $_ .= "\n";
	s/\r//g;
        if ($curitem eq "" && /^([A-Z0-9\_]+)=>([^\n\r]*)/)
        {
	    $hashref->{$1} = $2;
        }
        elsif ($curitem eq "" && /^([A-Z0-9\_]+)<=\s*$/)
        {
	    $curitem = $1;
	    $hashref->{$curitem} = "";
        }
        elsif ($curitem && /^<=$curitem\s*$/)
        {
	    chop $hashref->{$curitem};  # remove the false newline
	    $curitem = "";
        }
        else
        {
	    $hashref->{$curitem} .= $_ if ($curitem =~ /\S/);
        }
    }
}

sub server_down_html
{
    return "<b>$LJ::SERVER_DOWN_SUBJECT</b><br />$LJ::SERVER_DOWN_MESSAGE";
}

##
## loads a style and takes into account caching (don't reload a system style
## until 60 seconds)
##
sub load_style_fast
{
    ### styleid -- numeric, primary key
    ### dataref -- pointer where to store data
    ### typeref -- optional pointer where to store style type (undef for none)
    ### nocache -- flag to say don't cache

    my ($dbarg, $styleid, $dataref, $typeref, $nocache) = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    $styleid += 0;
    my $now = time();
    
    if ((defined $LJ::CACHE_STYLE{$styleid}) &&
	($LJ::CACHE_STYLE{$styleid}->{'lastpull'} > ($now-300)) &&
	(! $nocache)
	)
    {
	$$dataref = $LJ::CACHE_STYLE{$styleid}->{'data'};
	if (ref $typeref eq "SCALAR") { $$typeref = $LJ::CACHE_STYLE{$styleid}->{'type'}; }
    }
    else
    {
	my @h = ($dbh);
	if ($dbs->{'has_slave'}) {
	    unshift @h, $dbr;
	}
	my ($data, $type, $cache);
	my $sth;
	foreach my $db (@h) 
	{
	    $sth = $dbr->prepare("SELECT formatdata, type, opt_cache FROM style WHERE styleid=$styleid");
	    $sth->execute;
	    ($data, $type, $cache) = $sth->fetchrow_array;
	    $sth->finish;
	    last if ($data);
	}
	if ($cache eq "Y") {
	    $LJ::CACHE_STYLE{$styleid} = { 'lastpull' => $now,
				       'data' => $data,
				       'type' => $type,
				   };
	}

	$$dataref = $data;
	if (ref $typeref eq "SCALAR") { $$typeref = $type; }
    }
}

# $dbarg can be either a $dbh (master) or a $dbs (db set, master & slave hashref)
sub make_journal
{
    my ($dbarg, $user, $view, $remote, $opts) = @_;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    if ($LJ::SERVER_DOWN) {
	if ($opts->{'vhost'} eq "customview") {
	    return "<!-- LJ down for maintenance -->";
	}
	return LJ::server_down_html();
    }
    
    my ($styleid);
    if ($opts->{'styleid'}) { 
	$styleid = $opts->{'styleid'}+0; 
    } else {
	$view ||= "lastn";    # default view when none specified explicitly in URLs
	if ($LJ::viewinfo{$view})  {
	    $styleid = -1;    # to get past the return, then checked later for -1 and fixed, once user is loaded.
	    $view = $view;
	} else {
	    $opts->{'badargs'} = 1;
	}
    }
    return unless ($styleid);

    my $quser = $dbh->quote($user);
    my $u;
    if ($opts->{'u'}) {
	$u = $opts->{'u'};
    } else {
	$u = LJ::load_user($dbs, $user);
    }

    unless ($u)
    {
	$opts->{'baduser'} = 1;
	return "<H1>Error</H1>No such user <B>$user</B>";
    }

    if ($styleid == -1) {
	if ($u->{"${view}_style"}) {
	    # NOTE: old schema.  only here to make transition easier.  remove later.
	    $styleid = $u->{"${view}_style"};
	} else {
	    my $prop = "s1_${view}_style";
	    unless (defined $u->{$prop}) {
	      LJ::load_user_props($dbs, $u, $prop);
	    }
	    $styleid = $u->{$prop};
	}
    }

    if ($LJ::USER_VHOSTS && $opts->{'vhost'} eq "users" && ! LJ::get_cap($u, "userdomain")) {
	return "<b>Notice</b><br />Addresses like <tt>http://<i>username</i>.$LJ::USER_DOMAIN</tt> aren't enabled for this user's account type.  Instead, visit:<ul><font face=\"Verdana,Arial\"><b><a href=\"$LJ::SITEROOT/users/$user/\">$LJ::SITEROOT/users/$user/</a></b></font></ul>";
    }
    if ($opts->{'vhost'} eq "customview" && ! LJ::get_cap($u, "userdomain")) {
	return "<b>Notice</b><br />Only users with <A HREF=\"$LJ::SITEROOT/paidaccounts/\">paid accounts</A> can create and embed styles.";
    }
    if ($opts->{'vhost'} eq "community" && $u->{'journaltype'} ne "C") {
	return "<b>Notice</b><br />This account isn't a community journal.";
    }

    return "<h1>Error</h1>Journal has been deleted.  If you are <B>$user</B>, you have a period of 30 days to decide to undelete your journal." if ($u->{'statusvis'} eq "D");
    return "<h1>Error</h1>This journal has been suspended." if ($u->{'statusvis'} eq "S");
    return "<h1>Error</h1>This journal has been deleted and purged.  This username will be available shortly." if ($u->{'statusvis'} eq "X");

    my %vars = ();
    # load the base style
    my $basevars = "";
    LJ::load_style_fast($dbs, $styleid, \$basevars, \$view)
	unless ($LJ::viewinfo{$view}->{'nostyle'});

    # load the overrides
    my $overrides = "";
    if ($opts->{'nooverride'}==0 && $u->{'useoverrides'} eq "Y")
    {
        my $sth = $dbr->prepare("SELECT override FROM overrides WHERE user=$quser");
        $sth->execute;
        ($overrides) = $sth->fetchrow_array;
	$sth->finish;
    }

    # populate the variable hash
    LJ::parse_vars(\$basevars, \%vars);
    LJ::parse_vars(\$overrides, \%vars);
    LJ::load_user_theme($dbs, $user, $u, \%vars);
    
    # kinda free some memory
    $basevars = "";
    $overrides = "";

    # instruct some function to make this specific view type
    return unless (defined $LJ::viewinfo{$view}->{'creator'});
    my $ret = "";

    # call the view creator w/ the buffer to fill and the construction variables
    &{$LJ::viewinfo{$view}->{'creator'}}($dbs, \$ret, $u, \%vars, $remote, $opts);

    # remove bad stuff
    unless ($opts->{'trusted_html'}) {
        LJ::strip_bad_code(\$ret);
    }

    # return it...
    return $ret;   
}

sub html_datetime
{
    my $opts = shift;
    my $lang = $opts->{'lang'} || "EN";
    my ($yyyy, $mm, $dd, $hh, $nn, $ss);
    my $ret;
    my $name = $opts->{'name'};
    my $disabled = $opts->{'disabled'} ? "DISABLED" : "";
    if ($opts->{'default'} =~ /^(\d\d\d\d)-(\d\d)-(\d\d)(?: (\d\d):(\d\d):(\d\d))/) {
	($yyyy, $mm, $dd, $hh, $nn, $ss) = ($1 > 0 ? $1 : "",
					    $2+0, 
					    $3 > 0 ? $3+0 : "",
					    $4 > 0 ? $4 : "", 
					    $5 > 0 ? $5 : "", 
					    $6 > 0 ? $6 : "");
    }
    $ret .= LJ::html_select({ 'name' => "${name}_mm", 'selected' => $mm, 'disabled' => $opts->{'disabled'} },
			 map { $_, LJ::Lang::month_long($lang, $_) } (0..12));
    $ret .= "<INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_dd VALUE=\"$dd\" $disabled>, <INPUT SIZE=4 MAXLENGTH=4 NAME=${name}_yyyy VALUE=\"$yyyy\" $disabled>";
    unless ($opts->{'notime'}) {
	$ret.= " <INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_hh VALUE=\"$hh\" $disabled>:<INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_nn VALUE=\"$nn\" $disabled>";
	if ($opts->{'seconds'}) {
	    $ret .= "<INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_ss VALUE=\"$ss\" $disabled>";
	}
    }

    return $ret;
}

sub html_datetime_decode
{
    my $opts = shift;
    my $hash = shift;
    my $name = $opts->{'name'};
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d", 
		   $hash->{"${name}_yyyy"},
		   $hash->{"${name}_mm"},
		   $hash->{"${name}_dd"},
		   $hash->{"${name}_hh"},
		   $hash->{"${name}_nn"},
		   $hash->{"${name}_ss"});
}

sub html_select
{
    my $opts = shift;
    my @items = @_;
    my $disabled = $opts->{'disabled'} ? " disabled='1'" : "";
    my $ret;
    $ret .= "<select";
    if ($opts->{'name'}) { $ret .= " name='$opts->{'name'}'"; }
    if ($opts->{'raw'}) { $ret .= " $opts->{'raw'}"; }
    $ret .= "$disabled>";
    while (my ($value, $text) = splice(@items, 0, 2)) {
	my $sel = "";
	if ($value eq $opts->{'selected'}) { $sel = " selected"; }
	$ret .= "<option value=\"$value\"$sel>$text</option>";
    }
    $ret .= "</select>";
    return $ret;
}

sub html_check
{
    my $opts = shift;

    my $disabled = $opts->{'disabled'} ? " DISABLED" : "";
    my $ret;
    if ($opts->{'type'} eq "radio") {
	$ret .= "<input type=\"radio\" ";
    } else {
	$ret .= "<input type=\"checkbox\" ";
    }
    if ($opts->{'selected'}) { $ret .= " checked='1'"; }
    if ($opts->{'raw'}) { $ret .= " $opts->{'raw'}"; }
    if ($opts->{'name'}) { $ret .= " name=\"$opts->{'name'}\""; }
    if (defined $opts->{'value'}) { $ret .= " value=\"$opts->{'value'}\""; }
    $ret .= "$disabled>";
    return $ret;
}

sub html_text
{
    my $opts = shift;

    my $disabled = $opts->{'disabled'} ? " DISABLED" : "";
    my $ret;
    $ret .= "<input type=\"text\"";
    if ($opts->{'size'}) { $ret .= " size=\"$opts->{'size'}\""; }
    if ($opts->{'maxlength'}) { $ret .= " maxlength=\"$opts->{'maxlength'}\""; }
    if ($opts->{'name'}) { $ret .= " name=\"" . LJ::ehtml($opts->{'name'}) . "\""; }
    if ($opts->{'value'}) { $ret .= " value=\"" . LJ::ehtml($opts->{'value'}) . "\""; }
    $ret .= "$disabled>";
    return $ret;
}

#
# returns the canonical username given, or blank if the username is not well-formed
#
sub canonical_username
{
    my $user = shift;
    if ($user =~ /^\s*([\w\-]{1,15})\s*$/) {
	$user = lc($1);
	$user =~ s/-/_/g;
	return $user;
    }
    return "";  # not a good username.
}

sub decode_url_string
{
    my $buffer = shift;   # input scalarref
    my $hashref = shift;  # output hash

    my $pair;
    my @pairs = split(/&/, $$buffer);
    my ($name, $value);
    foreach $pair (@pairs)
    {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $hashref->{$name} .= $hashref->{$name} ? "\0$value" : $value;
    }
}

# given two db roles, returns true only if the two roles are for sure
# served by different database servers.  this is useful for, say,
# the moveusercluster script:  you wouldn't want to select something
# from one db, copy it into another, and then delete it from the 
# source if they were both the same machine.
sub use_diff_db
{
    my ($role1, $role2) = @_;
    
    return 0 if $role1 eq $role2;

    # this is implied:  (makes logic below more readable by forcing it)
    $LJ::DBINFO{'master'}->{'role'}->{'master'} = 1;

    foreach (keys %LJ::DBINFO) {
	next if /^_/;
	next unless ref $LJ::DBINFO{$_} eq "HASH";
	if ($LJ::DBINFO{$_}->{'role'}->{$role1} &&
	    $LJ::DBINFO{$_}->{'role'}->{$role2}) {
	    return 0;
	}
    }

    return 1;    
}

sub get_dbh
{
    my @roles = @_;
    my $role = shift @roles;
    return undef unless $role;

    my $now = time();

    # otherwise, see if we have a role -> full DSN mapping already
    my ($fdsn, $dbh);
    if ($role eq "master") { 
	$fdsn = _get_dbh_fdsn($LJ::DBINFO{'master'});
    } else {
	if ($LJ::DBCACHE{$role}) {
	    $fdsn = $LJ::DBCACHE{$role};
	    if ($now > $LJ::DBCACHE_UNTIL{$role}) {
		# this role -> DSN mapping is too old.  invalidate,
		# and while we're at it, clean up any connections we have
		# that are too idle.
		undef $fdsn;
		my @idle;
		foreach (keys %LJ::DB_USED_AT) {
		    push @idle, $_ if ($LJ::DB_USED_AT{$_} < $now - 60);
		}
		foreach (@idle) {
		    delete $LJ::DB_USED_AT{$_};
		    delete $LJ::DBCACHE{$_};
		}
	    }
	}
    }

    if ($fdsn) {
	$dbh = _get_dbh_conn($fdsn);
	return $dbh if $dbh;
	delete $LJ::DBCACHE{$role};  # guess it was bogus
    }
    return undef if $role eq "master";  # no hope now
    
    # time to randomly weightedly select one.
    my @applicable;
    my $total_weight;
    foreach (keys %LJ::DBINFO) {
	next if /^_/;
	next unless ref $LJ::DBINFO{$_} eq "HASH";
	my $weight = $LJ::DBINFO{$_}->{'role'}->{$role};
	next unless $weight;
	push @applicable, [ $LJ::DBINFO{$_}, $weight ];
	$total_weight += $weight;
    }

    while (@applicable)
    {
	my $rand = rand($total_weight);
	my ($i, $t) = (0, 0);
	for (; $i<@applicable; $i++) {
	    $t += $applicable[$i]->[1];
	    last if $t > $rand;
	}
	my $fdsn = _get_dbh_fdsn($applicable[$i]->[0]);
	$dbh = _get_dbh_conn($fdsn);
	if ($dbh) {
	    $LJ::DBCACHE{$role} = $fdsn;
	    $LJ::DBCACHE_UNTIL{$role} = $now + 20;
	    return $dbh;
	}
       
	# otherwise, discard that one.
	$total_weight -= $applicable[$i]->[1];
	splice(@applicable, $i, 1);
    }

    # try others
    return get_dbh(@roles);
}

sub _get_dbh_fdsn
{
    my $db = shift;   # hashref with DSN info, from ljconfig.pl's %LJ::DBINFO
    my $fdsn = "DBI:mysql";  # join("|",$dsn,$user,$pass) (because no refs as hash keys)

    return $db->{'_fdsn'} if $db->{'_fdsn'};

    $db->{'dbname'} ||= "livejournal";
    $fdsn .= ":$db->{'dbname'}:";
    if ($db->{'host'}) {
	$fdsn .= "host=$db->{'host'};";
    }
    if ($db->{'sock'}) {
	$fdsn .= "mysql_socket=$db->{'sock'};";
    }
    $fdsn .= "|$db->{'user'}|$db->{'pass'}";

    $db->{'_fdsn'} = $fdsn;
    return $fdsn;
}

sub _get_dbh_conn
{
    my $fdsn = shift;
    my $now = time();

    # have we already created or verified a handle this request for this DSN?
    if ($LJ::DBREQCACHE{$fdsn}) {
	$LJ::DB_USED_AT{$fdsn} = $now;
	return $LJ::DBREQCACHE{$fdsn};
    }
    
    # check to see if we recently tried to connect to that dead server
    return undef if $now < $LJ::DBDEADUNTIL{$fdsn};

    # if not, we'll try to find one we used sometime in this process lifetime
    my $dbh = $LJ::DBCACHE{$fdsn};

    # if it exists, verify it's still alive and return it:
    if ($dbh) {
	if ($dbh->selectrow_array("SELECT CONNECTION_ID()")) {
	    $LJ::DBREQCACHE{$fdsn} = $dbh;  # validated.
	    $LJ::DB_USED_AT{$fdsn} = $now;
	    return $dbh;
	}
	undef $dbh;
	undef $LJ::DBCACHE{$fdsn};
    }
    
    # time to make one!
    my ($dsn, $user, $pass) = split(/\|/, $fdsn);
    $dbh = DBI->connect($dsn, $user, $pass, {			
	PrintError => 0,
    });

    # mark server as dead if dead.  won't try to reconnect again for 5 seconds.
    if ($dbh) {
	$LJ::DB_USED_AT{$fdsn} = $now;
    } else {
	$LJ::DB_DEAD_UNTIL{$fdsn} = $now + 5;
    }

    return $LJ::DBREQCACHE{$fdsn} = $LJ::DBCACHE{$fdsn} = $dbh;
}

# <LJFUNC>
# name: LJ::get_dbs
# des: Returns a set of database handles to master and a slave,
#      if this site is using slave databases.  Only use this
#      once per connection and pass around the same $dbs, since
#      this function calls [func[LJ::get_dbh]] which uses cached
#      connections, but validates the connection is still live.
# returns: $dbs (see [func[LJ::make_dbs]])
# </LJFUNC>
sub get_dbs
{
    my $dbh = LJ::get_dbh("master");
    my $dbr = LJ::get_dbh("slave");
    return make_dbs($dbh, $dbr);
}

sub get_cluster_reader
{
    my $arg = shift;
    my $id = ref $arg eq "HASH" ? $arg->{'clusterid'} : $arg;
    return LJ::get_dbh("cluster${id}slave",
		       "cluster${id}");
}

sub get_cluster_master
{
    my $arg = shift;
    my $id = ref $arg eq "HASH" ? $arg->{'clusterid'} : $arg;
    return LJ::get_dbh("cluster${id}");
}

# <LJFUNC>
# name: LJ::make_dbs
# des: Makes a $dbs structure from a master db
#      handle and optionally a slave.  This function
#      is called from [func[LJ::get_dbs]].  You shouldn't need
#      to call it yourself.
# returns: $dbs: hashref with 'dbh' (master), 'dbr' (slave or undef),
#          'has_slave' (boolean) and 'reader' (dbr if defined, else dbh)
# </LJFUNC>
sub make_dbs
{
    my ($dbh, $dbr) = @_;
    my $dbs = {};
    $dbs->{'dbh'} = $dbh;
    $dbs->{'dbr'} = $dbr;
    $dbs->{'has_slave'} = defined $dbr ? 1 : 0;
    $dbs->{'reader'} = defined $dbr ? $dbr : $dbh;
    return $dbs;
}

# converts a single argument to a dbs.  the argument is either a 
# dbset already, or it's a master handle, in which case we need
# to make it into a dbset with no slave.
sub make_dbs_from_arg
{
    my $dbarg = shift;
    my $dbs;
    if (ref($dbarg) eq "HASH") {
	$dbs = $dbarg;
    } else {
	$dbs = LJ::make_dbs($dbarg, undef);
    }
    return $dbs;    
}

 
## turns a date (yyyy-mm-dd) into links to year calendar, month view, and day view, given
## also a user object (hashref)
sub date_to_view_links
{
    my ($u, $date) = @_;
    
    return unless ($date =~ /(\d\d\d\d)-(\d\d)-(\d\d)/);
    my ($y, $m, $d) = ($1, $2, $3);
    my ($nm, $nd) = ($m+0, $d+0);   # numeric, without leading zeros
    my $user = $u->{'user'};

    my $ret;
    $ret .= "<a href=\"$LJ::SITEROOT/users/$user/calendar/$y\">$y</a>-";
    $ret .= "<a href=\"$LJ::SITEROOT/view/?type=month&amp;user=$user&amp;y=$y&amp;m=$nm\">$m</a>-";
    $ret .= "<a href=\"$LJ::SITEROOT/users/$user/day/$y/$m/$d\">$d</a>";
    return $ret;
}

sub item_link
{
    my ($u, $itemid) = @_;
    return "$LJ::SITEROOT/talkread.bml?itemid=$itemid";
}

sub make_graphviz_dot_file
{
    my $dbarg = shift;
    my $user = shift;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    my $quser = $dbr->quote($user);
    my $sth;
    my $ret;
 
    $sth = $dbr->prepare("SELECT u.*, UNIX_TIMESTAMP()-UNIX_TIMESTAMP(uu.timeupdate) AS 'secondsold' FROM user u, userusage uu WHERE u.userid=uu.userid AND u.user=$quser");
    $sth->execute;
    my $u = $sth->fetchrow_hashref;
    
    unless ($u) {
	return "";	
    }
    
    $ret .= "digraph G {\n";
    $ret .= "  node [URL=\"$LJ::SITEROOT/userinfo.bml?user=\\N\"]\n";
    $ret .= "  node [fontsize=10, color=lightgray, style=filled]\n";
    $ret .= "  \"$user\" [color=yellow, style=filled]\n";
    
    my @friends = ();
    $sth = $dbr->prepare("SELECT friendid FROM friends WHERE userid=$u->{'userid'} AND userid<>friendid");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	push @friends, $_->{'friendid'};
    }
    
    my $friendsin = join(", ", map { $dbh->quote($_); } ($u->{'userid'}, @friends));
    my $sql = "SELECT uu.user, uf.user AS 'friend' FROM friends f, user uu, user uf WHERE f.userid=uu.userid AND f.friendid=uf.userid AND f.userid<>f.friendid AND uu.statusvis='V' AND uf.statusvis='V' AND (f.friendid=$u->{'userid'} OR (f.userid IN ($friendsin) AND f.friendid IN ($friendsin)))";
    $sth = $dbr->prepare($sql);
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	$ret .= "  \"$_->{'user'}\"->\"$_->{'friend'}\"\n";
    }
    
    $ret .= "}\n";
    
    return $ret;
}

sub expand_embedded
{
    my $dbarg = shift;
    my $itemid = shift;
    my $remote = shift;
    my $eventref = shift;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    # TODO: This should send $dbs instead of $dbh when that function
    # is converted. In addition, when that occurs the make_dbs_from_arg
    # code above can be removed.
    LJ::Poll::show_polls($dbh, $itemid, $remote, $eventref);
}

sub make_remote
{
    my $user = shift;
    my $userid = shift;
    if ($userid && $userid =~ /^\d+$/) {
	return { 'user' => $user,
		 'userid' => $userid, };
    }
    return undef;
}

sub escapeall
{
    my $a = $_[0];

    ### escape HTML
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;

    ### and escape BML
    $a =~ s/\(=/\(&#0061;/g;
    $a =~ s/=\)/&#0061;\)/g;
    return $a;
}

# $dbarg can be either a $dbh (master) or a $dbs (db set, master & slave hashref)
sub load_user
{
    my $dbarg = shift;
    my $user = shift;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    $user = LJ::canonical_username($user);

    my $quser = $dbr->quote($user);
    my $sth = $dbr->prepare("SELECT * FROM user WHERE user=$quser");
    $sth->execute;
    my $u = $sth->fetchrow_hashref;
    $sth->finish;

    # if user doesn't exist in the LJ database, it's possible we're using
    # an external authentication source and we should create the account
    # implicitly.
    if (! $u && ref $LJ::AUTH_EXISTS eq "CODE") {
	if ($LJ::AUTH_EXISTS->($user)) {
	    if (LJ::create_account($dbh, {
		'user' => $user,
		'name' => $user,
		'password' => "",
	    }))
	    {
		# NOTE: this should pull from the master, since it was _just_
		# created and the elsif below won't catch.
		$sth = $dbh->prepare("SELECT * FROM user WHERE user=$quser");
		$sth->execute;
		$u = $sth->fetchrow_hashref;
		$sth->finish;
		return $u;		
	    } else {
		return undef;
	    }
	}
    } elsif (! $u && $dbs->{'has_slave'}) {
        # If the user still doesn't exist, and there isn't an alternate auth code
        # try grabbing it from the master.
        $sth = $dbh->prepare("SELECT * FROM user WHERE user=$quser");
        $sth->execute;
        $u = $sth->fetchrow_hashref;
        $sth->finish;
    }

    return $u;
}

sub load_userid
{
    my $dbarg = shift;
    my $userid = shift;
    return undef unless $userid;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
		
    my $quserid = $dbr->quote($userid);
    my $sth = $dbr->prepare("SELECT * FROM user WHERE userid=$quserid");
    $sth->execute;
    my $u = $sth->fetchrow_hashref;
    $sth->finish;
    return $u;
}

sub load_moods
{
    return if ($LJ::CACHED_MOODS);
    my $dbarg = shift;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    my $sth = $dbr->prepare("SELECT moodid, mood, parentmood FROM moods");
    $sth->execute;
    while (my ($id, $mood, $parent) = $sth->fetchrow_array) {
	$LJ::CACHE_MOODS{$id} = { 'name' => $mood, 'parent' => $parent };
	if ($id > $LJ::CACHED_MOOD_MAX) { $LJ::CACHED_MOOD_MAX = $id; }
    }
    $LJ::CACHED_MOODS = 1;
}

# <LJFUNC>
# name: LJ::query_buffer_add
# des: Schedules an insert/update query to be run on a certain table sometime 
#      in the near future in a batch with a lot of similar updates, or
#      immediately if the site doesn't provide query buffering.  Returns
#      nothing (no db error code) since there's the possibility it won't
#      run immediately anyway.
# args: dbarg, table, query
# des-table: Table to modify.
# des-query: Query that'll update table.  The query <b>must not</b> access
#            any table other than that one, since the update is done inside
#            an explicit table lock for performance.
# </LJFUNC>
sub query_buffer_add
{
    my ($dbarg, $table, $query) = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    if ($LJ::BUFFER_QUERIES) 
    {
	# if this is a high load site, you'll want to batch queries up and send them at once.

	my $table = $dbh->quote($table);
	my $query = $dbh->quote($query);
	$dbh->do("INSERT INTO querybuffer (qbid, tablename, instime, query) VALUES (NULL, $table, NOW(), $query)");
    }
    else 
    {
	# low load sites can skip this, and just have queries go through immediately.
	$dbh->do($query);
    }
}

sub query_buffer_flush
{
    my ($dbarg, $table) = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    return -1 unless ($table);
    return -1 if ($table =~ /[^\w]/);
    
    $dbh->do("LOCK TABLES $table WRITE, querybuffer WRITE");
    
    my $count = 0;
    my $max = 0;
    my $qtable = $dbh->quote($table);

    # We want to leave this pointed to the master to ensure we are
    # getting the most recent data!  (also, querybuffer doesn't even
    # replicate to slaves in the recommended configuration... it's
    # pointless to do so)
    my $sth = $dbh->prepare("SELECT qbid, query FROM querybuffer WHERE tablename=$qtable ORDER BY qbid");
    if ($dbh->err) { $dbh->do("UNLOCK TABLES"); die $dbh->errstr; }
    $sth->execute;
    if ($dbh->err) { $dbh->do("UNLOCK TABLES"); die $dbh->errstr; }	
    while (my ($id, $query) = $sth->fetchrow_array)
    {
	$dbh->do($query);
	$count++;
	$max = $id;
    }
    $sth->finish;
    
    $dbh->do("DELETE FROM querybuffer WHERE tablename=$qtable");
    if ($dbh->err) { $dbh->do("UNLOCK TABLES"); die $dbh->errstr; }		
    
    $dbh->do("UNLOCK TABLES");
    return $count;
}

sub journal_base
{
    my ($user, $vhost) = @_;
    if ($vhost eq "users") {
	my $he_user = $user;
	$he_user =~ s/_/-/g;
	return "http://$he_user.$LJ::USER_DOMAIN";
    } elsif ($vhost eq "tilde") {
	return "$LJ::SITEROOT/~$user";
    } elsif ($vhost eq "community") {
	return "$LJ::SITEROOT/community/$user";
    } else { 
	return "$LJ::SITEROOT/users/$user";
    }
}

# loads all of the given privs for a given user into a hashref
# inside the user record ($u->{_privs}->{$priv}->{$arg} = 1)
sub load_user_privs
{
    my $dbarg = shift;
    my $remote = shift;
    my @privs = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    return unless ($remote and @privs);

    # return if we've already loaded these privs for this user.
    @privs = map { $dbr->quote($_) } 
             grep { ! $remote->{'_privloaded'}->{$_}++ } @privs;
    
    return unless (@privs);

    my $sth = $dbr->prepare("SELECT pl.privcode, pm.arg ".
			    "FROM priv_map pm, priv_list pl ".
			    "WHERE pm.prlid=pl.prlid AND ".
			    "pl.privcode IN (" . join(',',@privs) . ") ".
			    "AND pm.userid=$remote->{'userid'}");
    $sth->execute;
    while (my ($priv, $arg) = $sth->fetchrow_array)
    {
	unless (defined $arg) { $arg = ""; }  # NULL -> ""
	$remote->{'_priv'}->{$priv}->{$arg} = 1;
    }
}

# arg is optional.  if arg not present, checks if remote has
# any privs at all of that type.
# also, $dbh can be undef, in which case privs must be pre-loaded
sub check_priv
{
    my ($dbarg, $remote, $priv, $arg) = @_;
    return 0 unless ($remote);

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    if (! $remote->{'_privloaded'}->{$priv}) {
	if ($dbr) {
	    load_user_privs($dbr, $remote, $priv);
	} else {
	    return 0;
	}
    }

    if (defined $arg) {
	return (defined $remote->{'_priv'}->{$priv} &&
		defined $remote->{'_priv'}->{$priv}->{$arg});
    } else {
	return (defined $remote->{'_priv'}->{$priv});
    }
}

# check to see if the given remote user has a certain privledge
# DEPRECATED.  should use load_user_privs + check_priv
sub remote_has_priv
{
    my $dbarg = shift;
    my $remote = shift;
    my $privcode = shift;     # required.  priv code to check for.
    my $ref = shift;  # optional, arrayref or hashref to populate

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    return 0 unless ($remote);

    ### authentication done.  time to authorize...

    my $qprivcode = $dbh->quote($privcode);
    my $sth = $dbr->prepare("SELECT pm.arg FROM priv_map pm, priv_list pl WHERE pm.prlid=pl.prlid AND pl.privcode=$qprivcode AND pm.userid=$remote->{'userid'}");
    $sth->execute;
    
    my $match = 0;
    if (ref $ref eq "ARRAY") { @$ref = (); }
    if (ref $ref eq "HASH") { %$ref = (); }
    while (my ($arg) = $sth->fetchrow_array) {
	$match++;
	if (ref $ref eq "ARRAY") { push @$ref, $arg; }
	if (ref $ref eq "HASH") { $ref->{$arg} = 1; }
    }
    return $match;
}

## get a userid from a username (returns 0 if invalid user)
sub get_userid
{
    my $dbarg = shift;
    my $user = shift;
		
    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    $user = canonical_username($user);

    my $userid;
    if ($LJ::CACHE_USERID{$user}) { return $LJ::CACHE_USERID{$user}; }

    my $quser = $dbr->quote($user);
    my $sth = $dbr->prepare("SELECT userid FROM useridmap WHERE user=$quser");
    $sth->execute;
    ($userid) = $sth->fetchrow_array;
    if ($userid) { $LJ::CACHE_USERID{$user} = $userid; }

    # implictly create an account if we're using an external
    # auth mechanism
    if (! $userid && ref $LJ::AUTH_EXISTS eq "CODE")
    {
	# TODO: eventual $dbs conversion (even though create_account will ALWAYS
	# use the master)
	$userid = LJ::create_account($dbh, { 'user' => $user,
					     'name' => $user,
					     'password' => '', });
    }

    return ($userid+0);
}

## get a username from a userid (returns undef if invalid user)
# $dbarg can be either a $dbh (master) or a $dbs (db set, master & slave hashref)
sub get_username
{
    my $dbarg = shift;
    my $userid = shift;
    my $user;
    $userid += 0;

    # Checked the cache first. 
    if ($LJ::CACHE_USERNAME{$userid}) { return $LJ::CACHE_USERNAME{$userid}; }

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbr = $dbs->{'reader'};

    my $sth = $dbr->prepare("SELECT user FROM useridmap WHERE userid=$userid");
    $sth->execute;
    $user = $sth->fetchrow_array;

    # Fall back to master if it doesn't exist.
    if (! defined($user) && $dbs->{'has_slave'}) {
        my $dbh = $dbs->{'dbh'};
        $sth = $dbh->prepare("SELECT user FROM useridmap WHERE userid=$userid");
        $sth->execute;
        $user = $sth->fetchrow_array;
    }
    if (defined($user)) { $LJ::CACHE_USERNAME{$userid} = $user; }
    return ($user);
}

sub get_itemid_near
{
    my $dbarg = shift;
    my $ownerid = shift;
    my $date = shift;
    my $after_before = shift;
		
    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    return 0 unless ($date =~ /^(\d{4})-(\d{2})-\d{2} \d{2}:\d{2}:\d{2}$/);
    my ($year, $month) = ($1, $2);

    my ($op, $inc, $func);
    if ($after_before eq "after") {
	($op, $inc, $func) = (">",  1, "MIN");
    } elsif ($after_before eq "before") {
	($op, $inc, $func) = ("<", -1, "MAX");
    } else {
	return 0;
    }

    my $qeventtime = $dbh->quote($date);

    my $item = 0;
    my $tries = 0;
    while ($item==0 && $tries<2) 
    {
	my $sql = "SELECT $func(itemid) FROM log WHERE ownerid=$ownerid AND year=$year AND month=$month AND eventtime $op $qeventtime";
	my $sth = $dbr->prepare($sql);
	$sth->execute;
	($item) = $sth->fetchrow_array;

	unless ($item) {
	    $tries++;
	    $month += $inc;
	    if ($month == 13) { $month = 1;  $year++; }
	    if ($month == 0)  { $month = 12; $year--; }
	}
    }
    return ($item+0);
}

sub get_itemid_after  { return get_itemid_near(@_, "after");  }
sub get_itemid_before { return get_itemid_near(@_, "before"); }

sub mysql_time
{
    my $time = shift;
    $time ||= time();
    my @ltime = localtime($time);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d", 
		   $ltime[5]+1900,
		   $ltime[4]+1,
		   $ltime[3],
		   $ltime[2],
		   $ltime[1],
		   $ltime[0]);
}

sub get_keyword_id
{
    my $dbarg = shift;
    my $kw = shift;
    unless ($kw =~ /\S/) { return 0; }

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
		
    my $qkw = $dbh->quote($kw);

    # Making this a $dbr could cause problems due to the insertion of
    # data based on the results of this query. Leave as a $dbh.
    my $sth = $dbh->prepare("SELECT kwid FROM keywords WHERE keyword=$qkw");
    $sth->execute;
    my ($kwid) = $sth->fetchrow_array;
    unless ($kwid) {
	$sth = $dbh->prepare("INSERT INTO keywords (kwid, keyword) VALUES (NULL, $qkw)");
	$sth->execute;
	$kwid = $dbh->{'mysql_insertid'};
    }
    return $kwid;
}

# <LJFUNC>
# name: LJ::trim
# des: Removes whitespace from left and right side of a string.
# args: string
# des-string: string to be trimmed
# returns: string trimmed
# </LJFUNC>
sub trim
{
    my $a = $_[0];
    $a =~ s/^\s+//;
    $a =~ s/\s+$//;
    return $a;	
}

# returns true if $formref->{'password'} matches cleartext password or if
# $formref->{'hpassword'} is the hash of the cleartext password
# DEPRECTED: should use LJ::auth_okay
sub valid_password
{
    my ($clearpass, $formref) = @_;
    if ($formref->{'password'} && $formref->{'password'} eq $clearpass)
    {
        return 1;
    }
    if ($formref->{'hpassword'} && lc($formref->{'hpassword'}) eq &hash_password($clearpass))
    {
        return 1;
    }
    return 0;    
}

sub delete_user
{
		# TODO: Is this function even being called?
		# It doesn't look like it does anything useful
    my $dbh = shift;
    my $user = shift;
    my $quser = $dbh->quote($user);
    my $sth;
    $sth = $dbh->prepare("SELECT user, userid FROM useridmap WHERE user=$quser");
    my $u = $sth->fetchrow_hashref;
    unless ($u) { return; }
    
    ### so many issues.     
}

sub hash_password
{
    return Digest::MD5::md5_hex($_[0]);
}

# $dbarg can be either a $dbh (master) or a $dbs (db set, master & slave hashref)
sub can_use_journal
{
    my ($dbarg, $posterid, $reqownername, $res) = @_;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    my $qreqownername = $dbh->quote($reqownername);
    my $qposterid = $posterid+0;

    ## find the journal owner's userid
    my $sth = $dbr->prepare("SELECT userid FROM useridmap WHERE user=$qreqownername");
    $sth->execute;
    my $ownerid = $sth->fetchrow_array;
    # First, fall back to the master.
    unless ($ownerid) {
        if ($dbs->{'has_slave'}) {
            $sth = $dbh->prepare("SELECT userid FROM useridmap WHERE user=$qreqownername");
            $sth->execute;
            $ownerid = $sth->fetchrow_array;
        }
        # If it still doesn't exist, it doesn't exist.
        unless ($ownerid) {
            $res->{'errmsg'} = "User \"$reqownername\" does not exist.";
            return 0;
        }
    }
    
    ## check if user has access
    $sth = $dbh->prepare("SELECT COUNT(*) AS 'count' FROM logaccess WHERE ownerid=$ownerid AND posterid=$qposterid");

    $sth->execute;
    my $row = $sth->fetchrow_hashref;
    if ($row && $row->{'count'}==1) {
	$res->{'ownerid'} = $ownerid;
	return 1;
    } else {
	$res->{'errmsg'} = "You do not have access to post to this journal.";
	return 0;
    }
}

sub load_log_props
{
    my ($dbarg, $listref, $hashref) = @_;

    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    my $itemin = join(", ", map { $_+0; } @{$listref});
    unless ($itemin) { return ; }
    unless (ref $hashref eq "HASH") { return; }
    
    my $sth = $dbr->prepare("SELECT p.itemid, l.name, p.value FROM logprop p, logproplist l WHERE p.propid=l.propid AND p.itemid IN ($itemin)");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	$hashref->{$_->{'itemid'}}->{$_->{'name'}} = $_->{'value'};
    }
}

# Note: requires caller to first call LJ::load_props($dbs, "log")
sub load_log_props2
{
    my ($db, $journalid, $listref, $hashref) = @_;

    my $jitemin = join(", ", map { $_+0; } @$listref);
    return unless $jitemin;
    return unless ref $hashref eq "HASH";
    return unless defined $LJ::CACHE_PROPID{'log'};

    my $sth = $db->prepare("SELECT jitemid, propid, value FROM logprop2 WHERE journalid=$journalid AND jitemid IN ($jitemin)");
    $sth->execute;
    while (my ($jitemid, $propid, $value) = $sth->fetchrow_array) {
	$hashref->{$jitemid}->{$LJ::CACHE_PROPID{'log'}->{$propid}->{'name'}} = $value;
    }
}

# Note: requires caller to first call LJ::load_props($dbs, "log")
sub load_log_props2multi
{
    # ids by cluster (hashref),  output hashref (keys = "$ownerid $jitemid",
    # where ownerid could be 0 for unclustered)
    my ($dbs, $idsbyc, $hashref) = @_;
    my $sth;
    return unless ref $idsbyc eq "HASH";
    return unless defined $LJ::CACHE_PROPID{'log'};

    foreach my $c (keys %$idsbyc)
    {
	if ($c) {
	    # clustered:
	    my $fattyin = join(" OR ", map {
		"(journalid=" . ($_->[0]+0) . " AND jitemid=" . ($_->[1]+0) . ")"
	    } @{$idsbyc->{$c}});
	    my $db = LJ::get_cluster_reader($c);
	    $sth = $db->prepare("SELECT journalid, jitemid, propid, value ".
				"FROM logprop2 WHERE $fattyin");
	    $sth->execute;
	    while (my ($jid, $jitemid, $propid, $value) = $sth->fetchrow_array) {
		$hashref->{"$jid $jitemid"}->{$LJ::CACHE_PROPID{'log'}->{$propid}->{'name'}} = $value;
	    }
	} else {
	    # unclustered:
	    my $dbr = $dbs->{'reader'};
	    my $in = join(",", map { $_+0 } @{$idsbyc->{'0'}});
	    $sth = $dbr->prepare("SELECT itemid, propid, value FROM logprop ".
				 "WHERE itemid IN ($in)");
	    $sth->execute;
	    while (my ($itemid, $propid, $value) = $sth->fetchrow_array) {
		$hashref->{"0 $itemid"}->{$LJ::CACHE_PROPID{'log'}->{$propid}->{'name'}} = $value;
	    }
	    
	}
    }
    foreach my $c (keys %$idsbyc)
    {
	if ($c) {
	    # clustered:
	    my $fattyin = join(" OR ", map {
		"(journalid=" . ($_->[0]+0) . " AND jitemid=" . ($_->[1]+0) . ")"
	    } @{$idsbyc->{$c}});
	    my $db = LJ::get_cluster_reader($c);
	    $sth = $db->prepare("SELECT journalid, jitemid, propid, value ".
				"FROM logprop2 WHERE $fattyin");
	    $sth->execute;
	    while (my ($jid, $jitemid, $propid, $value) = $sth->fetchrow_array) {
		$hashref->{"$jid $jitemid"}->{$LJ::CACHE_PROPID{'log'}->{$propid}->{'name'}} = $value;
	    }
	} else {
	    # unclustered:
	    my $dbr = $dbs->{'reader'};
	    my $in = join(",", map { $_+0 } @{$idsbyc->{'0'}});
	    $sth = $dbr->prepare("SELECT itemid, propid, value FROM logprop ".
				 "WHERE itemid IN ($in)");
	    $sth->execute;
	    while (my ($itemid, $propid, $value) = $sth->fetchrow_array) {
		$hashref->{"0 $itemid"}->{$LJ::CACHE_PROPID{'log'}->{$propid}->{'name'}} = $value;
	    }
	    
	}
    }
}


sub load_talk_props
{
    my ($dbarg, $listref, $hashref) = @_;
    my $itemin = join(", ", map { $_+0; } @{$listref});
    unless ($itemin) { return ; }
    unless (ref $hashref eq "HASH") { return; }
    
    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    my $sth = $dbr->prepare("SELECT tp.talkid, tpl.name, tp.value FROM talkproplist tpl, talkprop tp WHERE tp.tpropid=tpl.tpropid AND tp.talkid IN ($itemin)");
    $sth->execute;
    while (my ($id, $name, $val) = $sth->fetchrow_array) {
	$hashref->{$id}->{$name} = $val;
    }
    $sth->finish;
}

# <LJFUNC>
# name: LJ::eurl
# des: Escapes a value before it can be put in a URL.  See also [func[LJ::durl]].
# args: string
# des-string: string to be escaped
# returns: string escaped
# </LJFUNC>
sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

# <LJFUNC>
# name: LJ::durl
# des: Decodes a value that's URL-escaped.  See also [func[LJ::eurl]].
# args: string
# des-string: string to be decoded
# returns: string decoded
# </LJFUNC>
sub durl
{
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

# <LJFUNC>
# name: LJ::exml
# des: Escapes a value before it can be put in XML.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </LJFUNC>
sub exml
{
    my $a = shift;
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&apos;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}

# <LJFUNC>
# name: LJ::ehtml
# des: Escapes a value before it can be put in HTML.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </LJFUNC>
sub ehtml
{
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&\#39;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;	
}

# <LJFUNC>
# name: LJ::days_in_month
# des: Figures out the number of days in a month.
# args: month, year
# des-month: Month
# des-year: Year
# returns: Number of days in that month in that year.
# </LJFUNC>
sub days_in_month
{
    my ($month, $year) = @_;
    if ($month == 2)
    {
        if ($year % 4 == 0)
        {
	  # years divisible by 400 are leap years
	  return 29 if ($year % 400 == 0);

	  # if they're divisible by 100, they aren't.
	  return 28 if ($year % 100 == 0);

	  # otherwise, if divisible by 4, they are.
	  return 29;
        }
    }
    return ((31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[$month-1]);
}

####
### delete an itemid.  if $quick is specified, that means items are being deleted en-masse
##  and the batch deleter will take care of some of the stuff, so this doesn't have to
#
sub delete_item
{
    my ($dbarg, $ownerid, $itemid, $quick, $deleter) = @_;
    my $sth;
		
    my $dbs = make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    
    $ownerid += 0;
    $itemid += 0;

    $deleter ||= sub {
	my $table = shift;
	my $col = shift;
	my @ids = @_;
	return unless @ids;
	my $in = join(",", @ids);
	$dbh->do("DELETE FROM $table WHERE $col IN ($in)");
    };

    $deleter->("memorable", "itemid", $itemid);
    $dbh->do("UPDATE userusage SET lastitemid=0 WHERE userid=$ownerid AND lastitemid=$itemid") unless ($quick);
    foreach my $t (qw(log logtext logsubject logprop)) {
	$deleter->($t, "itemid", $itemid);
    }
    $dbh->do("DELETE FROM logsec WHERE ownerid=$ownerid AND itemid=$itemid");

    my @talkids = ();
    $sth = $dbh->prepare("SELECT talkid FROM talk WHERE nodetype='L' AND nodeid=$itemid");
    $sth->execute;
    push @talkids, $_ while ($_ = $sth->fetchrow_array);
    foreach my $t (qw(talk talktext talkprop)) {
	$deleter->($t, "talkid", @talkids);
    }
}

####
### delete a clustered log item and all its associated data
##  if $quick is specified, that means items are being deleted en-masse
#
sub delete_item2
{
    my ($dbcm, $journalid, $jitemid, $quick, $deleter) = @_;
    my $sth;
		
    $journalid += 0;
    $jitemid += 0;

    $dbcm->do("DELETE FROM log2 WHERE journalid=$journalid AND jitemid=$jitemid");

    # FIXME: TODO: make log of this deletion, do the rest of the deletions async
}

1;
