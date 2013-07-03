package LJ;

use strict;
use warnings;

# Internal modules
use LJ::RelationService;

#########################
# Types of relations:
# P - poster
# A - maintainer
# B - ban
# N - pre-approved
# M - moderator
# S - supermaintainer
# I - inviter
# D - spammer
# W - journal sweeper
# C - do not receive mass mailing from community
# J - ban in journalpromo
#########################

sub get_relation_types {
    return ('P', # - poster
            'A', # - maintainer
            'B', # - ban
            'N', # - pre-approved
            'M', # - moderator
            'S', # - supermaintainer
            'I', # - inviter
            'D', # - spammer
            'W', # - journal sweeper
            'C', # - do not receive mass mailing from community
            'J', #- ban in journalpromo
            );
}

# <LJFUNC>
# name: LJ::is_friend
# des: Checks to see if a user is a friend of another user.
# returns: boolean; 1 if user B is a friend of user A or if A == B
# args: usera, userb
# des-usera: Source user hashref or userid.
# des-userb: Destination user hashref or userid. (can be undef)
# </LJFUNC>
sub is_friend {
    &nodb;

    my ($ua, $ub) = @_[0, 1];

    $ua = LJ::want_userid($ua);
    $ub = LJ::want_userid($ub);

    return 0 unless $ua && $ub;

    # get group mask from the first argument to the second argument and
    # see if first bit is set.  if it is, they're a friend.  get_groupmask
    # is memcached and used often, so it's likely to be available quickly.
    return LJ::get_groupmask(@_[0, 1]) & 1;
}

# <LJFUNC>
# name: LJ::is_banned
# des: Checks to see if a user is banned from a journal.
# returns: boolean; 1 if "user" is banned from "journal"
# args: user, journal
# des-user: User hashref or userid.
# des-journal: Journal hashref or userid.
# </LJFUNC>
sub is_banned {
    &nodb;

    # get user and journal ids
    my $uid = LJ::want_userid(shift);
    my $jid = LJ::want_userid(shift);
    return 1 unless $uid && $jid;

    # for speed: common case is non-community posting and replies
    # in own journal.  avoid db hit.
    return 0 if ($uid == $jid);
    
    # edge from journal -> user
    return LJ::check_rel($jid, $uid, 'B');
}

sub get_groupmask {
    my ($journal, $remote) = @_;
    return 0 unless $journal && $remote;

    return LJ::RelationService->get_groupmask($journal, $remote);
}

sub get_filtermask {
    my ($journal, $remote) = @_;
    return 0 unless $journal && $remote;

    return LJ::RelationService->get_filtermask($journal, $remote);
}


# <LJFUNC>
# name: LJ::get_reluser_id
# des: for [dbtable[reluser2]], numbers 1 - 31999 are reserved for
#      livejournal stuff, whereas numbers 32000-65535 are used for local sites.
# info: If you wish to add your own hooks to this, you should define a
#       hook "get_reluser_id" in ljlib-local.pl. No reluser2 [special[reluserdefs]]
#        types can be a single character, those are reserved for
#        the [dbtable[reluser]] table, so we don't have namespace problems.
# args: type
# des-type: the name of the type you're trying to access, e.g. "hide_comm_assoc"
# returns: id of type, 0 means it's not a reluser2 type
# </LJFUNC>
sub get_reluser_id {
    my $type = shift;
    return 0 if length $type == 1; # must be more than a single character
    my $val =
        {
            'hide_comm_assoc' => 1,
        }->{$type}+0;
    return $val if $val;
    return 0 unless $type =~ /^local-/;
    return LJ::run_hook('get_reluser_id', $type)+0;
}

# <LJFUNC>
# name: LJ::load_rel_user
# des: Load user relationship information. Loads all relationships of type 'type' in
#      which user 'userid' participates on the left side (is the source of the
#      relationship).
# args: db?, userid, type
# des-userid: userid or a user hash to load relationship information for.
# des-type: type of the relationship
# returns: reference to an array of userids
# </LJFUNC>
sub load_rel_user
{
    my $db = isdb($_[0]) ? shift : undef;
    my ($u, $type, %args) = @_;

    return undef unless $u and $type;

    my $limit = int(delete $args{limit}) || 50000;

    my @uids = LJ::RelationService->find_relation_destinations($u, $type, limit => $limit, db => $db, %args);
    return \@uids;
}

