#!/usr/bin/perl

package FB::SecGroup;

use strict;

BEGIN {
    use fields qw(u secid grpname members
                  _loaded_secgroup
                  _loaded_secmembers );

    use Carp qw(croak);

    use FB::Singleton;
}


# hashref innards:
#    u                   -- FB::User, always
#    secid               -- SecGroup ID, always
#    _loaded_secgroup    -- 0 until secgroup row is loaded
#    _loaded_secmembers  -- 0 until secmembers arrayref is loaded
#
# once _loaded_secgroup:
#    grpname             -- SecGroup name from db
#
# once _loaded_secmembers:
#    secmembers          -- [ SecMember1, SecMember2, ... ]

#

# instantiate a singleton object for this singleton domain
my $single = FB::Singleton->new('SecGroup');

###############################################################################
# Constructors
#

sub new {
    my $class = shift;

    my $uuid  = shift;
    my $secid = int(shift);
    return FB::error("invalid secid")
        unless $secid > 0 && $secid < 251;

    # grpname can optionally be passed if the
    # caller has it around
    my $grpname = undef;
    if (@_) {
        $grpname = shift;
        return error("utf8")
            unless FB::is_utf8(\$grpname);
    }

    croak "bogus extra args" if @_;

    # does a singleton already exist for this object?
    my $userid     = _userid_from_uuid($uuid);
    my $single_key = join("-", $userid, $secid);

    my FB::SecGroup $self = $single->get($single_key);

    # need to instantiate a new object?
    unless ($self) {
        $self = fields::new($class);
        $self->_init;

        $self->{u}     = _u_from_uuid($uuid);
        $self->{secid} = $secid;
    }

    # was a grpname passed?  if so we'll go ahead and fill it in
    if ($grpname) {
        $self->{grpname} = $grpname;
        $self->{_loaded_secgroup} = 1;
    }

    # register ourself as a singleton
    return $single->set($single_key => $self);
}

# create a new user security group
sub create_user {
    my $class = shift;
    my $uuid  = shift;

    my $u = _u_from_uuid($uuid);

    # FIXME: locking to avoid a race here
    my $secid = $u->alloc_secid('user')
        or return FB::error("unable to allocate user secid");

    return FB::SecGroup->create($u, $secid, @_);
}

# create a new security group with given secid
sub create {
    my $class   = shift;
    my $uuid    = shift;
    my $secid   = int(shift);
    my $grpname = shift;

    my $u = _u_from_uuid($uuid);

    return FB::error("invalid secid")
        unless $secid > 0 && $secid < 251;

    return error("utf8")
        unless FB::is_utf8(\$grpname);

    $u->do("INSERT INTO secgroups VALUES (?,?,?)",
           $u->{userid}, $secid, $grpname);
    return FB::error($u->errstr) if $u->err;

    return FB::SecGroup->new($u, $secid, $grpname);
}

# create a new security group from a secgroup row
sub from_secgroup_row {
    my $class = shift;
    my ($uuid, $row) = @_;

    my $u = _u_from_uuid($uuid);

    croak "row has no secid"
        unless defined $row->{secid};
    croak "row's userid doesn't match the provided uuid"
        unless $row->{userid} == $u->{userid};
    croak "row has no grpname"
        unless defined $row->{grpname}; # FIXME: is '' valid?

    # just call new with the optional grpname arg
    return FB::SecGroup->new
        ($u, $row->{secid}, $row->{grpname});
}


###############################################################################
# Accessors
#

sub u       { _get($_[0], 'u'      ) }
sub secid   { _get($_[0], 'secid'  ) }
sub grpname { _get($_[0], 'grpname') }

sub members {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    # not already loaded?
    $self->_load_from_secmembers
        unless @{$self->{members}};

    return @{$self->{members}};
}

###############################################################################
# Object Methods
#

sub valid {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    return $self->_load_from_secgroups;
}

