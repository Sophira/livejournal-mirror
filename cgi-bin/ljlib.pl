#!/usr/bin/perl

use DBI;
use Digest::MD5 qw(md5_hex);

########################
# CONSTANTS
#

require "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljlang.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljpoll.pl";

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
		 );

## for use in style system's %%cons:.+%% mapping
%LJ::constant_map = ('siteroot' => $LJ::SITEROOT,
		     'sitename' => $LJ::SITENAME,
		     'img' => $LJ::IMGPREFIX,
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
	&LJ::clear_caches;
    };
} else {
    $SIG{'HUP'} = \&LJ::clear_caches;    
}

sub send_mail
{
    my $opt = shift;
    &LJ::send_mail($opt);
}

## for stupid AOL mail client, wraps a plain-text URL in an anchor tag since AOL
## incorrectly renders regular text as HTML.  fucking AOL.  die.
sub make_text_link
{
    my ($url, $email) = @_;
    if ($email =~ /\@aol.com$/i) {
	return "<A HREF=\"$url\">$url</A>";
    }
    return $url;
}

sub is_valid_authaction
{
    &connect_db();
    my ($aaid, $auth) = map { $dbh->quote($_) } @_;
    my $sth = $dbh->prepare("SELECT aaid, userid, datecreate, authcode, action, arg1 FROM authactions WHERE aaid=$aaid AND authcode=$auth");
    $sth->execute;
    return $sth->fetchrow_hashref;
}

## authenticates the user at the remote end and returns a hashref containing:
##    user, userid
## or returns undef if no logged-in remote or errors.
## optional argument is arrayref to push errors
sub get_remote
{
    my $errors = shift;
    my $cgi = shift;   # optional CGI.pm reference

    ### are they logged in?
    my $remuser = $cgi ? $cgi->cookie('ljuser') : $BMLClient::COOKIE{"ljuser"};
    return undef unless ($remuser);

    my $hpass = $cgi ? $cgi->cookie('ljhpass') : $BMLClient::COOKIE{"ljhpass"};

    ### does their login password match their login?
    return undef unless ($hpass =~ /^$remuser:(.+)/);
    my $remhpass = $1;

    &connect_db();

    ### do they exist?
    my $userid = &get_userid($remuser);
    $userid += 0;
    return undef unless ($userid);

    ### is their password correct?
    my $password;
    my $sth = $dbh->prepare("SELECT password FROM user WHERE userid=$userid");
    $sth->execute;
    ($password) = $sth->fetchrow_array;
    return undef unless (&valid_password($password, { 'hpassword' => $remhpass }));

    return { 'user' => $remuser,
	     'userid' => $userid, };
}

# this is like get_remote, but it only returns who they say they are,
# not who they really are.  so if they're faking out their cookies,
# they'll fake this out.  but this is fast.
#
sub get_remote_noauth
{
    ### are they logged in?
    my $remuser = $BMLClient::COOKIE{"ljuser"};
    return undef unless ($remuser =~ /^\w{1,15}$/);

    ### does their login password match their login?
    return undef unless ($BMLClient::COOKIE{"ljhpass"} =~ /^$remuser:(.+)/);
    return { 'user' => $remuser, };
}

sub remote_has_priv { return &LJ::remote_has_priv($dbh, @_); }