# <LJFUNC>
# name: LJ::load_rel_user_cache
# des: Loads user relationship information of the type 'type' where user
#      'targetid' participates on the left side (is the source of the relationship)
#      trying memcache first.  The results from this sub should be
#      <strong>treated as inaccurate and out of date</strong>.
# args: userid, type
# des-userid: userid or a user hash to load relationship information for.
# des-type: type of the relationship
# returns: reference to an array of userids
# </LJFUNC>
sub load_rel_user_cache
{
    my ($userid, $type) = @_;
    return undef unless $type && $userid;

    my $u = LJ::want_user($userid);
    return undef unless $u;
    $userid = $u->{'userid'};

    my $key = [ $userid, "reluser:$userid:$type" ];
    my $res = LJ::MemCacheProxy::get($key);

    return $res if $res;

    $res = LJ::load_rel_user($userid, $type);

    my $exp = time() + 60*30; # 30 min
    LJ::MemCacheProxy::set($key, $res, $exp);

    return $res;
}

# <LJFUNC>
# name: LJ::load_rel_target
# des: Load user relationship information. Loads all relationships of type 'type' in
#      which user 'targetid' participates on the right side (is the target of the
#      relationship).
# args: db?, targetid, type
# des-targetid: userid or a user hash to load relationship information for.
# des-type: type of the relationship
# returns: reference to an array of userids
# </LJFUNC>
sub load_rel_target
{
    my $db = isdb($_[0]) ? shift : undef;
    my ($u, $type, %args) = @_;

    return undef unless $u and $type;

    my $limit = int(delete $args{limit} || 50000);

    my @uids = LJ::RelationService->find_relation_sources($u, $type, limit => $limit, db => $db, %args);
    return \@uids;
}

# <LJFUNC>
# name: LJ::_get_rel_memcache
# des: Helper function: returns memcached value for a given (userid, targetid, type) triple, if valid.
# args: userid, targetid, type
# des-userid: source userid, nonzero
# des-targetid: target userid, nonzero
# des-type: type (reluser) or typeid (rel2) of the relationship
# returns: undef on failure, 0 or 1 depending on edge existence
# </LJFUNC>
sub _get_rel_memcache {
    return undef unless @LJ::MEMCACHE_SERVERS;
    return undef if $LJ::DISABLED{memcache_reluser};

    my ($userid, $targetid, $type) = @_;
    return undef unless $userid && $targetid && defined $type;

    # memcache keys
    my $relkey  = [$userid,   "rel:$userid:$targetid:$type"]; # rel $uid->$targetid edge
    my $modukey = [$userid,   "relmodu:$userid:$type"      ]; # rel modtime for uid
    my $modtkey = [$targetid, "relmodt:$targetid:$type"    ]; # rel modtime for targetid

    # do a get_multi since $relkey and $modukey are both hashed on $userid
    my $memc = LJ::MemCacheProxy::get_multi($relkey, $modukey);
    return undef unless $memc && ref $memc eq 'HASH';

    # [{0|1}, modtime]
    my $rel = $memc->{$relkey->[1]};
    return undef unless $rel && ref $rel eq 'ARRAY';

    # check rel modtime for $userid
    my $relmodu = $memc->{$modukey->[1]};
    return undef if ! $relmodu || $relmodu > $rel->[1];

    # check rel modtime for $targetid
    my $relmodt = LJ::MemCacheProxy::get($modtkey);
    return undef if ! $relmodt || $relmodt > $rel->[1];

    # return memcache value if it's up-to-date
    return $rel->[0] ? 1 : 0;
}

# <LJFUNC>
# name: LJ::_set_rel_memcache
# des: Helper function: sets memcache values for a given (userid, targetid, type) triple
# args: userid, targetid, type
# des-userid: source userid, nonzero
# des-targetid: target userid, nonzero
# des-type: type (reluser) or typeid (rel2) of the relationship
# returns: 1 on success, undef on failure
# </LJFUNC>
sub _set_rel_memcache {
    return 1 unless @LJ::MEMCACHE_SERVERS;

    my ($userid, $targetid, $type, $val) = @_;
    return undef unless $userid && $targetid && defined $type;
    $val = $val ? 1 : 0;

    # memcache keys
    my $relkey  = [$userid,   "rel:$userid:$targetid:$type"]; # rel $uid->$targetid edge
    my $modukey = [$userid,   "relmodu:$userid:$type"      ]; # rel modtime for uid
    my $modtkey = [$targetid, "relmodt:$targetid:$type"    ]; # rel modtime for targetid

    my $now = time();
    my $exp = $now + 3600*6; # 6 hour
    LJ::MemCacheProxy::set($relkey, [$val, $now], $exp);
    LJ::MemCacheProxy::set($modukey, $now, $exp);
    LJ::MemCacheProxy::set($modtkey, $now, $exp);

    # Also, delete this key, since the contents have changed.
    LJ::MemCacheProxy::delete([$userid, "reluser:$userid:$type"]);

    return 1;
}