sub add_member {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    my $uuid = shift;
    my $u_add = _u_from_uuid($uuid);

    # anything to do?
    return 1 if grep { $_->{userid} == $u_add->{userid} } $self->members;

    my $u = $self->u;

    # add this member in the database
    $u->do("INSERT INTO secmembers VALUES (?,?,?)",
           $u->{userid}, $self->{secid}, $u_add->{userid});
    return FB::error($u) if $u->err;

    # add this user to the current object in memory
    push @{$self->{members}}, $u_add;

    return 1;
}

sub delete_member {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    my $uuid = shift;
    my $u_add = _u_from_uuid($uuid);

    # anything to do?
    return 1 unless grep { $_->{userid} == $u_add->{userid} } $self->members;

    my $u = $self->u;

    # remove this member from the database
    $u->do("DELETE FROM secmembers WHERE userid=? AND secid=? AND otherid=?",
           $u->{userid}, $self->{secid}, $u_add->{userid});
    return FB::error($u) if $u->err;

    # remove this user from the current object in memory
    @{$self->{members}} = grep { $_->{userid} != $u_add->{userid} } @{$self->{members}};

    return 1;
}

sub is_member {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    my $uuid = shift;
    my $u_other = _u_from_uuid($uuid);

    return scalar(grep { $_->{userid} == $u_other->{userid} } $self->members) ? 1 : 0;
}

sub rename {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    my $grpname = shift;
    return error("utf8")
        unless FB::is_utf8(\$grpname);

    my $u     = $self->{u};
    my $secid = $self->{secid};

    # update in the database
    $u->do("UPDATE secgroups SET grpname=? " .
           "WHERE userid=? AND secid=?",
           $grpname, $u->{userid}, $secid);
    return FB::error($u) if $u->err;

    # now update object in memory, but call constructor to do so since it
    # will properly update the singleton in memory and set _loaded_secgroups
    FB::SecGroup->new($self->{u}, $self->{secid}, $grpname)
        or return FB::error("unable to construct SecGroup object");

    return 1;
}

sub delete {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    my $u     = $self->{u};
    my $secid = $self->{secid};

    # FIXME: do gallery/upic/etc object need to be loaded and have methods
    #        called so that they remain consistent in memory?

    # remove the group
    $u->do("DELETE FROM secgroups WHERE userid=? AND secid=?",
           $u->{userid}, $secid);
    $u->do("DELETE FROM secmembers WHERE userid=? AND secid=?",
           $u->{userid}, $secid);

    # remove its usage
    $u->do("UPDATE gallery SET secid=0 WHERE userid=? AND secid=?",
           $u->{userid}, $secid);
    $u->do("UPDATE upic SET secid=0 WHERE userid=? AND secid=?",
           $u->{userid}, $secid);

    # gallerysize needs adjusting
    my %had;
    $u->do("LOCK TABLE gallerysize WRITE");
    my $sth = $u->prepare("SELECT gallid, count FROM gallerysize ".
                          "WHERE userid=? AND secid=?",
                          $u->{userid}, $secid);
    $sth->execute;
    while (my ($gallid, $count) = $sth->fetchrow_array) {

        my $gal = $u->load_gallery_id($gallid);

        # add to private count:  (we subtract later with DELETE)
        FB::change_gal_size($u, $gal, 0, $count);
    }
    $u->do("DELETE FROM gallerysize WHERE userid=? AND secid=?",
           $u->{userid}, $secid);
    $u->do("UNLOCK TABLES");

    # delete this singleton so it won't live on for later callers
    #  - probably unncessary
    my $single_key = join("-", $u->{userid}, $secid);
    $single->delete($single_key);

    # finally, clear out our guts
    return $self->_init;
}


###############################################################################
# Class Methods
#

# return a string given this $u, secid
sub name {
    my ($class, $u, $secid) = @_;

    return FB::SecGroup->new($u, $secid)->grpname if ($secid > 0 && $secid < 251);

    my $names = {
        255 => 'Public',
        251 => 'Reserved',
        252 => 'Reserved',
        253 => 'Registered Users',
        254 => 'All Groups',
        0   => 'Private',
    }->{$secid};

    return $names if $names;
    return 'Invalid group';
}

