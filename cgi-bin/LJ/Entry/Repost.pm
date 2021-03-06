package LJ::Entry::Repost;

use strict;
use warnings;

use LJ;
require 'ljprotocol.pl';
use LJ::Lang;

use LJ::Pay::Repost::Offer;
use LJ::Pay::Repost::Blocking;

use constant { REPOST_KEYS_EXPIRING    => 60*60*2,
               REPOST_USERS_LIST_LIMIT => 25,
               REPOSTS_LIST_LIMIT      => 1000,
             };

# memcache namespace: reposters chunks are stored with these keys in memcache
my $memcache_ns = 'reposters_list_chunk2';

sub __get_count {
    my ($u, $jitemid) = @_;

    my $journalid = $u->userid;
    my $memcache_key = "reposted_count:$journalid:$jitemid";

    my ($count) = LJ::MemCache::get($memcache_key);
    if (defined $count) {
        return $count;
    }

    my $dbcr = LJ::get_cluster_master($u)
        or die "get cluster for journal failed";

    my ($count_jitemid) = $dbcr->selectrow_array( 'SELECT COUNT(reposted_jitemid) ' .
                                                  'FROM repost2 ' .
                                                  'WHERE journalid = ? AND jitemid = ?',
                                                   undef,
                                                   $journalid,
                                                   $jitemid, );

    LJ::MemCache::set(  $memcache_key,
                        $count_jitemid,
                        REPOST_KEYS_EXPIRING );

    return $count_jitemid;
}

sub __get_repost {
    my ($u, $jitemid, $reposterid) = @_;
    return 0 unless $u;

    my $journalid = $u->userid;
    my $memcache_key = "reposted_item:$journalid:$jitemid:$reposterid";
    my $cached = LJ::MemCache::get($memcache_key);
    my ($repost_jitemid, $cost) = ($cached ? (split /:/, $cached) : ());
    if ($repost_jitemid) {
        return ($repost_jitemid, $cost);
    }

    ($repost_jitemid, $cost) = __get_repost_full($u, $jitemid, $reposterid);

    if ($repost_jitemid) {
        LJ::MemCache::set($memcache_key, (join ':', $repost_jitemid, $cost), REPOST_KEYS_EXPIRING);
        return ($repost_jitemid, $cost);
    }

    return 0;
}

sub __get_repost_full {
    my ($u, $jitemid, $reposterid) = @_;
    return 0 unless $u;

    my $dbcr = LJ::get_cluster_master($u)
        or die "get cluster for journal failed";

    my ($repost_jitemid, $cost, $blid, $repost_time) = $dbcr->selectrow_array( 'SELECT reposted_jitemid, cost, blid, repost_time ' .
                                                                               'FROM repost2 ' .
                                                                               'WHERE journalid = ? AND jitemid = ? AND reposterid = ?',
                                                                               undef,
                                                                               $u->userid,
                                                                               $jitemid,
                                                                               $reposterid, );
    return ($repost_jitemid, $cost, $blid, $repost_time);
}


