package LJ::Comet::History;
use strict;
use LJ::Comet::HistoryRecord;
=head
CREATE TABLE comet_history (
     rec_id   integer unsigned unique auto_increment primary key,
     uid      integer unsigned not null,
     type     varchar(31),
     message  text,
     status   char(1), -- (N)ew, (R)eaded
     added    datetime,

     INDEX(uid)
);
=cut

sub add {
    my $class = shift;
    my %args  = @_;

    my $type  = $args{type}
        or die "Message type does not provided";
    my $msg   = $args{msg}
        or die "No message text";
    my $u     = $args{u}
        or die "User does not provided";
    
    die "Unknown message type"
        unless grep {$_ eq $type} qw/alert message post comment/;
    
    my $dbcm = LJ::get_cluster_master($u);
    $dbcm->do("
        INSERT INTO comet_history
            (uid, type, message, added)
            VALUES
            (?,?,?,NOW())
        ", undef,
        $u->userid, $type, $msg
        ) or die "Can't add message to db: " . $dbcm->errstr;
    LJ::MemCache::delete("comet:history:" . $u->userid . ":$type");

    my ($rec_id) = $dbcm->selectrow_array("SELECT LAST_INSERT_ID()");
    return 
        LJ::Comet::HistoryRecord->new({ 
            rec_id  => $rec_id,
            type    => $type,
            message => $msg,
            uid     => $u->userid,
            });
}

sub log {
    my $class  = shift;
    my $u      = shift;
    my $type   = shift;
    my $status = shift || 'N';

    die "Unknown message type"
        unless grep {$_ eq $type} qw/alert message post comment/;

    die "Unknown status"
        unless $status =~ m/^N|R\z/;

    #
    my $ckey   = "comet:history:" . $u->userid . ":$type";
    my $cached = LJ::MemCache::get($ckey);
    return $cached if $cached;

    my @messages = ();
    my $dbcm = LJ::get_cluster_master($u);
    my $sth  = $dbcm->prepare("
        SELECT * 
        FROM   comet_history
        WHERE  
            uid = ?
            AND type = ?
            AND status = ?
        LIMIT 51
        ") or die $dbcm->errstr;
    $sth->execute($u->userid, $type, $status)
        or die "Can't get comet history from DB: user_id=" . $u->userid . "  Error:" . $dbcm->errstr;
    while (my $h = $sth->fetchrow_hashref){
        push @messages => $h;
    }

    #
    my $have_more = (scalar (@messages) > 50) ? 1 : 0;
    my $res = {
                messages  => [splice @messages, 0 => 50],
                have_more => $have_more,
                };
    LJ::MemCache::set($ckey, $res, $LJ::COMET_HISTORY_LIFETIME);
    return $res;

}

sub jsoned_log {
    my $class = shift;
    my $res   = $class->log(@_);
    require JSON;
    return JSON::objToJson($res);
}


sub mark_as_readed {
    my $class = shift;
    my $u     = shift;
    my $to    = shift;
    my $type  = shift;

    die "Unknown message type"
        unless grep {$_ eq $type} qw/alert message post comment/;

    # 1. update db
    my $dbcm = LJ::get_cluster_master($u);
    $dbcm->do("
        UPDATE comet_history
        SET status='R'
        WHERE 
            rec_id  <= ?
            AND uid  = ?
            AND type = ?
        ", undef,
        $u->userid, $to, $type
        ) or die "Can't mark comet_history records as readed: " . $dbcm->errstr;


    # 2. invalidate cached data
    my $ckey   = "comet:history:" . $u->userid . ":$type";
    LJ::MemCache::delete($ckey);
    
    return 1;
}

sub remove_outdated {
    my $class = shift;

    foreach my $cid (@LJ::CLUSTERS){
        my $dbcw = LJ::get_cluster_master($cid);
        die "Unable to get cluster writer for cluster $cid" unless $dbcw;

        $dbcw->do("
            DELETE FROM comet_history
            WHERE added < FROM_UNIXTIME(?)
            ", undef,
            (time - $LJ::COMET_HISTORY_LIFETIME)
            ) or die "Could not remove outdated records from 'comet_history': " . $dbcw->errstr;
warn "after delete... cluster: $cid";
    }
    return 1;
}

1;