# returns [url, w, h] for the icon representing this security group
# returns undef if no icon
sub icon {
    my ($class, $secid) = @_;

    return undef if ($secid < 0 || $secid > 255);
    return [$FB::IMGPREFIX . '/icon_protected.gif', 14, 15] if ($secid > 0 && $secid < 251); # custom group is protected icon

    my $attrs = {
        255 => undef,
        251 => undef,
        252 => undef,
        252 => undef,
        253 => [$FB::IMGPREFIX . '/icon_protected.gif', 14, 15],
        254 => [$FB::IMGPREFIX . '/fb-userinfo.gif', 17, 17],
        0   => [$FB::IMGPREFIX . '/icon_private.gif', 16, 16],
    }->{$secid};

    return $attrs;
}

# returns an img tag for the icon representing this security group
# takes $u, secid
sub icontag {
    my ($class, $u, $secid) = @_;

    # for alt/title tag
    my $ename = FB::ehtml(FB::SecGroup->name($u, $secid));

    my $icon = FB::SecGroup->icon($secid);

    return '' unless $icon;

    return "<img src='$icon->[0]' width='$icon->[1]' height='$icon->[2]' alt='$ename' title='$ename' border='0' />";
}

sub load_secgroups {
    my $class = shift;
    croak "load_secgroups is a class method" if ref $class;

    my $uuid     = shift;
    my $sec_list = shift;

    croak "bogus extra args" if @_;

    my $u = _u_from_uuid($uuid);

    my $where = '';
    my @needload;
    if ($sec_list) {
        @needload = grep { ! $_->{_loaded_secgroup} } @$sec_list;
        return 1 unless @needload;

        $where = _secid_where("secid", \@needload);
    }

    # grpname is the only column needed from 'secgroups'
    my $rows = $u->selectall_hashref
        ("SELECT userid, secid, grpname FROM secgroups ".
         "WHERE userid=? $where", 'secid', $u->{userid})
        or return FB::error($u);

    # if no sec_list, we're returning a hashref (keyed by secid) of all groups
    if (! $sec_list) {

        my %ret = ();
        while (my ($secid, $secrow) = each %$rows) {

            $ret{$secid} = FB::SecGroup->from_secgroup_row($u, $secrow)
                or croak "failed to create secgroup '$secid' from secgroup row";
        }
        return \%ret;
    }

    # otherwise we're just filling in $sec objects for them
    my $missing = 0;
    foreach my $sec (@needload) {
        my $secid = $sec->{secid};
        unless ($rows->{$secid}) {
            $missing = 1;
            next;
        }

        # don't need to modify $sec, because $sec is a singleton, and from_secgroup_row
        # will get the same record that we have, and fill it in...
        FB::SecGroup->from_secgroup_row($u, $rows->{$secid});
    }

    return $missing ? 0 : 1;
}

sub load_secmembers {
    my $class = shift;
    croak "load_secmembers is a class method" if ref $class;

    my $uuid     = shift;
    my $sec_list = shift;

    croak "bogus extra args" if @_;

    my $u = _u_from_uuid($uuid);

    my $where = '';
    my @needload;
    if ($sec_list) {
        @needload = grep { ! $_->{_loaded_secmembers} } @$sec_list;
        return 1 unless @needload;

        $where = _secid_where("secid", \@needload);
    }

    my $sth = $u->prepare
        ("SELECT secid, otherid FROM secmembers WHERE userid=? $where");
    $sth->execute($u->{userid});
    return FB::error($u) if $u->err;

    my %members  = (); # secid => [ member_uid* ]
    my %all_uids = (); # member_id => ct
    while (my ($secid, $otherid) = $sth->fetchrow_array) {
        push @{$members{$secid}}, $otherid;
        $all_uids{$otherid}++;
    }

    # build a list of all unique member userids
    my @all_uids = keys %all_uids;

    my $member_u = FB::User->load_userids(@all_uids) || {};

    # convert ids to u objects in place
    while (my ($secid, $list) = each %members) {
        foreach (@$list) {
            return FB::error("unable to load user object for uid '$_'")
                unless $member_u->{$_};

            $_ = $member_u->{$_};
        }
    }

    # if no sec_list, we're returning a hashref (keyed by secid) of all members
    return \%members unless $sec_list;

    # otherwise we're just filling in member lists
    foreach my $sec (@needload) {

        my $secid = $sec->{secid};
        $sec->{members} = $members{$secid} || [];
        $sec->{_loaded_secmembers} = 1;
    }

    return 1;
}


