package LJ::Entry::Repost;

use strict;
use warnings;

require 'ljlib.pl';
require 'ljprotocol.pl';
use LJ::Lang;

sub __get_count {
    my ($u, $jitemid) = @_;

    my $journalid = $u->userid;
    my $memcache_key = "reposted_count:$journalid:$jitemid";
    my ($count) = LJ::MemCache::get($memcache_key);
    if ($count) {
        return $count;
    }

    my $dbcr = LJ::get_cluster_master($u)
        or die "get cluster for journal failed";

    my ($count_jitemid) = $dbcr->selectrow_array( 'SELECT COUNT(reposted_jitemid) ' .
                                                  'FROM repost2 ' .
                                                  'WHERE journalid = ? AND jitemid = ?',
                                                   undef,
                                                   $u->userid,
                                                   $jitemid, );

    LJ::MemCache::set($memcache_key, $count_jitemid, 3600);

    return $count_jitemid;

}

sub __get_repostid {
    my ($u, $jitemid, $reposterid) = @_;

    my $journalid = $u->userid;
    my $memcache_key = "reposted_itemid:$journalid:$jitemid:$reposterid";
    my ($itemid) = LJ::MemCache::get($memcache_key);
    if ($itemid) {
        return $itemid;
    }

    my $dbcr = LJ::get_cluster_master($u)
        or die "get cluster for journal failed";

    my ($repost_jitemid) = $dbcr->selectrow_array( 'SELECT reposted_jitemid ' .
                                                   'FROM repost2 ' .
                                                   'WHERE journalid = ? AND jitemid = ? AND reposterid = ?',
                                                   undef,
                                                   $u->userid,
                                                   $jitemid,
                                                   $reposterid, );

    LJ::MemCache::set($memcache_key, $repost_jitemid, 3600);
    return $repost_jitemid;
}

sub __create_repost_record {
    my ($u, $itemid, $repost_journalid, $repost_itemid) = @_;

    my $journalid = $u->userid;
    my $memcache_key_count = "reposted_count:$journalid:$itemid";
    my $memcache_key_status = "reposted_itemid:$journalid:$itemid:$repost_journalid";
   
    LJ::MemCache::delete($memcache_key_count);
    LJ::MemCache::delete($memcache_key_status);

    $u->do('INSERT INTO repost2 VALUES(?,?,?,?)',
            undef,
            $u->userid,
            $itemid,
            $repost_journalid,
            $repost_itemid, );
}

sub __delete_repost_record {
    my ($u, $itemid, $reposterid) = @_;

    my $journalid = $u->userid;
    my $memcache_key = "reposted_count:$journalid:$itemid";
    my $memcache_key_status = "reposted_itemid:$journalid:$itemid:$reposterid";
    LJ::MemCache::delete($memcache_key);
    LJ::MemCache::delete($memcache_key_status);

    $u->do('DELETE FROM repost2 WHERE journalid = ? AND jitemid = ? AND reposterid = ?',
            undef,
            $u->userid,
            $itemid,
            $reposterid,);
}

sub __create_post {
    my ($u, $timezone, $url, $error) = @_;

    my $err = 0;
    my $flags = { 'noauth'             => 1,
                  'use_custom_time'    => 0,
                  'u'                  => $u };

    my %req = ( 'username'    => $u->user,
                'event'       => LJ::Lang::ml('repost.text', { 'url' =>  $url}),
                'subject'     => '',
                'tz'          => $timezone,
              );

    # move to LJ::API
    my $res = LJ::Protocol::do_request("postevent", \%req, \$err, $flags);

    my $fail = !defined $res->{itemid} && $res->{message};
    if ($fail) {
         $$error = $res->{message};
         return;
    }

    return LJ::Entry->new($u, jitemid => $res->{'itemid'} );
}

sub __create_repost {
    my ($opts) = @_;

    my $u         = $opts->{'u'};
    my $entry_obj = $opts->{'entry_obj'}; 
    my $timezone  = $opts->{'timezone'};
    my $error     = $opts->{'error'};

    if (!$entry_obj->visible_to($u)) {
        $$error = LJ::Lang::ml('repost.access_denied');
        return;
    }

    my $post_obj = __create_post($u, $timezone, $entry_obj->url);
    if (!$post_obj) {
        $$error = LJ::Lang::ml('repost.unknown_error');
        return;
    }

    my $mark = $entry_obj->journalid . ":" . $entry_obj->jitemid;
    $post_obj->convert_to_repost($mark);

    # create record
    my $repost_jitemid = $post_obj->jitemid;
    
    my $journalid = $entry_obj->journalid;
    my $jitemid   = $entry_obj->jitemid;

    __create_repost_record($entry_obj->journal,
                           $jitemid,
                           $u->userid,
                           $repost_jitemid);

    return $post_obj;
}

sub get_status {
    my ($class, $u, $entry_obj) = @_;

    my $reposted = __get_repostid( $entry_obj->journal, $entry_obj->jitemid, $u->userid ) || 0;
    return  { 'result' => { 
              'count'    =>  __get_count($entry_obj->journal, $entry_obj->jitemid), 
              'reposted' => !!$reposted, },
            };
}