sub __create_repost_record {
    my (%args) = @_;

    my $journalu         = $args{'journalu'};
    my $jitemid          = $args{'jitemid'};
    my $repost_journalid = $args{'repost_journalid'};
    my $repost_itemid    = $args{'repost_itemid'};
    my $cost             = $args{'cost'};
    my $blid             = $args{'blid'};

    # my ($u, $jitemid, $repost_journalid, $repost_itemid, $cost, $blid) = @_;

    $cost ||= 0;

    my $current_count = __get_count($journalu, $jitemid);

    my $journalid = $journalu->userid;
    my $time  = time();
    my $query = 'INSERT INTO repost2 (journalid,' .
                                     'jitemid,' .
                                     'reposterid, ' .
                                     'reposted_jitemid,' .
                                     'cost,' .
                                     'blid, ' .
                                     'repost_time) VALUES(?,?,?,?,?,?,?)';

    $journalu->do( $query,
            undef,
            $journalid,
            $jitemid,
            $repost_journalid,
            $repost_itemid,
            $cost,
            $blid,
            $time );

    die $journalu->errstr if $journalu->err;

    #
    # remove last users list block from cache
    #
    my $last_block_id = int( $current_count / REPOST_USERS_LIST_LIMIT );
    LJ::MemCache::delete("$memcache_ns:$journalid:$jitemid:$last_block_id");

    #
    # remove prev block too
    #
    if ($last_block_id > 0) {
        $last_block_id--;
        LJ::MemCache::delete("$memcache_ns:$journalid:$jitemid:$last_block_id")
    }

    #
    # inc or add reposters counter
    #
    my $memcache_key_count = "reposted_count:$journalid:$jitemid";
    LJ::MemCache::incr($memcache_key_count, 1);

    my $memcache_key_status = "reposted_item:$journalid:$jitemid:$repost_journalid";
    LJ::MemCache::set($memcache_key_status, (join ':', $repost_itemid, $cost), REPOST_KEYS_EXPIRING);
}

sub __delete_repost_record {
    my ($u, $jitemid, $reposterid) = @_;
    my $journalid = $u->userid;

    #
    # remove users list
    #
    __clean_reposters_list($u, $jitemid);

    #
    # remove record from db
    #
    $u->do('DELETE FROM repost2 WHERE journalid = ? AND jitemid = ? AND reposterid = ?',
            undef,
            $u->userid,
            $jitemid,
            $reposterid,);

    #
    # remove cached reposts count
    #
    LJ::MemCache::delete("reposted_count:$journalid:$jitemid");

    #
    # remove cached status
    #
    LJ::MemCache::delete("reposted_item:$journalid:$jitemid:$reposterid");
}

sub __create_post {
    my (%opts) = @_;

    my $journalu = $opts{'journalu'};
    my $posteru  = $opts{'posteru'};
    my $timezone = $opts{'timezone'};
    my $url      = $opts{'url'};
    my $error    = $opts{'error'};

    my $err = 0;
    my $flags = { 'noauth'             => 1,
                  'use_custom_time'    => 0,
                  'u'                  => $posteru,
                  'entryrepost'        => 1, };

    my $event_text_stub = LJ::Lang::ml('entry.reference.event_text', { 'url' =>  $url});

    #
    # Needs to create new entry
    #
    my %req = (
                'ver'         => 4,
                'username'    => $posteru->username,
                'event'       => $event_text_stub,
                'subject'     => '',
                'tz'          => $timezone,
                'usejournal'  => $journalu->username,
              );

    #
    # Sends request to create new
    #
    my $res = LJ::Protocol::do_request("postevent",
                                        \%req,
                                        \$err,
                                        $flags);

    if ($err) {
         my ($code, $text) = split(/:/, $err);
         $$error = LJ::API::Error->make_error( $text, -$code );
         return;
    }

    return LJ::Entry->new(  $journalu,
                            jitemid => $res->{'itemid'} );
}

