package LJ::Comet::HistoryRecord;
use strict;
use base qw(Class::Accessor::Fast);
use JSON;
use constant FIELDS => qw/rec_id uid type message added/;
__PACKAGE__->mk_accessors(FIELDS);

sub serialize {
    my $self = shift;
    my $res  = {};
    foreach my $field (FIELDS){
        $res->{$field} = $self->{$field};
    }

use Data::Dumper;
warn "SELF: " . Dumper( $self );
warn "RES: " .  Dumper( $res );
warn "JSON : " . JSON::objToJson($res);
    return JSON::objToJson($res);
}

1;

