package LJ::Comet::History;
use strict;
use LJ::Comet::HistoryRecord;
=head
CREATE TABLE comet_history (
     rec_id   integer unsigned unique auto_increment primary key,
     uid      integer unsigned not null,
     type     varchar(31),
     message  text,
     
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
    LJ::MemCache::delete("comet:history:" . $u->userid);

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
    my $class = shift;
    my $u     = shift;
    my $from  = int (shift);

    #
    my $ckey   = "comet:history:" . $u->userid;
    my $cached = LJ::MemCache::get($ckey);
warn "*********** BEFORE CACHE";
    return $cached if $cached and $cached->{messages}->[0]->{rec_id} eq $from;
warn "*********** AFTER CACHE";

    my @messages = ();
    my $dbcm = LJ::get_cluster_master($u);
    my $sth  = $dbcm->prepare("
        SELECT * 
        FROM   comet_history
        WHERE 
            rec_id > ?
            AND uid = ?
        LIMIT 51
        ") or die $dbcm->errstr;
    $sth->execute($from, $u->userid)
        or die "Can't get comet history from DB: user_id=" . $u->userid . " from=$from  Error:" . $dbcm->errstr;
    while (my $h = $sth->fetchrow_hashref){
        push @messages => $h;
    }

    #
    my $have_more = (scalar (@messages) > 50) ? 1 : 0;
    my $res = {
                messages  => [splice @messages, 0 => 50],
                have_more => $have_more,
                };
    LJ::MemCache::set($ckey, $res);
    return $res;

}

sub jsoned_log {
    my $class = shift;
    my $res   = $class->log(@_);
    require JSON;
    return JSON::objToJson($res);
}

1;