###############################################################################
# Internal helper functions
#

sub _init {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    $self->{u}       = undef;
    $self->{secid}   = undef;
    $self->{grpname} = undef;
    $self->{members} = [];

    # nothing's been loaded yet
    $self->{_loaded_secgroup}   = 0;
    $self->{_loaded_secmembers} = 0;

    return 1;
}

sub _load_from_secgroups {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    # nothing to do if already loaded
    return 1 if $self->{_loaded_secgroup};

    return __PACKAGE__->load_secgroups
        ($self->{u},
         [ _secgroups_needing_field
           ($self->{u}, '_loaded_secgroup') ]
         );
}

sub _load_from_secmembers {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    # nothing to do if already loaded
    return 1 if $self->{_loaded_secmembers};

    return __PACKAGE__->load_secmembers
        ($self->{u},
         [ _secgroups_needing_field
           ($self->{u}, '_loaded_secmembers') ]
         );
}

sub _get {
    my FB::SecGroup $self = shift;
    croak "invalid SecGroup object"
        unless $self->isa('FB::SecGroup');

    my $field = shift
        or croak "no field passed to _get()";

    croak "invalid field '$field' in SecGroup object"
        unless exists $self->{$field};

    $self->_load_from_secgroups
        unless defined $self->{$field};

    # now values are loaded from db
    return $self->{$field};
}

sub _u_from_uuid {
    my $uuid = shift;

    if (ref $uuid) {
        croak "uuid is ref, but not FB::User"
            unless $uuid->isa("FB::User");

        return $uuid;
    }

    my $u = FB::load_userid($uuid)
        or croak "couldn't load user from userid";

    return $u;
}

sub _userid_from_uuid {
    my $uuid = shift;

    if (ref $uuid) {
        croak "uuid is ref, but not FB::User"
            unless $uuid->isa("FB::User");

        return $uuid->{userid};
    }

    # not a ref, just a userid
    return $uuid+0;
}

sub _secid_where {
    my ($col, $list, $all_thres) = @_;

    # if list is greater than $all_thres threshold, don't return a
    # WHERE query and let's just load everything.
    return "" if defined $all_thres && @$list > $all_thres;

    # impossible where, to prevent queries, if caller didn't check
    # their list being empty.
    return "AND 1=0" unless @$list;
    return "AND $col=" . int($list->[0]{secid}) if @$list == 1;
    return "AND $col IN (" . join(",", map { int($_->{secid}) } @$list) . ")";
}

sub _secgroups_needing_field {
    my $u     = shift;
    croak "invalid FB::User object passed"
        unless $u->isa("FB::User");

    my $field = shift;
    die "extra args" if @_;

    return grep { $_->{u}{userid} == $u->{userid} &&
                  ! $_->{$field}
                } $single->get_all;
}


###############################################################################
# Deprecated APIs
#

package FB;

use strict;