sub __create_repost {
    my (%opts) = @_;

    my $journalu     = $opts{'journalu'};
    my $posteru      = $opts{'posteru'};
    my $source_entry = $opts{'source_entry'};
    my $timezone     = $opts{'timezone'};
    my $cost         = $opts{'cost'} || 0;
    my $error        = $opts{'error'};

    if (!$source_entry->visible_to($posteru)) {
        $$error = LJ::API::Error->get_error('repost_access_denied');
        return;
    }

    my $source_journalid = $source_entry->journalid;
    my $source_journal   = $source_entry->journal;
    my $source_jitemid   = $source_entry->jitemid;

    my $post_obj;

    my $offerid = $source_entry->repost_offer;

    my $repost_offer;
    if ($offerid) {
        $repost_offer = LJ::Pay::Repost::Offer->get_repost_offer(
            $source_entry->posterid, $offerid );
    }

    my $lock_name = $repost_offer
        ? 'repost:'.$source_journalid.":".$source_jitemid
        : 'repost:'.$source_journalid.":".$source_jitemid.":".$journalu->id;

    my $get_lock = sub {
        LJ::get_lock( LJ::get_db_writer(), 'global', $lock_name );
    };

    my $release_lock = sub {
        LJ::release_lock( LJ::get_db_writer(), 'global', $lock_name );
    };

    my $fail = sub {
        $$error = shift;
        $release_lock->();
        LJ::delete_entry($journalu->userid, $post_obj->jitemid, undef, $post_obj->anum) if $post_obj;
        return;
    };

    $get_lock->() or return $fail->(LJ::API::Error->get_error('unknown_error'));

    my ($repost_itemid) = __get_repost( $source_journal,
                                        $source_jitemid,
                                        $journalu->userid );
    if ($repost_itemid) {
        return $fail->(LJ::API::Error->get_error('repost_already_exist'));
    }

    my ($reposter_cost, $total_cost);

    if($cost) {
        unless ($repost_offer && $repost_offer->budget) {
            return $fail->(LJ::API::Error->get_error('repost_notpaid'));
        }

        ($reposter_cost, $total_cost) = $repost_offer->cost($posteru);

        if ($cost > $reposter_cost) {
            return $fail->(LJ::API::Error->get_error('repost_cost_error'));
        } elsif ($cost < $reposter_cost) {
            $total_cost = $repost_offer->total_cost($cost);
        }
    }

    $post_obj = __create_post(
        'journalu' => $journalu,
        'posteru'  => $posteru,
        'timezone' => $timezone,
        'url'      => $source_entry->url,
        'error'    => $error,
    );

    if (!$post_obj) {
        return $fail->(LJ::API::Error->get_error('unknown_error'));
    }

    my $ret = eval {
    my $mark = $source_journalid . ":" . $source_jitemid;
    $post_obj->convert_to_repost($mark);
    
    my $props = { 'repost' => 'e' };
    
    if (my $targeting_opt = $repost_offer && $repost_offer->targeting_opt()) {
        $props->{'repost_targeting_opt'} = $targeting_opt;
    }

    $post_obj->set_prop_multi( $props );

    my $blid = 0;

    if ($repost_offer) {
        $repost_offer->on_repost_create( reposterid => $posteru->userid,
                                         cost       => $total_cost );
    }

    if ($cost) {
        my $err;

        $blid = LJ::Pay::Repost::Blocking->create(\$err,
                                                  offerid          => $offerid,
                                                  journalid        => $source_journalid,
                                                  jitemid          => $source_jitemid,
                                                  reposterid       => $posteru->id,
                                                  reposted_jitemid => $post_obj->jitemid,
                                                  posterid         => $source_entry->posterid,
                                                  qty              => $total_cost,
                                                  system_profit    => $total_cost - $cost,
                                                  );
        unless($blid){
            return $fail->(LJ::API::Error->get_error('repost_blocking_error'));
        }
    }

    #
    # create record
    #
    my $repost_jitemid = $post_obj->jitemid;

    __create_repost_record(
        'journalu'         => $source_journal,
        'jitemid'          => $source_jitemid,
        'repost_journalid' => $journalu->userid,
        'repost_itemid'    => $repost_jitemid,
        'cost'             => $cost,
        'blid'             => $blid,
    );

    return;
    }; # eval

    if ($@) {
        warn $@;
        return $fail->(LJ::API::Error->get_error('unknown_error'));
    }

    return $ret if $ret;

    $release_lock->();

    return $post_obj;
}