sub register_authaction
{
    &connect_db();
    my $userid = shift;  $userid += 0;
    my $action = $dbh->quote(shift);
    my $arg1 = $dbh->quote(shift);
    
    # make the authcode
    my $authcode = "";
    my $vchars = "abcdefghijklmnopqrstuvwxyz0123456789";
    srand();
    for (1..15) {
	$authcode .= substr($vchars, int(rand()*36), 1);
    }
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


sub auth_fields
{
    my $opts = shift;
    my $remote = &get_remote_noauth();
    my $ret = "";
    if (!$FORM{'altlogin'} && !$opts->{'user'} && $remote->{'user'}) {
	my $hpass;
	if ($BMLClient::COOKIE{"ljhpass"} =~ /^$remote->{'user'}:(.+)/) {
	    $hpass = $1;
	}
	my $alturl = $ENV{'REQUEST_URI'};
	$alturl .= ($alturl =~ /\?/) ? "&" : "?";
	$alturl .= "altlogin=1";

	$ret .= "<TR><TD COLSPAN=2>You are currently logged in as <B>$remote->{'user'}</B>.<BR>If this is not you, <A HREF=\"$alturl\">click here</A>.\n";
	$ret .= "<INPUT TYPE=HIDDEN NAME=user VALUE=\"$remote->{'user'}\">\n";
	$ret .= "<INPUT TYPE=HIDDEN NAME=hpassword VALUE=\"$hpass\"><BR>&nbsp;\n";
	$ret .= "</TD></TR>\n";
    } else {
	$ret .= "<TR><TD>Username:</TD><TD><INPUT TYPE=TEXT NAME=user SIZE=15 MAXLENGTH=15 VALUE=\"";
	my $user = $opts->{'user'};
	unless ($user || $ENV{'QUERY_STRING'} =~ /=/) { $user=$ENV{'QUERY_STRING'}; }
	$ret .= &BMLUtil::escapeall($user) unless ($FORM{'altlogin'});
	$ret .= "\"></TD></TR>\n";
	$ret .= "<TR><TD>Password:</TD><TD>\n";
	$ret .= "<INPUT TYPE=password NAME=password SIZE=15 MAXLENGTH=30 VALUE=\"" . &ehtml($opts->{'password'}) . "\">";
	$ret .= "</TD></TR>\n";
    }
    return $ret;
}


sub valid_password { return &LJ::valid_password(@_); }
sub hash_password { return md5_hex($_[0]); }


sub remap_event_links
{
    my ($eventref, $baseurl) = @_;
    return unless $baseurl;
    $$eventref =~ s/(<IMG\s+[^>]*SRC=)(("(.+?)")|([^\s>]+))/"$1\"" . &abs_url($2, $baseurl). '"'/ieg;
    $$eventref =~ s/(<A\s+[^>]*HREF=)(("(.+?)")|([^\s>]+))/"$1\"" . &abs_url($2, $baseurl). '"'/ieg;
}

sub abs_url
{
    use URI::URL;
    my ($uri, $base) = @_;
    $uri =~ s/^"//;
	$uri =~ s/"$//;
    return url($uri)->abs($base)->as_string;
}

sub load_user_props
{
    &connect_db();

    ## user reference
    my ($uref, @props) = @_;
    my $uid = $uref->{'userid'}+0;
    unless ($uid) {
	$uid = LJ::get_userid($dbh, $uref->{'user'});
    }
    
    my $propname_where;
    if (@props) {
	$propname_where = "AND upl.name IN (" . join(",", map { $dbh->quote($_) } @props) . ")";
    }
    
    my ($sql, $sth);

    # FIXME: right now we read userprops from both tables (indexed and lite).  we always have to do this
    #        for cases when we're loading all props, but when loading a subset, we might be able to
    #        eliminate one query or the other if we cache somewhere the userproplist and which props
    #        are in which table.  For now, though, this works:

    foreach my $table (qw(userprop userproplite))
    {
	$sql = "SELECT upl.name, up.value FROM $table up, userproplist upl WHERE up.userid=$uid AND up.upropid=upl.upropid $propname_where";
	$sth = $dbh->prepare($sql);
	$sth->execute;
	while ($_ = $sth->fetchrow_hashref) {
	    $uref->{$_->{'name'}} = $_->{'value'};
	}
	$sth->finish;
    }
}

sub set_userprop
{
    my ($dbh, $userid, $propname, $value) = @_;
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
    $value = $dbh->quote($value);

    $sth = $dbh->prepare("REPLACE INTO $table (userid, upropid, value) VALUES ($userid, $p->{'upropid'}, $value)");
    $sth->execute;
}


sub load_moods
{
    return if ($LJ::CACHED_MOODS);
    &connect_db();
    my $sth = $dbh->prepare("SELECT moodid, mood, parentmood FROM moods");
    $sth->execute;
    while (my ($id, $mood, $parent) = $sth->fetchrow_array) {
	$LJ::CACHE_MOODS{$id} = { 'name' => $mood, 'parent' => $parent };
	if ($id > $LJ::CACHED_MOOD_MAX) { $LJ::CACHED_MOOD_MAX = $id; }
    }
    $LJ::CACHED_MOODS = 1;
}

sub load_mood_theme
{
    my $themeid = shift;
    return if ($LJ::CACHE_MOOD_THEME{$themeid});

    &connect_db();
    $themeid += 0;
    my $sth = $dbh->prepare("SELECT moodid, picurl, width, height FROM moodthemedata WHERE moodthemeid=$themeid");
    $sth->execute;
    while (my ($id, $pic, $w, $h) = $sth->fetchrow_array) {
	$LJ::CACHE_MOOD_THEME{$themeid}->{$id} = { 'pic' => $pic, 'w' => $w, 'h' => $h };
    }
}

##
## returns 1 and populates %$retref if successful, else returns 0
##
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


sub server_down_html
{
    return &LJ::server_down_html();
}

sub make_journal
{
    &connect_db();
    return &LJ::make_journal($dbh, @_);
}

sub load_codes
{
    my ($req) = $_[0];
    &connect_db();
    foreach my $type (keys %{$req})
    {
	unless ($LJ::CACHE_CODES{$type})
	{
	    $LJ::CACHE_CODES{$type} = [];
	    my $qtype = $dbh->quote($type);
	    my $sth = $dbh->prepare("SELECT code, item FROM codes WHERE type=$qtype ORDER BY sortorder");
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

sub get_userid { return &LJ::get_userid($dbh, @_); }
sub get_username { return &LJ::get_username($dbh, @_); }
sub load_userpics { return &LJ::load_userpics($dbh, @_); }

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

## get the friends id
sub get_friend_itemids
{
    my $opts = shift;

    my $userid = $opts->{'userid'}+0;
    my $remoteid = $opts->{'remoteid'}+0;
    my @items = ();
    my $itemshow = $opts->{'itemshow'}+0;
    my $skip = $opts->{'skip'}+0;
    my $getitems = $itemshow+$skip;
    my $owners_ref = (ref $opts->{'owners'} eq "HASH") ? $opts->{'owners'} : {};
    my $filter = $opts->{'filter'}+0;

    # sanity check:
    $skip = 0 if ($skip < 0);

    ### what do your friends think of remote viewer?  what security level?
    my %usermask;
    if ($remoteid) 
    {
	$sth = $dbh->prepare("SELECT ff.userid, ff.groupmask FROM friends fu, friends ff WHERE fu.userid=$userid AND fu.friendid=ff.userid AND ff.friendid=$remoteid");
	$sth->execute;
	while (my ($friendid, $mask) = $sth->fetchrow_array) { 
	    $usermask{$friendid} = $mask; 
	}
    }

    my $filtersql;
    if ($filter) {
	if ($remoteid == $userid) {
	    $filtersql = "AND f.groupmask & $filter";
	}
    }

    $sth = $dbh->prepare("SELECT u.userid, u.timeupdate FROM friends f, user u WHERE f.userid=$userid AND f.friendid=u.userid $filtersql AND u.statusvis='V'");
    $sth->execute;

    my @friends = ();
    while (my ($userid, $update) = $sth->fetchrow_array) {
	push @friends, [ $userid, $update ];
    }
    @friends = sort { $b->[1] cmp $a->[1] } @friends;

    my $loop = 1;
    my $queries = 0;
    my $oldest = "";
    while ($loop)
    {
	my @ids = ();
	while (scalar(@ids) < 20 && @friends) {
	    my $f = shift @friends;
	    if ($oldest && $f->[1] lt $oldest) { last; }
	    push @ids, $f->[0];
	}
	last unless (@ids);
	my $in = join(',', @ids);
	
	my $sql;
	if ($remoteid) {
	    $sql = "SELECT l.ownerid, h.itemid, l.logtime, l.security, l.allowmask FROM hintlastnview h, log l WHERE h.userid IN ($in) AND h.itemid=l.itemid";
	} else {
	    $sql = "SELECT l.ownerid, h.itemid, l.logtime FROM hintlastnview h, log l WHERE h.userid IN ($in) AND h.itemid=l.itemid AND l.security='public'";
	}
	if ($oldest) { $sql .= " AND l.logtime > '$oldest'";  }

	# this causes MySQL to do use a temporary table and do an extra pass also (use file sort).  so, we'll do it in memory here.  yay.
	# $sql .= " ORDER BY l.logtime DESC";
	
	$sth = $dbh->prepare($sql);
	$sth->execute;

	my $rows = $sth->rows;
	if ($rows == 0) { last; }

	## see comment above.  this is our "ORDER BY l.logtime DESC".  pathetic, huh?
	my @hintrows;	
	while (my ($owner, $itemid, $logtime, $sec, $allowmask) = $sth->fetchrow_array) 
	{
	    push @hintrows, [ $owner, $itemid, $logtime, $sec, $allowmask ];
	}
	$sth->finish;
	@hintrows = sort { $b->[2] cmp $a->[2] } @hintrows;
	
	my $count;
	while (@hintrows)
	{
	    my $rec = shift @hintrows;
	    my ($owner, $itemid, $logtime, $sec, $allowmask) = @{$rec};

	    if ($sec eq "private" && $owner != $remoteid) { next; }
	    if ($sec eq "usemask" && $owner != $remoteid && ! (($usermask{$owner}+0) & ($allowmask+0))) { next; }
	    push @items, [ $itemid, $logtime, $owner ];
	    $count++;
	    if ($count >= $getitems) { last; }
	}
	@items = sort { $b->[1] cmp $a->[1] } @items;
	my $size = scalar(@items);
	if ($size < $getitems) { next; }
	@items = @items[0..($getitems-1)];
	$oldest = $items[$getitems-1]->[1] if (@items);
    }

    my $size = scalar(@items);

    my @ret;
    my $max = $skip+$itemshow;
    if ($size < $max) { $max = $size; }
    foreach my $it (@items[$skip..($max-1)]) {
	push @ret, $it->[0];
	$owners_ref->{$it->[2]} = 1;
    }
    return @ret;
}


# do all the current music/mood/weather/whatever stuff
sub prepare_currents
{
    my $args = shift;

    my %currents = ();
    my $val;
    if ($val = $args->{'props'}->{$args->{'itemid'}}->{'current_music'}) {
	$currents{'Music'} = $val;
    }
    if ($val = $args->{'props'}->{$args->{'itemid'}}->{'current_mood'}) {
	$currents{'Mood'} = $val;
    }
    if ($val = $args->{'props'}->{$args->{'itemid'}}->{'current_moodid'}) {
	my $theme = $args->{'user'}->{'moodthemeid'};
	&load_mood_theme($theme);
	my %pic;
	if (&get_mood_picture($theme, $val, \%pic)) {
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
		$fvp->{'currents'} .= &fill_var_props($args->{'vars'}, $args->{'prefix'}.'_CURRENT', {
		    'what' => $_,
		    'value' => $currents{$_},
		});
	    }
	    $args->{'event'}->{'currents'} = 
		&fill_var_props($args->{'vars'}, $args->{'prefix'}.'_CURRENTS', $fvp);
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
    


sub fill_var_props
{
    my ($vars, $key, $hashref) = @_;
    my $data = $vars->{$key};
    $data =~ s/%%(?:([\w:]+:))?(\S+?)%%/$1 ? &fvp_transform(lc($1), $vars, $hashref, $2) : $hashref->{$2}/eg;
    return $data;
}

sub fvp_transform
{
    my ($transform, $vars, $hashref, $attr) = @_;
    my $ret = $hashref->{$attr};
    while ($transform =~ s/(\w+):$//) {
	my $trans = $1;
	if ($trans eq "ue") {
	    $ret = &eurl($ret);
	}
	elsif ($trans eq "xe") {
	    $ret = &exml($ret);
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
	    $ret = $LJ::constant_map{$attr};
	}
	elsif ($trans eq "ad") {
	    $ret = "<LJAD $attr>";
	}
    }
    return $ret;
}

sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

### escape stuff so it can be used in XML attributes or elements
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

sub ehtml
{
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;	
}

# pass this a hashref, and it'll populate it.
sub get_form_data 
{
    my ($hashref) = shift;
    my $buffer = shift;

    if ($ENV{'REQUEST_METHOD'} eq 'POST') {
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

### WTF is this?
sub modify_time
{
    my $id = $_[0];
    return if ($id =~ /[^a-z0-9\-\_]/);
    return (stat("$DATADIR/bin/$id.mod"))[9];
}

sub bullet_errors
{
    my ($errorref) = @_;
    my $ret = "(=BADCONTENT=)\n<UL>\n";
    foreach (@{$errorref})
    {
	$ret .= "<LI>$_\n";
    }
    $ret .= "</UL>\n";
    return $ret;
}

sub icq_send
{
    my ($uin, $msg) = @_;
    if (length($msg) > 450) { $msg = substr($msg, 0, 447) . "..."; }
    return unless ($uin eq "489151" || $uin eq "19639663");
    my $time = time();
    my $rand = "0000";
    my $file;
    $file = "$ICQSPOOL/$time.$rand";
    while (-e $file) {
	$rand = sprintf("%04d", int(rand()*10000));
	$file = "$ICQSPOOL/$time.$rand";
    }
    open (FIL, ">$file");
    print FIL "send $uin $msg";
    close FIL;
}

sub create_password
{
    my @c = split(/ */, "bcdfghjklmnprstvwxyz");
    my @v = split(/ */, "aeiou");
    my $l = int(rand(2)) + 4;
    my $password = "";
    for(my $i = 1; $i <= $l; $i++)
    {
        $password .= "$c[int(rand(20))]$v[int(rand(5))]";
    }
    return $password;
}

sub age
{
    my ($age) = $_[0];   # seconds
    my $sec = $age; 
    my $unit;
    if ($age < 60) 
    { 
        $unit="sec"; 
    } 
    elsif ($age < 3600) 
    { 
        $age = int($age/60); 
        $unit=" min";
    } 
    elsif ($age < 3600*24)
    {
        $age = (int($age/3600)); 
        $unit="hr"; 
    } 
    else
    {
        $age = (int($age/(3600*24))); 
        $unit = "day";
    }
    if ($age != 1) 
    {
        $unit .= "s"; 
    } 
    return "$age $unit";
}

# XXX DEPRECATED
sub strip_bad_code
{
    return &LJ::strip_bad_code(@_);
}

sub self_link
{
    my $newvars = shift;
    my $link = $ENV{'REQUEST_URI'};
    $link =~ s/\?.+//;
    $link .= "?";
    foreach (keys %$newvars) {
	if (! exists $FORM{$_}) { $FORM{$_} = ""; }
    }
    foreach (sort keys %FORM) {
	if (defined $newvars->{$_} && ! $newvars->{$_}) { next; }
	my $val = $newvars->{$_} || $FORM{$_};
	next unless $val;
	$link .= &BMLUtil::eurl($_) . "=" . &BMLUtil::eurl($val) . "&";
    }
    chop $link;
    return $link;
}

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


#### UTILITY 

sub trim
{
    my $a = $_[0];
    $a =~ s/^\s+//;
    $a =~ s/\s+$//;
    return $a;	
}

sub durl
{
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

sub can_use_journal {
    &connect_db();
    return &LJ::can_use_journal($dbh, @_);
}
sub get_recent_itemids {
    &connect_db();
    return &LJ::get_recent_itemids($dbh, @_);
}
sub load_log_props {
    &connect_db();
    return &LJ::load_log_props($dbh, @_);
}
sub days_in_month {
    return &LJ::days_in_month(@_);
}

sub html_select
{
    return LJ::html_select(@_);
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
    $ret .= &html_select({ 'name' => "${name}_mm", 'selected' => $mm, 'disabled' => $opts->{'disabled'} },
			 map { $_, &LJ::Lang::month_long($lang, $_) } (0..12));
    $ret .= "<INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_dd VALUE=\"$dd\" $disabled>, <INPUT SIZE=4 MAXLENGTH=4 NAME=${name}_yyyy VALUE=\"$yyyy\" $disabled>";
    unless ($opts->{'notime'}) {
	$ret.= " <INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_hh VALUE=\"$hh\" $disabled>:<INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_nn VALUE=\"$nn\" $disabled>";
	if ($opts->{'seconds'}) {
	    $ret .= "<INPUT SIZE=2 MAXLENGTH=2 NAME=${name}_ss VALUE=\"$ss\" $disabled>";
	}
    }

    return $ret;
}

sub get_query_string
{
    my $q = $ENV{'QUERY_STRING'} || $ENV{'REDIRECT_QUERY_STRING'};
    if ($q eq "" && $ENV{'REQUEST_URI'} =~ /\?(.+)/) {
	$q = $1;
    }
    return $q;
}

# this is here only for upwards compatability.  the good function to use is
# LJ::get_dbh, which this function now calls.
sub connect_db
{
    $dbh = ($BMLPersist::dbh = LJ::get_dbh("master"));
}

sub parse_vars
{
    return &LJ::parse_vars(@_);
}

sub load_user_theme
{
    &connect_db();
    return &LJ::load_user_theme(@_);
}

package LJ;

# called from a HUP signal handler, so intentionally very very simple
# so we don't core dump on a system without reentrant libraries.
sub clear_caches
{
    $LJ::CLEAR_CACHES = 1;
}

# handle_caches
# clears caches, if the CLEAR_CACHES flag is set from an earlier HUP signal.
# always returns trues, so you can use it in a conjunction of statements
# in a while loop around the application like:
#        while (LJ::handle_caches() && FCGI::accept())
sub handle_caches
{
    return 1 unless ($LJ::CLEAR_CACHES);
    $LJ::CLEAR_CACHES = 0;

    %LJ::CACHE_STYLE = ();
    %LJ::CACHE_PROPS = ();
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

### hashref, arrayref
sub load_userpics
{
    my ($dbh, $upics, $idlist) = @_;
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
    my $sth = $dbh->prepare("SELECT picid, width, height FROM userpic WHERE picid IN ($picid_in)");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	my $id = $_->{'picid'};
	undef $_->{'picid'};	
	$upics->{$id} = $_;
	$LJ::CACHE_USERPIC_SIZE{$id}->{'width'} = $_->{'width'};
	$LJ::CACHE_USERPIC_SIZE{$id}->{'height'} = $_->{'height'};
    }
}

sub send_mail
{
    my $opt = shift;
    open (MAIL, "|$LJ::SENDMAIL");
    my $toname;
    if ($opt->{'toname'}) {
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

sub strip_bad_code
{
    my $data = shift;
    my $newdata;
    use HTML::TokeParser;
    $p = HTML::TokeParser->new($data);

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
		foreach (keys %$hash) {
		    $newdata .= " $_=\"$hash->{$_}\"";
		}
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

#sub strip_bad_code
#{
#    my $data = shift;
#    require "$ENV{'LJHOME'}/cgi-bin/cleanhtml.pl";
#    &LJ::CleanHTML::clean($data, {
#	'mode' => 'allow',
#	'keepcomments' => 1,
#    });
#}

%acct_name = ("paid" => "Paid Account",
	      "off" => "Free Account",
	      "early" => "Early Adopter",
	      "on" => "Permanent Account");

sub load_user_theme
{
    # hashref, hashref
    my ($dbh, $user, $u, $vars) = @_;
    my $sth;
    my $quser = $dbh->quote($user);

    if ($u->{'_contesttheme'}) {
	my $qnum = $dbh->quote($u->{'_contesttheme'});
	$sth = $dbh->prepare("SELECT name AS 'coltype', value AS 'color' FROM contest1data WHERE contestid=$qnum");
    } elsif ($u->{'themeid'} == 0) {
	$sth = $dbh->prepare("SELECT coltype, color FROM themecustom WHERE user=$quser");
    } else {
	my $qtid = $dbh->quote($u->{'themeid'});
	$sth = $dbh->prepare("SELECT coltype, color FROM themedata WHERE themeid=$qtid");
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
    return "<B>$LJ::SERVER_DOWN_SUBJECT</B><BR>$LJ::SERVER_DOWN_MESSAGE";
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

    my ($dbh, $styleid, $dataref, $typeref, $nocache) = @_;
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
	$sth = $dbh->prepare("SELECT formatdata, type, opt_cache FROM style WHERE styleid=$styleid");
	$sth->execute;
	my ($data, $type, $cache) = $sth->fetchrow_array;
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

sub make_journal
{
    my ($dbh, $user, $view, $remote, $opts) = @_;

    if ($LJ::SERVER_DOWN) {
	if ($opts->{'vhost'} eq "customview") {
	    return "<!-- LJ down for maintenance -->";
	}
	return &server_down_html();
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
    return "" unless ($styleid);

    my $quser = $dbh->quote($user);
    my $u;
    if ($opts->{'u'}) {
	$u = $opts->{'u'};
    } else {
	$sth = $dbh->prepare("SELECT * FROM user WHERE user=$quser");
	$sth->execute;
	$u = $sth->fetchrow_hashref;
    }

    unless ($u)
    {
	$opts->{'baduser'} = 1;
	return "<H1>Error</H1>No such user <B>$user</B>";
    }

    if ($styleid == -1) {
	$styleid = $u->{"${view}_style"};
    }

    ## temporary, for contest1 themes
    $u->{'_contesttheme'} = $opts->{'contesttheme'};

    if ($LJ::USER_VHOSTS && $opts->{'vhost'} eq "users" && $u->{'paidfeatures'} eq "off")
    {
	return "<B>Notice</B><BR>Addresses like <TT>http://<I>username</I>.$LJ::USER_DOMAIN</TT> only work for users with <A HREF=\"$LJ::SITEROOT/paidaccounts/\">paid accounts</A>.  The journal you're trying to view is available here:<UL><FONT FACE=\"Verdana,Arial\"><B><A HREF=\"$LJ::SITEROOT/users/$user/\">$LJ::SITEROOT/users/$user/</A></B></FONT></UL>";
    }
    if ($opts->{'vhost'} eq "customview" && $u->{'paidfeatures'} eq "off")
    {
	return "<B>Notice</B><BR>Only users with <A HREF=\"$LJ::SITEROOT/paidaccounts/\">paid accounts</A> can create and embed styles.";
    }
    if ($opts->{'vhost'} eq "community" && $u->{'journaltype'} ne "C") {
	return "<B>Notice</B><BR>This account isn't a community journal.";
    }

    return "<H1>Error</H1>Journal has been deleted.  If you are <B>$user</B>, you have a period of 30 days to decide to undelete your journal." if ($u->{'statusvis'} eq "D");
    return "<H1>Error</H1>This journal has been suspended." if ($u->{'statusvis'} eq "S");

    my %vars = ();
    # load the base style
    my $basevars = "";
    &load_style_fast($dbh, $styleid, \$basevars, \$view);

    # load the overrides
    my $overrides = "";
    if ($opts->{'nooverride'}==0 && $u->{'useoverrides'} eq "Y")
    {
        $sth = $dbh->prepare("SELECT override FROM overrides WHERE user=$quser");
        $sth->execute;
        ($overrides) = $sth->fetchrow_array;
    }

    # populate the variable hash
    &parse_vars(\$basevars, \%vars);
    &parse_vars(\$overrides, \%vars);
    &load_user_theme($dbh, $user, $u, \%vars);
    
    # kinda free some memory
    $basevars = "";
    $overrides = "";

    # instruct some function to make this specific view type
    return "" unless (defined $LJ::viewinfo{$view}->{'creator'});
    my $ret = "";

    # call the view creator w/ the buffer to fill and the construction variables
    &{$LJ::viewinfo{$view}->{'creator'}}(\$ret, $u, \%vars, $remote, $opts);

    # remove bad stuff
    unless ($opts->{'trusted_html'}) {
	&strip_bad_code(\$ret);
    }

    # return it...
    return $ret;   
}


sub html_select
{
    my $opts = shift;
    my @items = @_;
    my $disabled = $opts->{'disabled'} ? " DISABLED" : "";
    my $ret;
    $ret .= "<select";
    if ($opts->{'name'}) { $ret .= " name=\"$opts->{'name'}\""; }
    $ret .= "$disabled>";
    while (my ($value, $text) = splice(@items, 0, 2)) {
	my $sel = "";
	if ($value eq $opts->{'selected'}) { $sel = " selected"; }
	$ret .= "<option value=\"$value\"$sel>$text";
    }
    $ret .= "</select>";
    return $ret;
}

sub html_check
{
    my $opts = shift;

    my $disabled = $opts->{'disabled'} ? " DISABLED" : "";
    my $ret;
    $ret .= "<input type=checkbox ";
    if ($opts->{'selected'}) { $ret .= " checked"; }
    if ($opts->{'name'}) { $ret .= " name=\"$opts->{'name'}\""; }
    if ($opts->{'value'}) { $ret .= " value=\"$opts->{'value'}\""; }
    $ret .= "$disabled>";
    return $ret;
}

sub html_text
{
    my $opts = shift;

    my $disabled = $opts->{'disabled'} ? " DISABLED" : "";
    my $ret;
    $ret .= "<input type=text";
    if ($opts->{'size'}) { $ret .= " size=\"$opts->{'size'}\""; }
    if ($opts->{'maxlength'}) { $ret .= " maxlength=\"$opts->{'maxlength'}\""; }
    if ($opts->{'name'}) { $ret .= " name=\"" . &ehtml($opts->{'name'}) . "\""; }
    if ($opts->{'value'}) { $ret .= " value=\"" . &ehtml($opts->{'value'}) . "\""; }
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

# called by nearly all the other functions
sub get_dbh
{
    my $type = shift;  # 'master' or 'slave'
    my $dbh;

    ## already have a dbh of this type open?
    if (ref $LJ::DBCACHE{$type}) {
        $dbh = $LJ::DBCACHE{$type};

	# make sure connection is still good.
	my $sth = $dbh->prepare("SELECT CONNECTION_ID()");  # mysql specific
	$sth->execute;
	my ($id) = $sth->fetchrow_array;
	if ($id) { return $dbh; }
	undef $dbh;
	undef $LJ::DBCACHE{$type};
    }

    ### if we don't have a dbh cached already, which one would we try to connect to?
    my $key;
    if ($type eq "slave") {
	my $ct = $LJ::DBINFO{'slavecount'};
	if ($ct) {
	    $key = "slave" . int(rand($ct)+1);
	} else {
	    $key = "master";
	}
    } else {
	$key = "master";
    }

    $dbh = DBI->connect("DBI:mysql:livejournal:$LJ::DBINFO{$key}->{'host'}", 
			$LJ::DBINFO{$key}->{'user'},
			$LJ::DBINFO{$key}->{'pass'},
			{
			    PrintError => 0,
			});
			
    # save a reference to the database handle for later
    $LJ::DBCACHE{$type} = $dbh;

    return $dbh;
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
    $ret .= "<a href=\"$LJ::SITEROOT/view/?type=month&user=$user&y=$y&m=$nm\">$m</a>-";
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
    my $dbh = shift;
    my $user = shift;

    my $quser = $dbh->quote($user);
    my $sth;
    my $ret;
 
    $sth = $dbh->prepare("SELECT *, UNIX_TIMESTAMP()-UNIX_TIMESTAMP(timeupdate) AS 'secondsold' FROM user WHERE user=$quser");
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
    $sth = $dbh->prepare("SELECT friendid FROM friends WHERE userid=$u->{'userid'} AND userid<>friendid");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	push @friends, $_->{'friendid'};
    }
    
    my $friendsin = join(", ", map { $dbh->quote($_); } ($u->{'userid'}, @friends));
    my $sql = "SELECT uu.user, uf.user AS 'friend' FROM friends f, user uu, user uf WHERE f.userid=uu.userid AND f.friendid=uf.userid AND f.userid<>f.friendid AND uu.statusvis='V' AND uf.statusvis='V' AND (f.friendid=$u->{'userid'} OR (f.userid IN ($friendsin) AND f.friendid IN ($friendsin)))";
    $sth = $dbh->prepare($sql);
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	$ret .= "  \"$_->{'user'}\"->\"$_->{'friend'}\"\n";
	$mark{$_->{'user'}}++;
	$mark{$_->{'friend'}}++;
    }
    
    $ret .= "}\n";
    
    return $ret;
}

sub expand_embedded
{
    my $dbh = shift;
    my $itemid = shift;
    my $remote = shift;
    my $eventref = shift;

    &LJ::Poll::show_polls($dbh, $itemid, $remote, $eventref);
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

sub load_user
{
    my $dbh = shift;
    my $user = shift;
    my $quser = $dbh->quote($user);
    my $sth = $dbh->prepare("SELECT * FROM user WHERE user=$quser");
    $sth->execute;
    my $u = $sth->fetchrow_hashref;
    $sth->finish;
    return $u;
}

sub load_moods
{
    return if ($LJ::CACHED_MOODS);
    my $dbh = shift;
    my $sth = $dbh->prepare("SELECT moodid, mood, parentmood FROM moods");
    $sth->execute;
    while (my ($id, $mood, $parent) = $sth->fetchrow_array) {
	$LJ::CACHE_MOODS{$id} = { 'name' => $mood, 'parent' => $parent };
	if ($id > $LJ::CACHED_MOOD_MAX) { $LJ::CACHED_MOOD_MAX = $id; }
    }
    $LJ::CACHED_MOODS = 1;
}

sub query_buffer_add
{
    my ($dbh, $table, $query) = @_;
    
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
    my ($dbh, $table) = @_;
    return -1 unless ($table);
    return -1 if ($table =~ /[^\w]/);
    
    $dbh->do("LOCK TABLES $table WRITE, querybuffer WRITE");
    
    my $count = 0;
    my $max = 0;
    my $qtable = $dbh->quote($table);
    $sth = $dbh->prepare("SELECT qbid, query FROM querybuffer WHERE tablename=$qtable ORDER BY qbid");
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

# check to see if the given remote user has a certain privledge
sub remote_has_priv
{
    my $dbh = shift;
    my $remote = shift;
    my $privcode = shift;     # required.  priv code to check for.
    my $ref = shift;  # optional, arrayref or hashref to populate

    return 0 unless ($remote);

    ### authentication done.  time to authorize...

    my $qprivcode = $dbh->quote($privcode);
    my $sth = $dbh->prepare("SELECT pm.arg FROM priv_map pm, priv_list pl WHERE pm.prlid=pl.prlid AND pl.privcode=$qprivcode AND pm.userid=$remote->{'userid'}");
    $sth->execute;
    
    my $match = 0;
    if (ref $ref eq "ARRAY") { @$ref = (); }
    if (ref $ref eq "HASH") { %$ref = (); }
    while ($_ = $sth->fetchrow_hashref) {
	$match++;
	if (ref $ref eq "ARRAY") { push @$ref, $_->{'arg'}; }
	if (ref $ref eq "HASH") { $ref->{$_->{'arg'}} = 1; }
    }
    return $match;
}

## get a userid from a username (returns 0 if invalid user)
sub get_userid
{
    my $dbh = shift;
    my $user = shift;
    my $userid;
    if ($CACHE_USERID{$user}) { return $CACHE_USERID{$user}; }

    my $quser = $dbh->quote($user);
    my $sth = $dbh->prepare("SELECT userid FROM user WHERE user=$quser");
    $sth->execute;
    ($userid) = $sth->fetchrow_array;
    if ($userid) { $CACHE_USERID{$user} = $userid; }
    return ($userid+0);
}

## get a username from a userid (returns undef if invalid user)
sub get_username
{
    my $dbh = shift;
    my $userid = shift;
    my $user;
    $userid += 0;
    if ($CACHE_USERNAME{$userid}) { return $CACHE_USERNAME{$userid}; }
    
    my $sth = $dbh->prepare("SELECT user FROM user WHERE userid=$userid");
    $sth->execute;
    ($user) = $sth->fetchrow_array;
    if ($user) { $CACHE_USERNAME{$userid} = $user; }
    return ($user);
}

sub get_itemid_near
{
    my $dbh = shift;
    my $ownerid = shift;
    my $date = shift;
    my $after_before = shift;
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
	my $sth = $dbh->prepare($sql);
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
    my $dbh = shift;
    my $kw = shift;
    unless ($kw =~ /\S/) { return 0; }
    my $qkw = $dbh->quote($kw);

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

sub trim
{
    my $a = $_[0];
    $a =~ s/^\s+//;
    $a =~ s/\s+$//;
    return $a;	
}

# returns true if $formref->{'password'} matches cleartext password or if
# $formref->{'hpassword'} is the hash of the cleartext password
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
    my $dbh = shift;
    my $user = shift;
    my $quser = $dbh->quote($user);
    my $sth;
    $sth = $dbh->prepare("SELECT user, userid FROM user WHERE user=$quser");
    my $u = $sth->fetchrow_hashref;
    unless ($u) { return; }
    
    ### so many issues.     
}

sub hash_password
{
    return Digest::MD5::md5_hex($_[0]);
}

sub can_use_journal
{
    my ($dbh, $posterid, $reqownername, $res) = @_;
    my $qreqownername = $dbh->quote($reqownername);
    my $qposterid = $posterid+0;

    ## find the journal owner's userid
    my $sth = $dbh->prepare("SELECT userid FROM user WHERE user=$qreqownername");
    $sth->execute;
    my ($ownerid) = $sth->fetchrow_array;
    unless ($ownerid) {
	$res->{'errmsg'} = "User \"$reqownername\" does not exist.";
	return 0;
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

## internal function to most efficiently retrieve the last 'n' items
## for either the lastn or friends view
sub get_recent_itemids
{
    my $dbh = shift;
    my ($opts) = shift;

    my @itemids = ();
    my $userid = $opts->{'userid'}+0;
    my $view = $opts->{'view'};
    my $remid = $opts->{'remoteid'}+0;

    my $max_hints = 0;
    my $sort_key = "eventtime";
    if ($view eq "lastn") { $max_hints = $LJ::MAX_HINTS_LASTN; }
    if ($view eq "friends") { 
	$max_hints = $LJ::MAX_HINTS_FRIENDS; 
	$sort_key = "logtime";
    }
    unless ($max_hints) { return @itemids; }

    my $skip = $opts->{'skip'}+0;
    my $itemshow = $opts->{'itemshow'}+0;
    if ($itemshow > $max_hints) { $itemshow = $max_hints; }
    my $maxskip = $max_hints - $itemshow;
    if ($skip < 0) { $skip = 0; }
    if ($skip > $maxskip) { $skip = $maxskip; }
    my $itemload = $itemshow+$skip;
    
    ### get all the known hints, right off the bat.

    $sth = $dbh->prepare("SELECT hintid, itemid FROM hint${view}view WHERE userid=$userid");
    $sth->execute;
    my %iteminf;
    my $numhints = 0;
    while ($_ = $sth->fetchrow_arrayref) {
	$numhints++;
	$iteminf{$_->[1]} = { 'hintid' => $_->[0] };
    }
    if ($numhints > $max_hints * 4) {
	my @extra = sort { $b->{'hintid'} <=> $a->{'hintid'} } values %iteminf;
	my $minextra = $extra[$max_hints]->{'hintid'};
	$dbh->do("DELETE FROM hint${view}view WHERE userid=$userid AND hintid<=$minextra");
	foreach my $itemid (keys %iteminf) {
	    if ($iteminf{$itemid}->{'hintid'} <= $minextra) {
		delete $iteminf{$itemid};
	    }
	}
	
    }

    if (%iteminf) 
    {
	my %gmask_from;  # group mask of remote user from context of userid in key
	my $itemid_in = join(",", keys %iteminf);

	if ($remid) {
	    if ($view eq "lastn")
	    {
		## then we need to load the group mask for this friend
		$sth = $dbh->prepare("SELECT groupmask FROM friends WHERE userid=$userid AND friendid=$remid");
		$sth->execute;
		my ($mask) = $sth->fetchrow_array;
		$gmask_from{$userid} = $mask;
	    }
	}

	$sth = $dbh->prepare("SELECT itemid, security, allowmask, $sort_key FROM log WHERE itemid IN ($itemid_in)");
	$sth->execute;
	while (my $li = $sth->fetchrow_hashref) 
	{
	    my $this_ownerid = $li->{'ownerid'} || $userid;
	    
	    if ($li->{'security'} eq "public" ||
		($li->{'security'} eq "usemask" && 
		 (($li->{'allowmask'} + 0) & $gmask_from{$this_ownerid})) ||
		($remid && $this_ownerid == $remid))
	    {
		push @itemids, { 'hintid' => $iteminf{$li->{'itemid'}}->{'hintid'},
				 'itemid' => $li->{'itemid'},
				 'ownerid' => $this_ownerid,
				 $sort_key => $li->{$sort_key}, 
			     };
	    }
	}
    }
    
    %iteminf = ();  # free some memory (like perl would care!)

    @itemids = sort { $b->{$sort_key} cmp $a->{$sort_key} } @itemids;
    
    my $hintcount = scalar(@itemids);

    if ($hintcount >= $itemload) 
    {
	# we can delete some items from the hints table.
	if ($hintcount > $max_hints) {
	    my @remove = splice (@itemids, $max_hints, ($hintcount-$max_hints));
	    $hintcount = scalar(@itemids);
	    if (@remove) {
		my $sql = "REPLACE INTO batchdelete (what, itsid) VALUES ";
		$sql .= join(",", map { "('hint${view}', $_->{'hintid'})" } @remove);
		$dbh->do($sql);

		# my $removein = join(",", map { $_->{'hintid'} } @remove);
		# $dbh->do("DELETE FROM hint${view}view WHERE hintid IN ($removein)");
	    }
	}
    } 
    elsif (! $opts->{'dont_add_hints'})
    {
	## this hints table was too small.  populate it again.

	#print "Not enough in hint table!  hintcount ($hintcount) < itemload ($itemload)\n";

	if ($view eq "lastn")
        {
	    my $sql = "
REPLACE INTO hintlastnview (hintid, userid, itemid)
SELECT NULL, $userid, l.itemid
FROM log l
WHERE l.ownerid=$userid
ORDER BY l.eventtime DESC, l.logtime DESC
LIMIT $max_hints
";

	    # FUCK IT!  This kills MySQL!  Maybe later.
	    # $dbh->do($sql);
	}

	## call ourselves recursively, now that we've populated the hints table
	## however, we set this flag so we don't recurse again.  this may be true
	## for new journals that don't yet have $max_hints entries in them

	$opts->{'dont_add_hints'} = 1;
	return &get_recent_itemids($dbh, $opts);
    }

    ### remove the ones we're skipping
    if ($skip) {
	splice (@itemids, 0, $skip);
    }
    if (@itemids > $itemshow) {
	splice (@itemids, $itemshow, (scalar(@itemids)-$itemshow));
    }

    ## change the list of hashrefs to a list of integers (don't need other info now)
    if (ref $opts->{'owners'} eq "HASH") {
	grep { $opts->{'owners'}->{$_->{'ownerid'}}++ } @itemids;
    }

    @itemids = map { $_->{'itemid'} } @itemids;
    return @itemids;
}

sub load_log_props
{
    my ($dbh, $listref, $hashref) = @_;
    my $itemin = join(", ", map { $_+0; } @{$listref});
    unless ($itemin) { return ; }
    unless (ref $hashref eq "HASH") { return; }
    
    my $sth = $dbh->prepare("SELECT p.itemid, l.name, p.value FROM logprop p, logproplist l WHERE p.propid=l.propid AND p.itemid IN ($itemin)");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	$hashref->{$_->{'itemid'}}->{$_->{'name'}} = $_->{'value'};
    }
    $sth->finish;
}

sub load_talk_props
{
    my ($dbh, $listref, $hashref) = @_;
    my $itemin = join(", ", map { $_+0; } @{$listref});
    unless ($itemin) { return ; }
    unless (ref $hashref eq "HASH") { return; }
    
    my $sth = $dbh->prepare("SELECT tp.talkid, tpl.name, tp.value FROM talkproplist tpl, talkprop tp WHERE tp.tpropid=tpl.tpropid AND tp.talkid IN ($itemin)");
    $sth->execute;
    while (my ($id, $name, $val) = $sth->fetchrow_array) {
	$hashref->{$id}->{$name} = $val;
    }
    $sth->finish;
}


sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

### escape stuff so it can be used in XML attributes or elements
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

sub ehtml
{
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;	
}

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

sub populate_web_menu {
    my ($res, $menu, $numref) = @_;
    my $mn = $$numref;  # menu number
    my $mi = 0;         # menu item
    foreach my $it (@$menu) {
	$mi++;
	$res->{"menu_${mn}_${mi}_text"} = $it->{'text'};
	if ($it->{'text'} eq "-") { next; }
	if ($it->{'sub'}) { 
	    $$numref++; 
	    $res->{"menu_${mn}_${mi}_sub"} = $$numref;
	    &populate_web_menu($res, $it->{'sub'}, $numref); 
	    next;
	    
	}
	$res->{"menu_${mn}_${mi}_url"} = $it->{'url'};
    }
    $res->{"menu_${mn}_count"} = $mi;
}


####
### delete an itemid.  if $quick is specified, that means items are being deleted en-masse
##  and the batch deleter will take care of some of the stuff, so this doesn't have to
#
sub delete_item
{
    my ($dbh, $ownerid, $itemid, $quick) = @_;
    my $sth;
    $ownerid += 0;
    $itemid += 0;

    $dbh->do("DELETE FROM hintlastnview WHERE itemid=$itemid") unless ($quick);
    $dbh->do("DELETE FROM memorable WHERE itemid=$itemid");
    $dbh->do("UPDATE user SET lastitemid=0 WHERE userid=$ownerid AND lastitemid=$itemid") unless ($quick);
    $dbh->do("DELETE FROM log WHERE itemid=$itemid");
    $dbh->do("DELETE FROM logtext WHERE itemid=$itemid");
    $dbh->do("DELETE FROM logsubject WHERE itemid=$itemid");
    $dbh->do("DELETE FROM logprop WHERE itemid=$itemid");
    $dbh->do("DELETE FROM logsec WHERE ownerid=$ownerid AND itemid=$itemid");

    my @talkids = ();
    $sth = $dbh->prepare("SELECT talkid FROM talk WHERE nodetype='L' AND nodeid=$itemid");
    $sth->execute;
    while (my ($tid) = $sth->fetchrow_array) {
	push @talkids, $tid;
    }
    if (@talkids) {
	my $in = join(",", @talkids);
	$dbh->do("DELETE FROM talk WHERE talkid IN ($in)");
	$dbh->do("DELETE FROM talktext WHERE talkid IN ($in)");
	$dbh->do("DELETE FROM talkprop WHERE talkid IN ($in)");
    }
    
}

1;
