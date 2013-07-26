package LJ::RelationService::MysqlAPI;
use strict;

use LJ::MemCacheProxy;

## friends
sub find_relation_destinations {
    my $class = shift;
    my $u     = shift;
    my $type  = shift;
    my %opts  = @_;

    if ( $type eq 'F' ) {
        return $class->_find_relation_destinations_type_f($u, %opts);
    } else {
        return $class->_find_relation_destinations_type_other($u, $type, %opts);
    }
}

sub _find_relation_destinations_type_f {
    my $class = shift;
    my $u     = shift;
    my %opts  = @_;
    my $nogearman = $opts{nogearman} || 0;

    ## stricly disable gearman,
    ## load uids inporcess is faster than using gearman.
    $nogearman = 1;

    my $uids = $class->_friend_friendof_uids($u, 
                        %opts,
                        limit     => $opts{limit}, 
                        nogearman => $nogearman, 
                        mode      => "friends",
                        );
    return @$uids;
}

sub _find_relation_destinations_type_other {
    my $class = shift;
    my $u     = shift;
    my $type  = shift;
    my %opts  = @_;

    my $db = LJ::isdb($opts{db}) ? $opts{db} : undef;

    my $userid = $u->userid;
    my $typeid = LJ::get_reluser_id($type)+0;
    my $uids;

    my $eff_type = $typeid ? $typeid : $type;
    my $cached_data = LJ::MemCacheProxy::get("rlist:dst:$eff_type:$userid");
    if ($cached_data) {
        my @userids = unpack('V*', $cached_data);
        return @userids;
    }

    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_reader($u);
        $uids = $db->selectcol_arrayref("
            SELECT targetid 
            FROM reluser2 
            WHERE userid=? 
              AND type=?
        ", undef, $userid, $typeid);
    } else {
        # non-clustered reluser global table
        $db ||= LJ::get_db_reader();
        $uids = $db->selectcol_arrayref("
            SELECT targetid 
            FROM reluser 
            WHERE userid=? 
              AND type=?
        ", undef, $userid, $type);
    }

    unless ($opts{dont_set_cache}) {
        my $packed = pack('V*', @$uids);
        LJ::MemCacheProxy::set("rlist:dst:$eff_type:$userid", $packed, 24 * 3600)
    }
    ;
    return @$uids;
}

## friendofs
sub find_relation_sources {
    my $class = shift;
    my $u     = shift;
    my $type  = shift;
    my %opts  = @_;

    if ( $type eq 'F' ) {
        return $class->_find_relation_sources_type_f($u, %opts);
    } else {
        return $class->_find_relation_sources_type_other($u, $type, %opts);
    }
}

sub _find_relation_sources_type_f {
    my $class = shift;
    my $u     = shift;
    my %opts  = @_;
    my $nogearman = $opts{nogearman} || 0;
    
    ## stricly disable gearman
    ## load uids inporcess is faster than using gearman.
    $nogearman = 1;

    my $uids = $class->_friend_friendof_uids($u, 
                        %opts,
                        limit     => $opts{limit}, 
                        nogearman => $nogearman,
                        mode      => "friendofs",
                        );
    return @$uids;
}

sub _find_relation_sources_type_other {
    my $class = shift;
    my $u     = shift;
    my $type  = shift;
    my %opts  = @_;

    my $db = LJ::isdb($opts{db}) ? $opts{db} : undef;

    my $userid = $u->userid;
    my $typeid = LJ::get_reluser_id($type)+0;
    my $uids;

    my $eff_type = $typeid ? $typeid : $type;
    my $cached_data = LJ::MemCacheProxy::get("rlist:src:$eff_type:$userid");
    if ($cached_data) {
        my @userids = unpack('V*', $cached_data);
        return @userids;
    }

    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_reader($u);
        $uids = $db->selectcol_arrayref("
            SELECT userid 
            FROM reluser2 
            WHERE targetid=? 
              AND type=?
        ", undef, $userid, $typeid);
    } else {
        # non-clustered reluser global table
        $db ||= LJ::get_db_reader();
        $uids = $db->selectcol_arrayref("
            SELECT userid 
            FROM reluser 
            WHERE targetid=? 
              AND type=?
        ", undef, $userid, $type);
    }

    unless ($opts{dont_set_cache}) {
        my $packed = pack('V*', @$uids);
        LJ::MemCacheProxy::set("rlist:src:$eff_type:$userid", $packed, 24 * 3600);
    }

    return @$uids;
}

## friends rows
sub load_relation_destinations {
    my $class = shift;
    my $u     = shift;
    my $type  = shift;
    my %opts  = @_;
    my $limit     = $opts{limit} || 50000;
    my $nogearman = $opts{nogearman} || 0;

    my $friends = $class->_get_friends($u, 
                        %opts, 
                        limit     => $limit, 
                        nogearman => $nogearman,
                        );
    return $friends;
}

## friendofs rows
sub load_relation_sources {
    my $class = shift;
    my $u     = shift;
    my %opts  = @_;
    my $limit     = $opts{limit} || 50000;
    my $nogearman = $opts{nogearman} || 0;

    my $friendofs = $class->_get_friendofs($u, 
                        %opts, 
                        limit     => $limit, 
                        nogearman => $nogearman,
                        );
    return $friendofs;

}


##
sub create_relation_to {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my $type   = shift;
    my %opts   = @_;
    
    if ( $type eq 'F' ) {
        return $class->_create_relation_to_type_f($u, $friend, %opts);
    } else {
        return $class->_create_relation_to_type_other($u, $friend, $type, %opts);
    }
}

sub _create_relation_to_type_f {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my %opts   = @_;

    my $dbh = LJ::get_db_writer();
    
    my $cnt = $dbh->do("REPLACE INTO friends 
                            (userid, friendid, fgcolor, bgcolor, groupmask) 
                        VALUES 
                            (?, ?, ?, ?, ?)
                        ", undef, $u->userid, $friend->userid, $opts{fgcolor}, $opts{bgcolor}, $opts{groupmask});
    die "create_relation_to error: " . DBI->errstr if DBI->errstr;

    my $memkey = [$u->userid, "frgmask:" . $u->userid . ":" . $friend->userid];
    LJ::MemCacheProxy::set($memkey, $opts{groupmask}, time()+60*15);
    LJ::memcache_kill($friend->userid, 'friendofs');
    LJ::memcache_kill($friend->userid, 'friendofs2');

    # invalidate memcache of friends
    LJ::memcache_kill($u->userid, "friends");
    LJ::memcache_kill($u->userid, "friends2");

    LJ::run_hooks('befriended', $u, $friend);
    LJ::User->increase_friendsof_counter($friend->userid);

    $u->clear_cache_friends($friend);
    
    return $cnt;
}

sub _create_relation_to_type_other {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my $type   = shift;
    my %opts   = @_;

    my $typeid = LJ::get_reluser_id($type)+0;
    my $eff_type = $typeid || $type;

    # working on reluser or reluser2?
    my ($db, $table);
    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_master($u);
        $table = "reluser2";
    } else {
        # non-clustered reluser global table
        $db = LJ::get_db_writer();
        $table = "reluser";
    }
    return undef unless $db;

    # set in database
    $db->do("REPLACE INTO $table (userid, targetid, type) VALUES (?, ?, ?)",
            undef, $u->userid, $friend->userid, $eff_type);
    return undef if $db->err;

    # set in memcache
    LJ::_set_rel_memcache($u->userid, $friend->userid, $eff_type, 1);

    # drop list rel list
    LJ::MemCacheProxy::delete("rlist:src:$eff_type:" . $friend->userid);
    LJ::MemCacheProxy::delete("rlist:dst:$eff_type:" . $u->userid);

    return 1;
}


sub remove_relation_to {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my $type   = shift;
    
    if ( $type eq 'F' ) {
        return $class->_remove_relation_to_type_f($u, $friend);
    } else {
        return $class->_remove_relation_to_type_other($u, $friend, $type);
    }
}

sub _remove_relation_to_type_f {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;

    my $dbh = LJ::get_db_writer() 
        or return 0;

    my $cnt = $dbh->do("DELETE FROM friends WHERE userid=? AND friendid=?",
                        undef, $u->userid, $friend->userid);

    if (!$dbh->err && $cnt > 0) {
        LJ::run_hooks('defriended', $u, $friend);
        LJ::User->decrease_friendsof_counter($friend->userid);

        # delete friend-of memcache keys for anyone who was removed
        LJ::MemCacheProxy::delete([ $u->userid, "frgmask:" . $u->userid . ":" . $friend->userid ]);
        LJ::memcache_kill($friend->userid, 'friendofs');
        LJ::memcache_kill($friend->userid, 'friendofs2');

        LJ::memcache_kill($u->userid, 'friends');
        LJ::memcache_kill($u->userid, 'friends2');

        $u->clear_cache_friends($friend);
    }

    return $cnt;
}

sub _remove_relation_to_type_other {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my $type   = shift;

    my $typeid = LJ::get_reluser_id($type)+0;
    my $userid = ref($u) ? $u->userid : $u;
    my $friendid = ref($friend) ? $friend->userid : $friend;

    my $cache_base = '';
    my @rels = ($friendid);

    my $eff_type = $typeid ? $typeid : $type;
    if ($friendid eq '*') {
        @rels = $class->_find_relation_destinations_type_other($u, $type, dont_set_cache => 1);
        LJ::MemCacheProxy::delete("rlist:dst:$eff_type:" . $userid);
        $cache_base = "rlist:src:$eff_type";

    } elsif ($userid eq '*') {
        @rels = $class->_find_relation_sources_type_other($friend, $type, dont_set_cache => 1);
        LJ::MemCacheProxy::delete("rlist:src:$eff_type:" . $friendid);
        $cache_base = "rlist:dst:$eff_type";
    }

    if ($typeid) {
        # clustered reluser2 table
        return undef unless $u->writer;

        $u->do("DELETE FROM reluser2 WHERE " . ($userid ne '*' ? ("userid=".$userid." AND ") : "") .
               ($friendid ne '*' ? ("targetid=".$friendid." AND ") : "") . "type=$typeid");

        return undef if $u->err;
    } else {
        # non-clustered global reluser table
        my $dbh = LJ::get_db_writer()
            or return undef;

        my $qtype = $dbh->quote($type);
        $dbh->do("DELETE FROM reluser WHERE " . ($userid ne '*' ? ("userid=".$userid." AND ") : "") .
                 ($friendid ne '*' ? ("targetid=".$friendid." AND ") : "") . "type=$qtype");

        return undef if $dbh->err;
    }
    
    # if one of userid or targetid are '*', then we need to note the modtime
    # of the reluser edge from the specified id (the one that's not '*')
    # so that subsequent gets on rel:userid:targetid:type will know to ignore
    # what they got from memcache
    $eff_type = $typeid || $type;
    if ($userid eq '*') {
        LJ::MemCacheProxy::set([$friendid, "relmodt:$friendid:$eff_type"], time());
    } elsif ($friendid eq '*') {
        LJ::MemCacheProxy::set([$userid, "relmodu:$userid:$eff_type"], time());

    # if neither userid nor targetid are '*', then just call _set_rel_memcache
    # to update the rel:userid:targetid:type memcache key as well as the
    # userid and targetid modtime keys
    } else {
        LJ::_set_rel_memcache($userid, $friendid, $eff_type, 0);
    }    

    # drop list rel lists
    foreach my $uid (@rels) {
        LJ::MemCacheProxy::delete("$cache_base:$uid");
    }   

    return 1;
}


##
## Private methods
##

# helper method since the logic for both friends and friendofs is so similar
sub _friend_friendof_uids {
    my $class = shift;
    my $u     = shift;
    my %args  = @_;

    my $mode      = $args{mode};
    my $limit     = $args{limit};
    my $nogearman = $args{nogearman} || 0;

    ## check cache first
    my $res = $class->_load_friend_friendof_uids_from_memcache($u, $mode, $limit);
    return $res if defined $res;

    # call normally if no gearman/not wanted
    my $gc = '';
    return $class->_friend_friendof_uids_do($u, skip_memcached => 1, %args) # we've already checked memcached above
        if $nogearman or 
           not (LJ::conf_test($LJ::LOADFRIENDS_USING_GEARMAN, $u->userid) and 
                $gc = LJ::gearman_client());

    # invoke gearman
    my @uids = ();
    my $args = Storable::nfreeze({uid => $u->id, opts => \%args});
    my $task = Gearman::Task->new("load_friend_friendof_uids", \$args,
                                  {
                                      uniq => join("-", $mode, $u->id, $limit),
                                      on_complete => sub {
                                          my $res = shift;
                                          return unless $res;
                                          my $uidsref = Storable::thaw($$res);
                                          @uids = @{$uidsref || []};
                                      }
                                  });
    my $ts = $gc->new_task_set();
    $ts->add_task($task);
    $ts->wait(timeout => 30); # 30 sec timeout

    return \@uids;

}


# actually get friend/friendof uids, should not be called directly
sub _friend_friendof_uids_do {
    my $class = shift;
    my $u     = shift;
    my %args  = @_;

    ## ATTENTION:
    ##  'nolimit' option should not be used to generate
    ##  regular page. 
    ##  Use it with care only for admin pages only.

    my $limit   = $args{limit} || 50000;
    my $nolimit = $args{nolimit} ? 1 : 0; ## use it with care
    my $mode    = $args{mode};
    my $skip_memcached = $args{skip_memcached};

    $skip_memcached = 1 if $nolimit;

    ## cache
    unless ($skip_memcached){
        my $res = $class->_load_friend_friendof_uids_from_memcache($u, $mode, $limit);
        return $res if $res;
    }

    ## db
    ## disable $limit if $nolimit requires it.
    my $uids = $class->_load_friend_friendof_uids_from_db($u, $mode, $limit * (!$nolimit));

    if (not $nolimit and $uids and @$uids){
        ## do not cache if $nolimit option is in use,
        ## because with disabled limit we might put in the cache
        ## much more data than usually required.

        # if the list of uids is greater than 950k
        # -- slow but this definitely works
        my $pack = pack("N*", $limit);
        foreach (@$uids) {
            last if length $pack > 1024*950;
            $pack .= pack("N*", $_);
        }

        ## memcached
        my $memkey = $class->_friend_friendof_uids_memkey($u, $mode);
        LJ::MemCache::add($memkey, $pack, 3600);
    }

    return $uids;
}

sub _friend_friendof_uids_memkey {
    my ($class, $u, $mode) = @_;
    my $memkey;

    if ($mode eq "friends") {
        $memkey = [$u->id, "friends2:" . $u->id];
    } elsif ($mode eq "friendofs") {
        $memkey = [$u->id, "friendofs2:" . $u->id];
    } else {
        die "mode must either be 'friends' or 'friendofs'";
    }

    return $memkey;
}

sub _load_friend_friendof_uids_from_memcache {
    my ($class, $u, $mode, $limit) = @_;

    my $memkey = $class->_friend_friendof_uids_memkey($u, $mode);

    if (my $pack = LJ::MemCacheProxy::get($memkey)) {
        my ($slimit, @uids) = unpack("N*", $pack);
        # value in memcache is good if stored limit (from last time)
        # is >= the limit currently being requested.  we just may
        # have to truncate it to match the requested limit

        if ($slimit >= $limit) {
            @uids = @uids[0..$limit-1] if @uids > $limit;
            return \@uids;
        }

        # value in memcache is also good if number of items is less
        # than the stored limit... because then we know it's the full
        # set that got stored, not a truncated version.
        return \@uids if @uids < $slimit;
    }

    return undef;
}

## Attention: if 'limit' arg is omited, this method loads all userid from friends table.
sub _load_friend_friendof_uids_from_db {
    my $class = shift;
    my $u     = shift;
    my $mode  = shift;
    my $limit = shift;

    $limit = " LIMIT $limit" if $limit;

    my $sql = '';
    if ($mode eq 'friends'){
        $sql = "SELECT friendid FROM friends WHERE userid=? $limit";
    } elsif ($mode eq 'friendofs'){
        $sql = "SELECT userid FROM friends WHERE friendid=? $limit";
    } else {
        die "mode must either be 'friends' or 'friendofs'";
    }

    my $dbh  = LJ::get_db_reader();
    my $uids = $dbh->selectcol_arrayref($sql, undef, $u->id);
    return $uids;
}



##
## loads rows from friends table
##
sub _get_friends {
    my $class = shift;
    my $u     = shift;
    my %args  = @_;

    my $mask          = $args{mask};
    my $memcache_only = $args{memcache_only};
    my $force_db      = $args{force_db};
    my $nogearman     = $args{nogearma} || 0;

    return undef unless $u->userid;
    return undef if $LJ::FORCE_EMPTY_FRIENDS{$u->userid};

    unless ($force_db) {
        my $memc = $class->_get_friends_memc($u->userid, $mask);
        return $memc if $memc;
    }
    return {} if $memcache_only; # no friends

    # nothing from memcache, select all rows from the
    # database and insert those into memcache
    # then return rows that matched the given groupmask

    # no gearman/gearman not wanted
    my $gc = undef;
    return $class->_get_friends_db($u->userid, $mask)
        if $nogearman or
            not (LJ::conf_test($LJ::LOADFRIENDS_USING_GEARMAN, $u->userid) and $gc = LJ::gearman_client());

    # invoke the gearman
    my $friends;
    my $arg  = Storable::nfreeze({ userid => $u->userid, mask => $mask });
    my $task = Gearman::Task->new("load_friends", \$arg,
                                  {
                                      uniq => $u->userid,
                                      on_complete => sub {
                                          my $res = shift;
                                          return unless $res;
                                          $friends = Storable::thaw($$res);
                                      }
                                  });

    my $ts = $gc->new_task_set();
    $ts->add_task($task);
    $ts->wait(timeout => 30); # 30 sec timeout

    return $friends;
}

sub _get_friends_memc {
    my $class  = shift;
    my $userid = shift
        or Carp::croak("no userid to _get_friends_db");
    my $mask = shift;

    # memcache data version
    my $ver = 1;

    my $packfmt = "NH6H6NC";
    my $packlen = 15;  # bytes

    my @cols = qw(friendid fgcolor bgcolor groupmask showbydefault);

    # first, check memcache
    my $memkey = [$userid, "friends:$userid"];

    my $memfriends = LJ::MemCache::get($memkey);
    return undef unless $memfriends;

    my %friends; # rows to be returned

    # first byte of object is data version
    # only version 1 is meaningful right now
    my $memver = substr($memfriends, 0, 1, '');
    return undef unless $memver == $ver;

    # get each $packlen-byte row
    while (length($memfriends) >= $packlen) {
        my @row = unpack($packfmt, substr($memfriends, 0, $packlen, ''));

        # don't add into %friends hash if groupmask doesn't match
        next if $mask && ! ($row[3]+0 & $mask+0);

        # add "#" to beginning of colors
        $row[$_] = "\#$row[$_]" foreach 1..2;

        # turn unpacked row into hashref
        my $fid = $row[0];
        my $idx = 1;
        foreach my $col (@cols[1..$#cols]) {
            $friends{$fid}->{$col} = $row[$idx];
            $idx++;
        }
    }

    # got from memcache, return
    return \%friends;
}

sub _get_friends_db {
    my $class  = shift;

    my $userid = shift
        or Carp::croak("no userid to _get_friends_db");
    my $mask = shift;

    my $dbh = LJ::get_db_writer();

    my $lockname = "get_friends:$userid";
    my $release_lock = sub {
        LJ::release_lock($dbh, "global", $lockname);
    };

    # get a lock
    my $lock = LJ::get_lock($dbh, "global", $lockname);
    return {} unless $lock;

    # in lock, try memcache
    my $memc = $class->_get_friends_memc($userid, $mask);
    if ($memc) {
        $release_lock->();
        return $memc;
    }

    # inside lock, but still not populated, query db

    # memcache data info
    my $ver = 1;
    my $memkey = [$userid, "friends:$userid"];
    my $packfmt = "NH6H6NC";
    my $packlen = 15;  # bytes

    # columns we're selecting
    my @cols = qw(friendid fgcolor bgcolor groupmask showbydefault);

    my $mempack = $ver; # full packed string to insert into memcache, byte 1 is dversion
    my %friends = ();   # friends object to be returned, all groupmasks match

    my $sth = $dbh->prepare("SELECT friendid, fgcolor, bgcolor, groupmask, showbydefault " .
                            "FROM friends WHERE userid=?");
    $sth->execute($userid);
    die $dbh->errstr if $dbh->err;
    while (my @row = $sth->fetchrow_array) {

        # convert color columns to hex
        $row[$_] = sprintf("%06x", $row[$_]) foreach 1..2;

        my $newpack = pack($packfmt, @row);
        last if length($mempack) + length($newpack) > 950*1024;

        $mempack .= $newpack;

        # unless groupmask matches, skip adding to %friends
        next if $mask && ! ($row[3]+0 & $mask+0);

        # add "#" to beginning of colors
        $row[$_] = "\#$row[$_]" foreach 1..2;

        my $fid = $row[0];
        my $idx = 1;
        foreach my $col (@cols[1..$#cols]) {
            $friends{$fid}->{$col} = $row[$idx];
            $idx++;
        }
    }

    LJ::MemCache::add($memkey, $mempack);

    # finished with lock, release it
    $release_lock->();

    return \%friends;
}


## friendofs
sub _get_friendofs {
    my $class = shift;
    my $u     = shift;
    my %args  = @_;
    my $skip_memcached = $args{skip_memcached};
    my $limit          = $args{limit};
    my $nolimit        = $args{nolimit};

    ## ATTENTION:
    ##  'nolimit' option should not be used to generate
    ##  regular page. 
    ##  Use it with care only for admin pages only.

    $limit = 0 if $nolimit;

    # first, check memcache
    my $memkey = [$u->userid, "friendofs:" . $u->userid];

    unless ($skip_memcached) {
        my $memfriendofs = LJ::MemCache::get($memkey);
        return @$memfriendofs if $memfriendofs;
    }

    # nothing from memcache, select all rows from the
    # database and insert those into memcache

    my $dbh   = LJ::get_db_writer();
    my $limit_sql = $limit ? '' : " LIMIT " . ($LJ::MAX_FRIENDOF_LOAD + 1);
    my $friendofs = $dbh->selectcol_arrayref
        ("SELECT userid FROM friends WHERE friendid=? $limit_sql",
         undef, $u->userid) || [];
    die $dbh->errstr if $dbh->err;

    ## do not cache if $nolimit option is in use,
    ## because with disabled limit we might put in the cache
    ## much more data than usually required.
    LJ::MemCache::add($memkey, $friendofs) unless $skip_memcached;

    return @$friendofs;
}

sub is_relation_to {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my $type   = shift;
    my %opts   = @_;
    
    return undef unless $type && $u && $friend;

    my $userid = LJ::want_userid($u);
    my $friendid = LJ::want_userid($friend);

    my $typeid = LJ::get_reluser_id($type)+0;
    my $eff_type = $typeid || $type;

    my $key = "$userid-$friendid-$eff_type";
    return $LJ::REQ_CACHE_REL{$key} if defined $LJ::REQ_CACHE_REL{$key};

    # did we get something from memcache?
    my $memval = LJ::_get_rel_memcache($userid, $friendid, $eff_type);
    return $memval if defined $memval;

    # are we working on reluser or reluser2?
    my ($db, $table);
    if ($typeid) {
        # clustered reluser2 table
        $db = LJ::get_cluster_reader($u);
        $table = "reluser2";
    } else {
        # non-clustered reluser table
        $db ||= LJ::get_db_reader();
        $table = "reluser";
    }

    # get data from db, force result to be {0|1}
    my $dbval = $db->selectrow_array("SELECT COUNT(*) FROM $table ".
                                     "WHERE userid=? AND targetid=? AND type=? ",
                                     undef, $userid, $friendid, $eff_type)
        ? 1 : 0;

    # set in memcache
    LJ::_set_rel_memcache($userid, $friendid, $eff_type, $dbval);

    # return and set request cache
    return $LJ::REQ_CACHE_REL{$key} = $dbval;
}

sub is_relation_type_to {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my $types  = shift;
    my %opts   = @_;
    
    return undef unless $u && $friend;
    return undef unless ref $types eq 'ARRAY';

    my $userid = LJ::want_userid($u);
    my $friendid = LJ::want_userid($friend);

    $types = join ",", map {"'$_'"} @$types;

    my $dbh = LJ::get_db_writer();
    my $relcount = $dbh->selectrow_array("SELECT COUNT(*) FROM reluser ".
                                         "WHERE userid=$userid AND targetid=$friendid ".
                                         "AND type IN ($types)");
    return $relcount;
}

sub get_groupmask {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my %opts   = @_;
    
    return 0 unless $u && $friend;
 
    my $jid = LJ::want_userid($u);
    my $fid = LJ::want_userid($friend);
    return 0 unless $jid && $fid;

    my $memkey = [$jid,"frgmask:$jid:$fid"];
    my $mask = LJ::MemCacheProxy::get($memkey);
    unless (defined $mask) {
        my $dbw = LJ::get_db_writer();
        die "No database reader available" unless $dbw;

        $mask = $dbw->selectrow_array("SELECT groupmask FROM friends ".
                                      "WHERE userid=? AND friendid=?",
                                      undef, $jid, $fid);
        LJ::MemCacheProxy::set($memkey, $mask+0, time()+60*15);
    }

    return $mask+0;  # force it to a numeric scalar
}

sub delete_and_purge_completely {
    my $class = shift;
    my $u = shift;
    my %opts = @_;
    
    return unless $u;
    
    my $dbh = LJ::get_db_writer();
    $dbh->do("DELETE FROM reluser WHERE userid=?", undef, $u->id);
    $dbh->do("DELETE FROM friends WHERE userid=?", undef, $u->id);
    $dbh->do("DELETE FROM friends WHERE friendid=?", undef, $u->id);
    $dbh->do("DELETE FROM reluser WHERE targetid=?", undef, $u->id);

    foreach my $type (LJ::get_relation_types()) {
        my $typeid = LJ::get_reluser_id($type) || 0;
        my $eff_type = $typeid || $type;

        my @rels = $class->_find_relation_sources_type_other($u, $type, dont_set_cache => 1);
        foreach my $uid (@rels) {
            LJ::MemCacheProxy::delete("rlist:dst:$eff_type:$uid");
        }

        LJ::MemCacheProxy::delete("rlist:src:$eff_type:" . $u->id);
        LJ::MemCacheProxy::delete("rlist:dst:$eff_type:" . $u->id);
    }

    return 1;
}

sub set_rel_multi {
    my $class = shift;
    my $edges = shift;
    return _mod_rel_multi({ mode => 'set', edges => $edges });
}

sub clear_rel_multi {
    my $class = shift;
    my $edges = shift;
    return _mod_rel_multi({ mode => 'clear', edges => $edges });
}

# <LJFUNC>
# name: LJ::RelationService::MysqlAPI::_mod_rel_multi
# des: Sets/Clears relationship edges for lists of user tuples.
# args: keys, edges
# des-keys: keys: mode  => {clear|set}.
# des-edges: edges =>  array of arrayrefs of edges to set: [userid, targetid, type]
#            Where:
#            userid: source userid, or a user hash;
#            targetid: target userid, or a user hash;
#            type: type of the relationship.
# returns: 1 if all updates succeeded, otherwise undef
# </LJFUNC>
sub _mod_rel_multi
{
    my $opts = shift;
    return undef unless @{$opts->{edges}};

    my $mode = $opts->{mode} eq 'clear' ? 'clear' : 'set';
    my $memval = $mode eq 'set' ? 1 : 0;

    my @reluser  = (); # [userid, targetid, type]
    my @reluser2 = ();
    foreach my $edge (@{$opts->{edges}}) {
        my ($userid, $targetid, $type) = @$edge;
        $userid = LJ::want_userid($userid);
        $targetid = LJ::want_userid($targetid);
        next unless $type && $userid && $targetid;

        my $typeid = LJ::get_reluser_id($type)+0;
        my $eff_type = $typeid || $type;

        LJ::MemCacheProxy::delete("rlist:src:$eff_type:$targetid");
        LJ::MemCacheProxy::delete("rlist:dst:$eff_type:$userid");

        # working on reluser or reluser2?
        push @{$typeid ? \@reluser2 : \@reluser}, [$userid, $targetid, $eff_type];
    }

    # now group reluser2 edges by clusterid
    my %reluser2 = (); # cid => [userid, targetid, type]
    my $users = LJ::load_userids(map { $_->[0] } @reluser2);
    foreach (@reluser2) {
        my $cid = $users->{$_->[0]}->{clusterid} or next;
        push @{$reluser2{$cid}}, $_;
    }
    @reluser2 = ();

    # try to get all required cluster masters before we start doing database updates
    my %cache_dbcm = ();
    foreach my $cid (keys %reluser2) {
        next unless @{$reluser2{$cid}};

        # return undef immediately if we won't be able to do all the updates
        $cache_dbcm{$cid} = LJ::get_cluster_master($cid)
            or return undef;
    }

    # if any error occurs with a cluster, we'll skip over that cluster and continue
    # trying to process others since we've likely already done some amount of db
    # updates already, but we'll return undef to signify that everything did not
    # go smoothly
    my $ret = 1;

    # do clustered reluser2 updates
    foreach my $cid (keys %cache_dbcm) {
        # array of arrayrefs: [userid, targetid, type]
        my @edges = @{$reluser2{$cid}};

        # set in database, then in memcache.  keep the two atomic per clusterid
        my $dbcm = $cache_dbcm{$cid};

        my @vals = map { @$_ } @edges;

        if ($mode eq 'set') {
            my $bind = join(",", map { "(?,?,?)" } @edges);
            $dbcm->do("REPLACE INTO reluser2 (userid, targetid, type) VALUES $bind",
                      undef, @vals);
        }

        if ($mode eq 'clear') {
            my $where = join(" OR ", map { "(userid=? AND targetid=? AND type=?)" } @edges);
            $dbcm->do("DELETE FROM reluser2 WHERE $where", undef, @vals);
        }

        # don't update memcache if db update failed for this cluster
        if ($dbcm->err) {
            $ret = undef;
            next;
        }

        # updates to this cluster succeeded, set memcache
        LJ::_set_rel_memcache(@$_, $memval) foreach @edges;
    }

    # do global reluser updates
    if (@reluser) {

        # nothing to do after this block but return, so we can
        # immediately return undef from here if there's a problem
        my $dbh = LJ::get_db_writer()
            or return undef;

        my @vals = map { @$_ } @reluser;

        if ($mode eq 'set') {
            my $bind = join(",", map { "(?,?,?)" } @reluser);
            $dbh->do("REPLACE INTO reluser (userid, targetid, type) VALUES $bind",
                     undef, @vals);
        }

        if ($mode eq 'clear') {
            my $where = join(" OR ", map { "userid=? AND targetid=? AND type=?" } @reluser);
            $dbh->do("DELETE FROM reluser WHERE $where", undef, @vals);
        }

        # don't update memcache if db update failed for this cluster
        return undef if $dbh->err;

        # $_ = [userid, targetid, type] for each iteration
        LJ::_set_rel_memcache(@$_, $memval) foreach @reluser;
    }

    return $ret;
}

sub find_relation_attributes {
    my $class  = shift;
    my $u      = shift;
    my $friend = shift;
    my $type   = shift;
    my %opts   = @_;

    return undef unless $type eq 'F';

    return undef unless $u && $friend;
 
    my $jid = LJ::want_userid($u);
    my $fid = LJ::want_userid($friend);
    return undef unless $jid && $fid;

    my $dbr = LJ::get_db_reader();
    die "No database reader available" unless $dbr;

    my $fr = $dbr->selectrow_hashref("
        SELECT groupmask, fgcolor, bgcolor 
        FROM friends 
        WHERE userid=? 
          AND friendid=?
    ", { Slice => {} }, $u->userid, $friend->userid);
    return $fr;
}

1;