sub get_status {
    my ($class, $entry_obj, $u) = @_;


    my $result = {
        'count'    =>  __get_count($entry_obj->journal, $entry_obj->jitemid),
        reposted   => 0,
        paid       => 0,
        cost       => 0,
    };

    if ($u) {

        my $is_owner = ($entry_obj->posterid == $u->userid) ? 1 : 0;

        my ($reposted, $cost) = __get_repost( $entry_obj->journal,
                                              $entry_obj->jitemid,
                                              $u->userid );
        $reposted = (!!$reposted) || 0;

        my $paid = $reposted && !$is_owner ?
            (!!$cost || 0) :
            (!!$entry_obj->repost_offer || 0);

        if ($paid && !$reposted) {
            my $repost_offer = LJ::Pay::Repost::Offer->get_repost_offer($entry_obj->posterid, $entry_obj->repost_offer);

            $cost = $repost_offer->cost($u);
            my $budget = $repost_offer->budget;

            $paid = 0 if ($cost == 0 && !$is_owner) || !$budget;

            $result->{budget} = LJ::delimited_number( $repost_offer->budget ) if $is_owner;
        }

        $result->{reposted} = $reposted;
        $result->{paid}     = $paid;
        $result->{cost}     = LJ::delimited_number( $cost );
    }

    return $result;
}

sub __reposters {
    my ($dbcr, $journalid, $jitemid) = @_;

    my $reposted = $dbcr->selectcol_arrayref( "SELECT reposterid " .
                                              "FROM repost2 " .
                                              "WHERE journalid = ? AND jitemid = ? LIMIT 1000",
                                              undef,
                                              $journalid,
                                              $jitemid, );

    return undef unless scalar @$reposted;
    return $reposted;
}

sub __clean_reposters_list {
    my ($u, $jitemid) = @_;

    # get blocks count
    my $blocks_count = int(__get_count($u, $jitemid)/REPOST_USERS_LIST_LIMIT) + 1;

    # construct memcache keys base
    my $journalid = $u->userid;
    my $key_base = "$memcache_ns:$journalid:$jitemid";

    # clean all blocks
    for (my $i = 0; $i < $blocks_count; $i++) {
        LJ::MemCache::delete("$key_base:$i");
    }
}

sub __put_reposters_list {
    my ($journalid, $jitemid, $data, $lastrequest) = @_;

    my $subkey       = "$journalid:$jitemid";
    my $memcache_key = "$memcache_ns:$subkey:$lastrequest";

    my $serialized = LJ::JSON->to_json( $data );
    LJ::MemCache::set( $memcache_key, $serialized, REPOST_KEYS_EXPIRING );
}

sub __get_reposters_list {
    my ($journalid, $jitemid, $lastrequest) = @_;

    my $memcache_key = "$memcache_ns:$journalid:$jitemid:$lastrequest";

    my $data;
    my $reposters = LJ::MemCache::get($memcache_key);

    if ($reposters) {
        eval {
            $data = LJ::JSON->from_json($reposters);
        };
        if ($@) {
            warn $@;
        }
    }
    return $data;
}

sub __get_reposters {
    my ($u, $jitemid, $lastrequest) = @_;
    return [] unless $u;

    my $dbcr = LJ::get_cluster_master($u)
        or die "get cluster for journal failed";

    my $block_begin = $lastrequest * REPOST_USERS_LIST_LIMIT;
    my $final_limit = REPOST_USERS_LIST_LIMIT + 1;
    my $query_reposters = 'SELECT reposterid ' .
                          'FROM repost2 ' .
                          'WHERE journalid = ? AND jitemid = ? ' .
                          'ORDER BY repost_time ' .
                          "LIMIT $block_begin, $final_limit";

    my $reposters = $dbcr->selectcol_arrayref( $query_reposters,
                                               undef,
                                               $u->userid,
                                               $jitemid,);
    return $reposters;
}

sub is_repost {
    my ($class, $u, $itemid) = @_;
    my $jitemid = int($itemid / 256);

    my $props = {};
    LJ::load_log_props2($u, [ $jitemid ], $props);
    my $item_props = $props->{ $jitemid};

    return !!$item_props->{'repost_link'};
}