sub __reposters {
    my ($dbcr, $journalid, $jitemid) = @_;

    my $reposted = $dbcr->selectcol_arrayref( 'SELECT reposterid ' .
                                              'FROM repost2 ' .
                                              'WHERE journalid = ? AND jitemid = ? LIMIT 1000',
                                              undef,
                                              $journalid,
                                              $jitemid, ); 

    return undef unless scalar @$reposted;
    return $reposted;
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
            warn  LJ::D($reposterid);
            my $memcache_key_status = "reposted_itemid:$journalid:$jitemid:$reposterid";
            LJ::MemCache::delete($memcache_key_status);
        }

        my $reposters = join(',', @$reposted);
        warn $reposters;

        $u->do('DELETE FROM repost2 WHERE journalid = ? AND jitemid = ? AND reposterid IN ($reposters)',
                undef,
                $u->userid,
                $jitemid,);

    }
}

sub delete {
    my ($class, $u, $entry_obj) = @_;
    my $repost_itemid = __get_repostid( $entry_obj->journal, $entry_obj->jitemid, $u->userid );

    if ($repost_itemid) {
        LJ::set_remote($u);
        my $result = LJ::API::Event->delete({ itemid => $repost_itemid, journalid => $u->userid} ); 
        if ($result->{'error'}) { 
            return $result;
        }
        __delete_repost_record($entry_obj->journal, $entry_obj->jitemid, $u->userid);
    
        return  { 'result' => { 'delete' => 'OK' } } ;
    }

    return LJ::API::Error->get_error('entry_not_found');
}

sub create {
    my ($class, $u, $entry_obj, $timezone) = @_;
    my $result = {};
   
    if ($entry_obj->original_post) {
        $entry_obj = $entry_obj->original_post;
    }

    my $journalid = $entry_obj->journalid;
    my $jitemid   = $entry_obj->jitemid;

    my $repost_itemid = __get_repostid( $entry_obj->journal, $jitemid, $u->userid );

    my $error;

    if ($repost_itemid) {
        $error = LJ::Lang::ml('repost.already_exist');
    } else {
        my $reposted_obj = __create_repost( {'u'          => $u,
                                             'entry_obj'  => $entry_obj,
                                             'timezone'   => $timezone,
                                             'error'      => \$error } );

        if ($reposted_obj) {
            my $count = __get_count($entry_obj->journal, $entry_obj->jitemid);
            $result->{'result'} = { 'count' => $count };
        } elsif (!$error) {
            $error = LJ::Lang::ml('api.error.unknown_error');
        }
    }

    if ($error) {
        $result->{'error'}  = { 'error_code'    => -9000,
                                'error_message' => $error };
    }

    return $result;
}

sub substitute_content {
    my ($class, $entry_obj, $opts) = @_;

    my $original_entry_obj = $entry_obj->original_post;

    unless ($original_entry_obj) {
        my $link = $entry_obj->prop('repost_link'); 
        if ($link) {
            my ($org_journalid, $org_jitemid) = split(/:/, $link);
            my $journal = int($link) ? LJ::want_user($link) : undef;
             
            my $event = LJ::Lang::ml( 'entry.reference.journal.delete',
                                      'datetime'     => $entry_obj->eventtime_mysql );

            ${$opts->{'event'}} = $event;
            return 1;    
        }
        return 0;
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
        my $remote = LJ::get_remote();
        my $text_var =  LJ::u_equals($remote, $entry_obj->poster) ? 'entry.reference.journal.owner' : 
                                                                    'entry.reference.journal.guest';

        my $event_text = $original_entry_obj->event_html;
        my $event =  LJ::Lang::ml($text_var,  
                                    { 'author'       => LJ::ljuser2($original_entry_obj->poster),
                                      'reposter'     => LJ::ljuser2($entry_obj->poster),
                                      'datetime'     => $entry_obj->eventtime_mysql,
                                      'text'         => $event_text, });
 
        ${$opts->{'event'}} = $event;
    }

    if ($opts->{'event_friend'}) {       
        my $event_text = $original_entry_obj->event_html;
        my $journal = $original_entry_obj->journal;
        
        my $text_var = $journal->is_community ? 'entry.reference.friends.community' :
                                                'entry.reference.friends.journal';
         
        my $event = LJ::Lang::ml($text_var, 
                                   { 'author'       => LJ::ljuser2($original_entry_obj->poster),
                                     'community'    => LJ::ljuser2($original_entry_obj->journal->user),
                                     'reposter'     => LJ::ljuser2($entry_obj->poster),
                                     'text'         => $event_text, });

        ${$opts->{'event_friend'}} = $event;
    }

    if ($opts->{'subject_repost'}) {
        my $subject_text = $original_entry_obj->subject_html;
        my $repost_text = LJ::Lang::ml('entry.reference.subject');
        $subject_text .= " ( $repost_text )";
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

1;