# <WCMFUNC>
# name: FB::update_secgroup_multi
# des: Updates/creates multiple groups and sets secmembers in them
# args: u, hash
# des-hash: { secid => [ grpname, [ memberid1, memberid2, ... ]] }
# returns: bool
# </WCMFUNC>
sub update_secgroup_multi {   #DEPRECATED
    my ($u, $update) = @_;

    my $err = sub { $@ = $_[0], return undef; };

    return $err->('invalid $u object') unless $u;
    return $err->('invalid $update hash') unless $update && ref $update eq 'HASH';

    my @secids = keys %$update;
    return 1 unless @secids;

    # update structure: { secid => [ name, [members ...]] }, { ... }

    $u->writer or return $err->("couldn't connect to cluster $u->{clusterid} writer");

    my $lockname = "secgroups-$u->{userid}";
    my $got_lock = $u->selectrow_array("SELECT GET_LOCK(?,5)", $lockname);
    return $err->("couldn't get lock: $lockname") unless $got_lock;
    my $unlock = sub {
        $u->do("SELECT RELEASE_LOCK(?)", $lockname);
        return @_ ? $err->(@_) : undef;
    };

    # update groups
    {
        my @vals = map { $u->{userid}, $_, $update->{$_}->[0] }
                   grep { $update->{$_}->[0] } @secids;
        my $bind = join(",", map { "(?,?,?)" } @secids);

        $u->do("REPLACE INTO secgroups (userid, secid, grpname) VALUES $bind", @vals)
            or return $unlock->($u->errstr);
    }

    # update group members
    {
        # find userids in given groups who belong to the current domain ID.
        # these are eligible for deletion, but we'll whitelist ones which are being re-added
        my %to_delete = (); # { secid => { uid } }
        my $secid_in = join(",", map { $_ + 0 } @secids);
        my $sth = $u->prepare("SELECT m.secid, u.userid FROM secmembers m, user u " .
                              "WHERE m.userid=? AND m.otherid=u.userid " .
                              "AND u.domainid=? AND m.secid IN ($secid_in)",
                              $u->{userid}, $u->{domainid});
        $sth->execute;
        return $unlock->($u) if $u->err;
        while (my ($secid, $uid) = $sth->fetchrow_array) {
            $to_delete{$secid}->{$uid} = 1;
        }

        my @vals = ();
        my $bind = "";
        foreach my $secid (@secids) {
            my $val = $update->{$secid};
            next unless ref $val eq 'ARRAY';

            foreach my $memid (@{$val->[1]}) {
                next unless $memid;
                push @vals, $u->{userid}, $secid, $memid;
                $bind .= "(?,?,?),";

                # don't delete this one
                delete $to_delete{$secid}->{$memid};
            }
        }
        chop $bind;

        # merge in new secmembers we were given
        if (@vals) {
            $u->do("REPLACE INTO secmembers (userid, secid, otherid) VALUES $bind",@ vals)
                or return $unlock->($u->errstr);
        }

        # delete those who need deleted
        my @deletes = ();
        while (my ($secid, $val) = each %to_delete) {
            foreach my $uid (keys %$val) {
                push @deletes, "(secid=$secid AND otherid=$uid)";
            }
        }
        if (@deletes) {
            $u->do("DELETE FROM secmembers WHERE userid=? AND " .
                   "(" . join(" OR ", @deletes) . ")", $u->{userid})
                or return $unlock->($u->errstr);
        }
    }

    $unlock->();
    return 1;
}


# <WCMFUNC>
# name: FB::load_secgroups
# des: Loads a user's security groups
# args: u
# returns: hashref; keys=security group ids, value=secgroups row hashref
# </WCMFUNC>
sub load_secgroups {  #DEPRECATED: use $u->secgroups
    my $u = shift;
    return undef unless $u;

    my $ret = {};
    my $sth = $u->prepare("SELECT userid, secid, grpname ".
                          "FROM secgroups WHERE userid=?",
                          $u->{userid});
    $sth->execute;
    while (my $row = $sth->fetchrow_hashref) {
        $ret->{$row->{'secid'}} = $row;
    }

    return $ret;
}