sub get_list {
    my ($class, $entry, $lastrequest) = @_;

    my $journalid = $entry->journalid;
    my $jitemid   = $entry->jitemid;

    #
    # $lastrequest should be >= 0
    #
    if (!$lastrequest || $lastrequest < 0) {
        $lastrequest = 0;
    }

    #
    # Try to get value from cache
    #
    my $cached_reposters = __get_reposters_list($journalid,
                                                $jitemid,
                                                $lastrequest);
    if ($cached_reposters) {
        $cached_reposters->{'count'}  = __get_count($entry->journal,
                                                    $entry->jitemid);
        return $cached_reposters;
    }


    #
    # If there is no cache then get from db
    #
    my $repostersids = __get_reposters( $entry->journal,
                                        $jitemid,
                                        $lastrequest );

    #
    # construct answer structure
    #
    my $reposters_info = { users => [] };
    my $users = $reposters_info->{'users'};

    my $reposters_count = scalar @$repostersids;
    $reposters_info->{'last'}   = $lastrequest + 1;

    if ($reposters_count < REPOST_USERS_LIST_LIMIT + 1) {
        $reposters_info->{'nomore'} = 1;
    } else {
        pop @$repostersids;
    }

    foreach my $reposter (@$repostersids) {
        my $u = LJ::want_user($reposter);
        push @$users, {
            'userid' => $u->userid,
            'user'   => $u->user,
            'url'    => $u->journal_base,
        };
    }

    $reposters_info->{'last'}   = $lastrequest + 1;

    #
    # put data structure to cache
    #
    __put_reposters_list( $journalid,
                          $jitemid,
                          $reposters_info,
                          $lastrequest );

    #
    # no need to cache 'count'
    #
    $reposters_info->{'count'}  = __get_count($entry->journal,
                                              $entry->jitemid);

    return $reposters_info;
}

sub get_reposts {
    my ($class, $dbcr, $journalid, $jitemid, $lastrequest, %opts) = @_;

    if (!$lastrequest || $lastrequest < 0) {
        $lastrequest = 0;
    }

    my $limit  = REPOSTS_LIST_LIMIT;
    my $offset = REPOSTS_LIST_LIMIT * $lastrequest;
    my $where  = '';

    $where .= "AND repost_time >= $opts{mintime} " if $opts{mintime};

    my $reposts = $dbcr->selectall_arrayref( "SELECT reposterid, repost_time " .
                                             "FROM repost2 " .
                                             "WHERE journalid = ? AND jitemid = ? " .
                                             $where .
                                             "LIMIT $limit OFFSET $offset",
                                             { Slice => {} },
                                             $journalid,
                                             $jitemid, );
    return undef unless scalar @$reposts;
    return $reposts;
}

sub delete_all_reposts_records {
    my ($class, $journalid, $jitemid) = @_;

    my $memcache_key = "reposted_count:$journalid:$jitemid";
    LJ::MemCache::delete($memcache_key);

    my $u = LJ::want_user($journalid);
    my $dbcr = LJ::get_cluster_master($u)
        or die "get cluster for journal failed";

    while (my $reposted = __reposters($dbcr, $journalid, $jitemid)) {
        foreach my $reposterid (@$reposted) {
            my $memcache_key_status = "reposted_item:$journalid:$jitemid:$reposterid";
            LJ::MemCache::delete($memcache_key_status);
        }

        my $reposters = join(',', @$reposted);

        $u->do("DELETE FROM repost2 WHERE journalid = ? AND jitemid = ? AND reposterid IN ($reposters)",
                undef,
                $u->userid,
                $jitemid,);
    }
}

