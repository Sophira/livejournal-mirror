#!/usr/bin/perl
#

package FB::PP;

use strict;

# we require the LJ nav library. this is a terrible ugly hack and should be fixed when
# there is a better repository linking method. for now we're going to assume that fb
# is installed as a subdirectory under lj.
# -revmischa
if (-e "$ENV{LJHOME}/cgi-bin/LJ/Nav.pm") {
    require "$ENV{LJHOME}/cgi-bin/LJ/Nav.pm";
} else {
    die "Cannot find module cgi-bin/LJ/Nav.pm in LiveJournal install.";
}

# diskusage population paths:
#
# LJcom auth module:
# 1) FB::PP::get_paid_quota returns (0,0)
# 2) insert upic usage/0 into diskusage
# 3) call quota_pull which updates diskusage with correct Kibtotal
#
# LJBrand auth module:
# 1) FB::PP::get_paid_quota returns (quota, exptime)
# 2) insert upic usage/quota into diskusage
# 3) call quota_pull which updates diskusage with correct Kibexternal
#
sub populate_diskusage
{
    my $u = shift;

    my $authmod = FB::current_domain_plugin();

    # get the real quota, from the database
    # -- this number will be real if LJBrand, 0 for LJcom
    my $kquota = 0;
    if ($authmod && $authmod->{type} eq 'LJBrand') {
        $kquota = (FB::PP::get_paid_quota($u))[0]+0 * (1 << 10); # mb -> kb
    }

    my $bytes = FB::user_upic_bytes($u);
    # count total size of upics
    my $kused = int($bytes / (1 << 10)); # bytes => kb

    $u->do("REPLACE INTO diskusage (userid, Kibused, Kibtotal) VALUES (?,?,?)",
           $u->{'userid'}, $kused, $kquota);

    # now update external based on auth module
    # - this has to happen after the replace above since it does an update
    my $kexternal = 0;
    if ($authmod) {
        if ($authmod->{type} eq 'LJBrand') {
            # kquota was already pulled above, we want to respect that
            # rather than overwriting with what lj tells us
            $kexternal = ($authmod->quota_pull($u))[1]+0;
        } else {
            ($kquota, $kexternal) = $authmod->quota_pull($u);
        }
    }

    return ($kused, $kquota, $kexternal);
}

sub clear_diskusage
{
    my $u = shift;
    return undef unless $u;

    return $u->do("DELETE FROM diskusage WHERE userid=?", $u->{userid});
}

sub set_paid_quota
{
    my ($u, $size, $exptime) = @_;
    return undef unless $u && $size > 0 && $exptime > 0;
    $exptime += 0;

    # check the current auth module.  if it's not 'LJBrand', then
    # we don't deal with itemexp/paylog, so just return undef,
    # signifying error
    my $authmod = FB::current_domain_plugin();
    return undef unless $authmod->{type} eq 'LJBrand';

    # see what currently exists in itemexp
    my $dbh = FB::get_db_writer();
    my ($oldsize, $oldexptime, $oldexpdays, $nowdays, $expdays)
        = $dbh->selectrow_array("SELECT size, exptime, " .
                                "TO_DAYS(FROM_UNIXTIME(exptime)) AS 'oldexpdays', " .
                                "TO_DAYS(NOW()) as 'nowdays', " .
                                "TO_DAYS(FROM_UNIXTIME($exptime)) as 'expdays' " .
                                "FROM itemexp WHERE userid=? AND item='diskquota'",
                                undef, $u->{userid});
    return undef if $dbh->err;

    # update user's actual quota limits in itemexp
    $dbh->do("REPLACE INTO itemexp (userid, item, size, exptime) VALUES (?, ?, ?, ?)",
             undef, $u->{userid}, 'diskquota', $size, $exptime);
    return undef if $dbh->err;

    # we also need to clear their disk quota/usage cache (in diskusage table) to force
    # a population of it next time disk_used_total is called from web-land.
    # this will cause their new (possibly different) total quota limit to become effective
    FB::PP::clear_diskusage($u);

    # we know the above exptime to be in the future from checks done by our XMLRPC caller,
    # so we can just mark the user as no longer degraded at this point
    $u->set_prop('deg_start', undef);

    # now see what we need to log in paylog so we can charge them later
    if ($oldsize != $size || $oldexptime != $exptime) {

        # if query above failed, don't have previous days, so size and days
        # are just what is currently being set
        my $daysval = "TO_DAYS(FROM_UNIXTIME($exptime))-TO_DAYS(NOW())";
        my $sizeval = $size;

        # otherwise, need to calculate credits based on old values
        if ($oldsize) {

            # upgrade or extension, calculate credit if needed
            if ($size >= $oldsize) {
                $daysval = ($size * ($expdays - $nowdays)) - ($oldsize * ($oldexpdays - $nowdays));
                $daysval = int($daysval / $size);

            # downgrades are okay, but we only provide credit until the current expiration time,
            # there's no calculation of box areas so users can extend their time, etc.
            # EG: 100x6 -> 75x6 == free
            #     100x6 -> 75x7 == 75x1 charged
            } else {
                $daysval = $expdays - $oldexpdays;
                $daysval = 0 if $daysval < 0;

                # insert a 0-length box if necessary to show a downgrade took place
            }
        }

        # calculate values to insert into paylog
        $dbh->do("INSERT INTO paylog (dmid, userid, time, size, days) " .
                 "VALUES (?, ?, UNIX_TIMESTAMP(), $sizeval, $daysval)",
                 undef, $u->{domainid}, $u->{userid});

        return undef if $dbh->err;
    }

    return 1;
}

