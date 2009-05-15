package LJ::Friend::History;
use strict;

=head
create table friend_history (
    rec_id  integer unsigned unique auto_increment primary key,
    action  varchar(24),
    
    uid     integer unsigned not null,
    fid     integer unsigned not null,
    
    status  integer,
    added   datetime,
    
    INDEX(action)
);
=cut

sub add_record {
    my $class = shift;
    my %args  = @_;
    
    my $action = delete $args{action}
        or die "Unknown action";
    my $uid    = int delete $args{uid}
        or die "userid does not provided";
    my $fid    = int delete $args{fid}
        or die "friendid does not provided";
   
    my $dbh = LJ::get_db_writer();
    $dbh->do("
        INSERT INTO friend_history 
            (action, uid, fid, status, added)
            VALUES
            (?,?,?,?,NOW())
        ", undef,
        $action, $uid, $fid, "1"
        );

    die "Error adding record to friend_history: " . $dbh->err . " " . $dbh->errstr
        if $dbh->err;

    return 1;
}
sub log {
    my $class = shift;
    my %args  = @_;

    my $from  = int(delete $args{from}); # 0 is ok
    my $to    = int(delete $args{to}) || 100;

    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("
        SElECT *, UNIX_TIMESTAMP(added) as added 
        FROM friend_history
        WHERE
            rec_id >= ?
            AND rec_id <= ?
        ORDER BY
            rec_id asc
    ");
    $sth->execute($from, $to);
    
    my @res = ();
    while (my $h = $sth->fetchrow_hashref){
        push @res => $h;
    }

    return @res;
}



1;