sub delete {
    my ($class, $u, $entry_obj) = @_;

    #
    # Get entry id to delete
    #
    my ($repost_itemid, $cost, $blid, $repost_time) = __get_repost_full( $entry_obj->journal,
                                                                         $entry_obj->jitemid,
                                                                         $u->userid );

    #
    # If repost offer
    #
    if (my $offerid = $entry_obj->repost_offer) {
        my $offer = LJ::Pay::Repost::Offer->get_repost_offer($entry_obj->posterid, $offerid);
        $offer->on_repost_delete(
            reposterid  => $u->userid,
            cost        => $cost,
            repost_time => $repost_time,
        );
    }

    if ($blid) {
        my $blocking = LJ::Pay::Repost::Blocking->load($blid);
        die 'Cannot load blocking' unless $blocking;
        $blocking->release unless ($blocking->released || $blocking->paid);
    }

    #
    # If entry exists in db
    #
    if ($repost_itemid) {
        LJ::set_remote($u);

        my $remote = LJ::get_remote();
        my $entry = LJ::Entry->new($u->userid, jitemid => $repost_itemid);

        #
        # Try to delete entry
        #
        my $result = LJ::API::Event->delete({ itemid => $repost_itemid,
                                              journalid => $u->userid   } );

        #
        # If entry doesnt't exists then it should be removed from db
        #
        my $entry_not_found_code = LJ::API::Error->get_error_code('entry_not_found');
        my $error = $result->{'error'};

        #
        # Error is deversed from 'entry not found'
        #
        if ($error && $error->{'error_code'} != $entry_not_found_code) {
            return $result;
        }


        __delete_repost_record( $entry_obj->journal,
                                $entry_obj->jitemid,
                                $u->userid);

        LJ::User::UserlogRecord::DeleteRepost->create( $remote,
            'remote' => $remote,
            'jitemid' => $repost_itemid*256 + $entry->{'anum'},
            'journalid' => $u->userid,
        );

        my $status = $class->get_status($entry_obj, $u);
        $status->{'delete'} = 'OK';
        return $status;
    }

    return LJ::API::Error->get_error('entry_not_found');
}

sub create {
    my ( $class, %args ) = @_;

    my $journalu     = $args{'journalu'};
    my $posteru      = $args{'posteru'};
    my $source_entry = $args{'source_entry'};
    my $timezone     = $args{'timezone'} || 'guess';
    my $cost         = $args{'cost'};

    $posteru ||= $journalu;

    # the code isn't ready for this use case, so block this path
    # in case someone makes a coding error
    if ( ! LJ::u_equals( $journalu, $posteru ) && $cost ) {
        die 'Cannot create a paid repost in a community';
    }

    my $source_journalid = $source_entry->journalid;
    my $source_journal   = $source_entry->journal;
    my $source_jitemid   = $source_entry->jitemid;

    my $result = {};

    if ($source_entry->original_post) {
        $source_entry = $source_entry->original_post;
    }

    if ( $journalu->equals( $source_journal ) ) {
        return LJ::API::Error->get_error('same_user');
    }

    unless ( $posteru->is_validated ) {
        return LJ::API::Error->get_error('not_validated');
    }

    if ( $journalu->is_suspended || $posteru->is_suspended ) {
        return LJ::API::Error->get_error('user_suspended');
    }

    if ( $journalu->is_deleted || $posteru->is_deleted ) {
        return LJ::API::Error->get_error('user_deleted');
    }

    if ( ! $journalu->is_visible || ! $posteru->is_visible ) {
        return LJ::API::Error->get_error('invalid_user');
    }

    my $error;

    my $memcache_key = join ':', 'reposted_item', $source_journalid, $source_jitemid, $journalu->id;
    if (LJ::MemCache::get($memcache_key)) {
        $error = LJ::API::Error->get_error('repost_already_exist');
        $error->{'error'}->{'data'} = $class->get_status($source_entry, $journalu);
        return $error;
    }

    my $reposted_obj = __create_repost(
        'journalu'     => $journalu,
        'posteru'      => $posteru,
        'source_entry' => $source_entry,
        'timezone'     => $timezone,
        'cost'         => $cost,
        'error'        => \$error,
    );

    if ($reposted_obj) {
        # create new repost: $cost > 0 => paid
        LJ::PackedLogSink::Hooks->repost( {
            type              => 'link',
            source_entry      => $source_entry,
            repost_journal_id => $journalu->userid,
            repost_ditem_id   => $reposted_obj->{'ditemid'},
            cost              => $cost || 0,
        } );

        my $count = __get_count( $source_journal, $source_jitemid );

        $result->{'result'} = { 'count' => $count };

        return $result;
    } else {
        unless ($error && $error->{'error'}) {
            $error = LJ::API::Error->get_error('unknown_error');
        }

        $error->{'error'}->{'data'} =
            $class->get_status( $source_entry, $journalu );

        return $error;
    }
}