sub get_paid_quota
{
    my ($u) = @_;
    return undef unless $u;

    # check the current auth module.  if it's not 'LJBrand', then
    # we don't deal with itemexp/paylog, so just return 0,0 for
    # the user's paid quota and expiration
    my $authmod = FB::current_domain_plugin();
    return (0,0) unless $authmod && $authmod->{type} eq 'LJBrand';

    my $dbh = FB::get_db_writer();
    my ($size, $exptime) =
        $dbh->selectrow_array("SELECT size, exptime FROM itemexp " .
                              "WHERE userid=? AND item='diskquota' " .
                              "AND exptime>UNIX_TIMESTAMP()",
                              undef, $u->{userid});

    return ($size+0, $exptime+0);
}

sub get_deg_level
{
    my $u = shift;
    return undef unless $u;

    # d0
    # - full access
    my $degstart = $u->prop('deg_start');
    return 0 unless $degstart;

    my $now = time();

    # d3: older than 10 days
    # - no uploads
    # - no gallery
    # - management access
    # - limited pic size
    return 3 if $now - $degstart >= 86400*10;

    # d2: older than 3 days
    # - private access to gallery
    # - no uploads
    # - full management access
    return 2 if $now - $degstart >= 86400*3;

    # d1: less than 3 days
    # - full read access, no uploads
    return 1;
}

# name: FB::PP::ljuser
# des: Make link to userinfo/journal of LiveJournal user.
# info: Returns the HTML for a LJ userinfo/journal link pair for a given user
#       name, just like LJUSER does in BML.
# args: uuser, opts?
# des-uuser: Username to link to, or user hashref.
# des-opts: Optional hashref to control output.  Key 'full' when true causes
#           a link to the mode=full userinfo. Key 'del', when true, makes a
#            tag for a deleted user.  If user parameter is a hashref, its
#            'statusvis' overrides 'del'.
# returns: HTML with a little head image & bold text link.
sub ljuser
{
    my $user = shift;
    my $opts = shift;

    if (ref $user) {
        $opts->{'del'} = $user->{'statusvis'} ne 'V';
        $user = $user->{'user'};
    }
    my $andfull = $opts->{'full'} ? "&amp;mode=full" : "";
    my $img = $opts->{'imgroot'} || '/img';
    my $strike = $opts->{'del'} ? ' text-decoration: line-through;' : '';

    my $authmod = FB::current_domain_plugin();
    my ($user_root, $icon);
    my $profile_url = $authmod->profile_url($user);
    if ($opts->{'fbuser'}) {
        $user_root = $authmod->site_root() . "/$user/";
        $icon      = "$img/fb-userinfo.gif";
    } else {
        $user_root = $authmod->journal_base($user);
        $icon      = "$img/userinfo.gif";
    }

    return "<span class='ljuser' style='white-space: nowrap;$strike'><a href='$profile_url$andfull'><img src='$icon' alt='[info]' width='17' height='17' style='vertical-align: bottom; border: 0;' /></a><a href='$user_root'><b>$user</b></a></span>";

}

FB::register_hook("disk_remaining", \&hook_disk_remaining);
sub hook_disk_remaining
{
    my $u = shift;
    my ($used, $quota, $external) = disk_used_total($u);
    return $quota - ($used + $external);
}

sub disk_used_total
{
    my $u = shift;
    my $udbh = FB::get_user_db_writer($u);
    return 0 unless $u;

    # first see what we have in the database
    my ($quota, $used, $external) = $udbh->selectrow_array(qq{
        SELECT Kibtotal, Kibused, Kibexternal FROM diskusage
            WHERE userid=?
        }, undef, $u->{'userid'});

    # if didn't get a row above, need to populate diskusage with fresh data,
    # but if there's a db error, don't treat that as no row existing
    unless (defined $quota && ! $udbh->err) {
        ($used, $quota, $external) = populate_diskusage($u);
    }

    # should have something by now
    return ($used+0, $quota+0, $external+0);
}