# <WCMFUNC>
# name: FB::load_secgroup
# des: Loads a security group
# args: u, secid
# des-secid: security group id to load
# returns: hashref of secgroups row, or undef if none.
# </WCMFUNC>
sub load_secgroup {  #DEPRECATED: use $u->load_secgroup_id($secid)
   my ($u, $secid) = @_;
   return undef unless $u;
   return $u->selectrow_hashref("SELECT * FROM secgroups WHERE ".
                                "userid=? AND secid=?",
                                $u->{'userid'}, $secid);
}


# <WCMFUNC>
# name: FB::load_secmembers
# des: Loads members for a security group
# args: u, secid
# des-secid: security group id to load members for
# returns: hashref; keys=userids, values=hashref with userid, domainid, user, usercs
# </WCMFUNC>
sub load_secmembers {  #DEPRECATED: use $sec->members
   my ($u, $secid) = @_;
   return undef unless $u;

   my $ret = {};
   # FIXME: use memcache like LJ::load_userids() after the secmembers load
   my $sth = $u->prepare("SELECT u.userid, u.domainid, u.usercs ".
                         "FROM secmembers s, user u ".
                         "WHERE s.userid=? AND s.secid=? ".
                         "AND u.userid=s.otherid",
                         $u->{'userid'}, $secid);
   $sth->execute;
   while (my $row = $sth->fetchrow_hashref) {
       $row->{user} = FB::fbuser_text($row->{usercs}, $row->{domainid});
       $ret->{$row->{userid}} = $row;
   }

   return $ret;
}

# <WCMFUNC>
# name: FB::load_secmembers_multi
# des: Loads members for a set of security groups
# args: u, secids
# des-secids: arrayref of security group ids for which members should be loaded
# returns: hashref of hashrefs; secid => { userid => { secid, userid, domainid, user, usercs } }
# </WCMFUNC>
sub load_secmembers_multi {  #DEPRECATED
   my ($u, $secids, $opts) = @_;
   return undef unless $u && ref $secids eq 'ARRAY';
   return {} unless @$secids;
   $opts = {} unless ref $opts eq 'HASH';

   return FB::error("Couldn't connect to user database cluster") unless $u->writer;

   my $ret = {};
   # FIXME: use memcache like LJ::load_userids() after the secmembers load
   my $sec_in = join(",", map { $_ + 0 } @$secids);
   my $sth = $u->prepare("SELECT s.secid, u.userid, u.domainid, u.usercs ".
                         "FROM secmembers s, user u ".
                         "WHERE s.userid=? AND s.secid IN ($sec_in) ".
                         "AND u.userid=s.otherid",
                         $u->{userid});
   $sth->execute;
   return FB::error($u) if $u->err;

   while (my $row = $sth->fetchrow_hashref) {
       $row->{user} = FB::fbuser_text($row->{usercs}, $row->{domainid});
       $ret->{$row->{secid}}->{$row->{userid}} = $row;
   }

   return $ret;
}


# <WCMFUNC>
# name: FB::sec_groups
# des: Loads secids belonging to $u to which $remote belongs
# args: u, remote
# des-u: user whose groups we should search
# des-remote: user who we are searching for in $u's groups
# returns: array of secids matching the search
# </WCMFUNC>
sub sec_groups {  #DEPRECATED: use $u->secgroups_with_member($other_u)
    &nodb;

    my ($u, $remoteid) = @_;
    return undef unless $u;

    $remoteid = want_userid($remoteid);
    return 255 unless $remoteid;   # if no remote, only applicable for public.

    my @out;
    if ($u->{'userid'} == $remoteid) {
        # remote is owner, so can see private & all custom groups
        push @out, 0, 1..250;
    } else {
        my $sth = $u->prepare("SELECT secid FROM secmembers WHERE userid=? AND otherid=?",
                              $u->{'userid'}, $remoteid);
        $sth->execute;
        while (my $secid = $sth->fetchrow_array) {
            push @out, $secid;
        }
    }
    push @out, 254 if @out;  # 'all groups'
    push @out, 253, 255;     # registered user & public
    return @out;
}



1;