sub substitute_content {
    my ($class, $entry_obj, $opts, $props) = @_;

    my $domain = LJ::Lang::get_dom("general");
    my $lang = LJ::Lang::get_effective_lang();

    my $remote = LJ::get_remote();
    my $original_entry_obj = $entry_obj->original_post;

    unless ($original_entry_obj) {
        my $link = $entry_obj->prop('repost_link');
        if ($link) {
            my ($org_journalid, $org_jitemid) = split(/:/, $link);
            return 0 unless int($org_journalid);

            my $journal = int($org_journalid) ? LJ::want_user($org_journalid) :
                                                undef;

            my $fake_entry = LJ::Entry->new( $journal, jitemid => $org_jitemid);

            my $subject = LJ::Lang::get_text($lang, 'entry.reference.journal.delete.subject', $domain->{'dmid'} );
            my $event   = LJ::Lang::ml($lang,
                                        'entry.reference.journal.delete',
                                         $domain->{'dmid'},
                                        'datetime'     => $entry_obj->eventtime_mysql,
                                        'url'          => $fake_entry->url);

            if ($opts->{'original_post_obj'}) {
                ${$opts->{'original_post_obj'}}= $fake_entry;
            }

            if ($opts->{'removed'}) {
                ${$opts->{'removed'}} = 1;
            }

            if ($opts->{'repost_obj'}) {
                ${$opts->{'repost_obj'}} = $entry_obj;
            }

            if ($opts->{'subject_repost'}) {
                ${$opts->{'subject_repost'}} = $subject;
            }

            if ($opts->{'subject'}) {
                ${$opts->{'subject'}}  = $subject;
            }

            if ($opts->{'event_raw'}) {
                ${$opts->{'event_raw'}} = $event;
            }

            if ($opts->{'event'}) {
                ${$opts->{'event'}} = $event;
            }

            return 1;
        }
        return 0;
    }

    if ($opts->{'removed'}) {
        ${$opts->{'removed'}} = 0;
    }

    if ($opts->{'anum'}) {
        ${$opts->{'anum'}} = $original_entry_obj->anum;
    }

    if ($opts->{'cluster_id'}) {
        ${$opts->{'cluster_id'}} = $original_entry_obj->journal->clusterid;
    }

    if ($opts->{'original_post_obj'}) {
        ${$opts->{'original_post_obj'}}= $original_entry_obj;
    }

    if ($opts->{'repost_obj'}) {
        ${$opts->{'repost_obj'}} = $entry_obj;
    }

    if ($opts->{'ditemid'}) {
        ${$opts->{'ditemid'}} = $original_entry_obj->ditemid;
    }

    if ($opts->{'itemid'}) {
        ${$opts->{'itemid'}} = $original_entry_obj->jitemid;
    }

    if ($opts->{'journalid'}) {
        ${$opts->{'journalid'}} = $original_entry_obj->journalid;
    }

    if ($opts->{'journalu'}) {
        ${$opts->{'journalu'}} = $original_entry_obj->journal;
    }

    if ($opts->{'posterid'}) {
        ${$opts->{'posterid'}} = $original_entry_obj->posterid;
    }

    if ($opts->{'allowmask'}) {
        ${$opts->{'allowmask'}} = $original_entry_obj->allowmask;
    }

    if ($opts->{'security'}) {
        ${$opts->{'security'}} = $original_entry_obj->security;
    }

    if ($opts->{'eventtime'}) {
        ${$opts->{'eventtime'}} = $entry_obj->eventtime_mysql;
    }

    if ($opts->{'event'}) {
        my $event_text = $original_entry_obj->event_raw;

        if ($props->{use_repost_signature}) {
            my $journal = $original_entry_obj->journal;

            my $text_var;
            if ($journal->is_community) {
                $text_var = LJ::u_equals($remote, $entry_obj->poster) ? 'entry.reference.journal.community.owner' :
                                                                        'entry.reference.journal.community.guest';
            } else {
                $text_var = LJ::u_equals($remote, $entry_obj->poster) ? 'entry.reference.journal.owner' :
                                                                        'entry.reference.journal.guest';
            }

            my $event =  LJ::Lang::get_text( $lang,
                                             $text_var,
                                             $domain->{'dmid'},
                                            { 'author'          => $original_entry_obj->poster->display_username,
                                              'reposter'        => $entry_obj->poster->display_username,
                                              'communityname'   => $original_entry_obj->journal->display_username,
                                              'datetime'        => $entry_obj->eventtime_mysql,
                                              'text'            => $event_text, });
            ${$opts->{'event'}} = $event;
        } else {
            ${$opts->{'event'}} = $event_text;
        }
    }

    if ($opts->{'head_mob'}) {
        my $event_text = $original_entry_obj->event_raw;

        if ($props->{use_repost_signature}) {
            my $journal = $original_entry_obj->journal;

            my $text_var;
            if ($journal->is_community) {
                $text_var = LJ::u_equals($remote, $entry_obj->poster) ? 'entry.reference.journal.community.owner' :
                                                                        'entry.reference.journal.community.guest';
            } else {
                $text_var = LJ::u_equals($remote, $entry_obj->poster) ? 'entry.reference.journal.owner' :
                                                                        'entry.reference.journal.guest';
            }

            my $event =  LJ::Lang::ml(  $lang,
                                        $text_var,
                                        $domain->{'dmid'},
                                        { 'author'          => $original_entry_obj->poster->display_username,
                                          'reposter'        => $entry_obj->poster->display_username,
                                          'communityname'   => $original_entry_obj->journal->display_username,
                                          'datetime'        => $entry_obj->eventtime_mysql,
                                          'text'            => "", });

            ${$opts->{'head_mob'}} = $event;
        }
    }

    if ($opts->{'event_friend'}) {
        my $event_text = $original_entry_obj->event_raw;

        if ($props->{use_repost_signature}) {
            my $journal = $original_entry_obj->journal;

            my $text_var = $journal->is_community ? 'entry.reference.friends.community' :
                                                    'entry.reference.friends.journal';

            $text_var .= LJ::u_equals($remote, $entry_obj->poster) ? '.owner' : '.guest';

            my $event = LJ::Lang::ml(  $lang,
                                       $text_var,
                                       $domain->{'dmid'},
                                       { 'author'           => $original_entry_obj->poster->display_username,
                                         'communityname'    => $original_entry_obj->journal->display_username,
                                         'reposter'         => $entry_obj->poster->display_username,
                                         'datetime'         => $entry_obj->eventtime_mysql,
                                         'text'             => $event_text, });


            ${$opts->{'event_friend'}} = $event;
        } else {
            ${$opts->{'event_friend'}} = $event_text;
        }
    }

    if ($opts->{'subject_repost'}) {
        my $subject_text = $original_entry_obj->subject_html;
        ${$opts->{'subject_repost'}} = $subject_text;
    }

    if ($opts->{'subject'}) {
        ${$opts->{'subject'}}  = $original_entry_obj->subject_html;
    }

    if ($opts->{'reply_count'}) {
        ${$opts->{'reply_count'}} = $original_entry_obj->reply_count;
    }

    return 1;
}

sub is_visible_in_friendsfeed {
    my ($class, $entry, $u) = @_;

    if ( my $targeting_opt = $entry->prop('repost_targeting_opt') ) {
        return 0 unless LJ::Pay::Repost::Offer->check_targeting_for_user($targeting_opt, $u);
    }

    return 1;
}


1;