FB::register_hook("disk_usage_info", \&hook_disk_usage_info);
sub hook_disk_usage_info
{
    my $u = shift or return undef;

    my ($used, $quota, $external) = FB::PP::disk_used_total($u);

    # numbers returned in kilobytes
    return {
        used     => $used,
        quota    => $quota,
        external => $external,
        free     => $quota - ($used + $external),
    };

}

FB::register_hook("free_disk", \&hook_free_disk);
sub hook_free_disk { return hook_use_disk($_[0], 0-$_[1]); }

FB::register_hook("use_disk", \&hook_use_disk);
sub hook_use_disk
{
    my ($u, $bytes) = @_;
    return 0 unless $u;
    return 1 unless $bytes;

    my $op = "+";
    if ($bytes < 0) { $bytes = -$bytes; $op = "-"; }

    # in the database we store in terms of kib.  but to avoid disk
    # space attacks with files under 1 kib, round up in the tiny
    # file case.
    my $Kib = ($bytes / (1 << 10)) || 1;

    my $udbh = FB::get_user_db_writer($u);
    my $dec = sub {
        return $udbh->do("UPDATE diskusage SET Kibused=Kibused${op}? WHERE userid=?",
                         undef, $Kib, $u->{'userid'});
    };

    return 1 if $dec->();

    # if there was an error when $dec was called above, then we don't want to proceed
    # and repopulate disk usage, which could cause their quota to be overwritten
    return undef if $udbh->err;

    # local picpix user, initial population of disk usage
    populate_diskusage($u);
    return 1 if $dec->();
    return undef;
}

FB::register_hook("XMLRPC_dispatch", sub { return undef });

###############################################################################
# non-quota related local functions
#

FB::register_hook("alter_stock_sidebar", sub {
    my $list = shift;
    foreach (@$list) {
        next unless $_->[0] eq "/manage/";
        push @$_, [ '/manage/accountstatus' => 'Account Status' ];
        return;
    }
});

FB::register_hook("trans_bml_overrides", sub {
    my ($r, $or) = @_;
    return if $r->uri =~ m!^/doc/protocol!;

    my $dmid = FB::current_domain_id();
    return unless $dmid;
    my $authmod = FB::domain_plugin($dmid);
    if ($authmod->{type} eq 'LJcom') {
        $or->{'DefaultScheme'}   = "horizon";
        $or->{'DefaultLanguage'} = "en_LJ";
        $or->{'TryAltExtension'} = "lj";
    } else { # LJBrand, LiveJournal
        $or->{'DefaultScheme'} = $authmod->{config}->{scheme}      || 'horizon';
        $or->{'DefaultLanguage'} = $authmod->{config}->{language}  || 'en';
        $or->{'TryAltExtension'} = $authmod->{config}->{extension} || undef;
    }
});

FB::register_hook('picsave_submit', sub {
    my $post = shift;

    # this should only be called when the user's browser doesn't support javascript
    # and ends up here, so we usurp them and bounce them along
    if ($post->{'action:postpics'}) {
        # good, let's handle it
        my $picids = join(':', map { $_+0 } grep { $post->{"pic_check_$_"} } split(':', $post->{upicids}));
        BML::redirect("/manage/postpics?gallid=" . ($post->{gallid}+0) . "&upicids=$picids");
        return 1;
    }
    return undef;
});

FB::register_hook('trans_using_handlers', sub {
    my $handlers = {
        'getgals'    => 'manage/tolj_pickgal',
        'getgalpics' => 'manage/tolj_galpics',
        'getgalsrte'    => 'manage/tolj_pickgalrte',
        'getgalpicsrte' => 'manage/tolj_galpicsrte',
    };

    return $handlers;
});

FB::register_hook('extra_js', sub {
    my $out;
    my $siteroot = FB::siteroot();
    if ( $FB::USE_HITBOX ) {
        $out = <<EOJ;
<!--WEBSIDESTORY CODE HBX1.0 (Universal)-->
<!--COPYRIGHT 1997-2004 WEBSIDESTORY,INC. ALL RIGHTS RESERVED. U.S.PATENT No. 6,393,479B1. MORE INFO:http://websidestory.com/privacy-->
<script type="text/javascript">
var _hbEC=0,_hbE=new Array;function _hbEvent(a,b){b=_hbE[_hbEC++]=new Object();b._N=a;b._C=0;return b;}
var hbx=_hbEvent("pv");
EOJ
        $out .= "$_=\"$FB::HITBOX_VARS{$_}\";\n" foreach keys %FB::HITBOX_VARS;
        $out .= <<EOJ;
</script>
<script type="text/javascript" defer="defer" src="$siteroot/js/hbx.js"></script>
<!--END WEBSIDESTORY CODE-->
EOJ
    }
    return $out;
});


1;