# <LJFUNC>
# name: LJ::check_rel
# des: Checks whether two users are in a specified relationship to each other.
# args: db?, userid, targetid, type
# des-userid: source userid, nonzero; may also be a user hash.
# des-targetid: target userid, nonzero; may also be a user hash.
# des-type: type of the relationship
# returns: 1 if the relationship exists, 0 otherwise
# </LJFUNC>
sub check_rel
{
    my ($userid, $targetid, $type) = @_;
    return undef unless $type && $userid && $targetid;

    my $result;
    if ( ref $type eq 'ARRAY' ) {
        $result = LJ::RelationService->is_relation_type_to($userid, $targetid, $type);
    } else {
        $result = LJ::RelationService->is_relation_to($userid, $targetid, $type);
    }
    return $result;
}

# <LJFUNC>
# name: LJ::set_rel
# des: Sets relationship information for two users.
# args: dbs?, userid, targetid, type
# des-dbs: Deprecated; optional, a master/slave set of database handles.
# des-userid: source userid, or a user hash
# des-targetid: target userid, or a user hash
# des-type: type of the relationship
# returns: 1 if set succeeded, otherwise undef
# </LJFUNC>
sub set_rel
{
    my ($userid, $targetid, $type) = @_;

    return LJ::RelationService->create_relation_to($userid, $targetid, $type);
}

# <LJFUNC>
# name: LJ::set_rel_multi
# des: Sets relationship edges for lists of user tuples.
# args: edges
# des-edges: array of arrayrefs of edges to set: [userid, targetid, type].
#            Where:
#            userid: source userid, or a user hash;
#            targetid: target userid, or a user hash;
#            type: type of the relationship.
# returns: 1 if all sets succeeded, otherwise undef
# </LJFUNC>
sub set_rel_multi {
    return LJ::RelationService->set_rel_multi( \@_ );
}

# <LJFUNC>
# name: LJ::clear_rel_multi
# des: Clear relationship edges for lists of user tuples.
# args: edges
# des-edges: array of arrayrefs of edges to clear: [userid, targetid, type].
#            Where:
#            userid: source userid, or a user hash;
#            targetid: target userid, or a user hash;
#            type: type of the relationship.
# returns: 1 if all clears succeeded, otherwise undef
# </LJFUNC>
sub clear_rel_multi {
    return LJ::RelationService->clear_rel_multi( \@_ );
}

# <LJFUNC>
# name: LJ::clear_rel
# des: Deletes a relationship between two users or all relationships of a particular type
#      for one user, on either side of the relationship.
# info: One of userid,targetid -- bit not both -- may be '*'. In that case,
#       if, say, userid is '*', then all relationship edges with target equal to
#       targetid and of the specified type are deleted.
#       If both userid and targetid are numbers, just one edge is deleted.
# args: dbs?, userid, targetid, type
# des-dbs: Deprecated; optional, a master/slave set of database handles.
# des-userid: source userid, or a user hash, or '*'
# des-targetid: target userid, or a user hash, or '*'
# des-type: type of the relationship
# returns: 1 if clear succeeded, otherwise undef
# </LJFUNC>
sub clear_rel
{
    &nodb;
    my ($userid, $targetid, $type) = @_;
    return undef if $userid eq '*' and $targetid eq '*';

    my $u;
    $u = LJ::want_user($userid) unless $userid eq '*';
    $userid = LJ::want_userid($userid) unless $userid eq '*';
    $targetid = LJ::want_userid($targetid) unless $targetid eq '*';
    return undef unless $type && $userid && $targetid;

    my $result = LJ::RelationService->remove_relation_to($userid, $targetid, $type);
    return undef unless $result;



    return 1;
}

1;
