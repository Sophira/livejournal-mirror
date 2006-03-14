package LJ;
use strict;

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
    return LJ::run_hook("name_caps", $caps);
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
    return LJ::run_hook("name_caps_short", $caps);
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
    my $opts  = shift;  # { no_hook => 1/0 }
    $opts ||= {};

    my $u = ref $caps ? $caps : undef;
    if (! defined $caps) { $caps = 0; }
    elsif ($u) { $caps = $u->{'caps'}; }
    my $max = undef;

    # allow a way for admins to force-set the read-only cap
    # to lower writes on a cluster.
    if ($cname eq "readonly" && $u &&
        ($LJ::READONLY_CLUSTER{$u->{clusterid}} ||
         $LJ::READONLY_CLUSTER_ADVISORY{$u->{clusterid}} &&
         ! LJ::get_cap($u, "avoid_readonly"))) {

        # HACK for desperate moments.  in when_needed mode, see if
        # database is locky first
        my $cid = $u->{clusterid};
        if ($LJ::READONLY_CLUSTER_ADVISORY{$cid} eq "when_needed") {
            my $now = time();
            return 1 if $LJ::LOCKY_CACHE{$cid} > $now - 15;

            my $dbcm = LJ::get_cluster_master($u->{clusterid});
            return 1 unless $dbcm;
            my $sth = $dbcm->prepare("SHOW PROCESSLIST");
            $sth->execute;
            return 1 if $dbcm->err;
            my $busy = 0;
            my $too_busy = $LJ::WHEN_NEEDED_THRES || 300;
            while (my $r = $sth->fetchrow_hashref) {
                $busy++ if $r->{Command} ne "Sleep";
            }
            if ($busy > $too_busy) {
                $LJ::LOCKY_CACHE{$cid} = $now;
                return 1;
            }
        } else {
            return 1;
        }
    }

    # underage/coppa check etc
    if ($cname eq "underage" && $u &&
        ($LJ::UNDERAGE_BIT &&
         $caps & 1 << $LJ::UNDERAGE_BIT)) {
        return 1;
    }

    # is there a hook for this cap name?
    if (! $opts->{no_hook} && LJ::isu($u) && LJ::are_hooks("check_cap_$cname")) {

        # hooks require a full $u object to be run
        my $val = LJ::run_hook("check_cap_$cname", $u);
        return $val if defined $val;

        # otherwise fall back to standard means
    }

    # otherwise check via other means
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
    elsif (isu($caps)) { $caps = $caps->{'caps'}; }
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



1;
