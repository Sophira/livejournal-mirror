package LJ::User::UserlogRecord::FriendInviteSent;
use strict;
use warnings;

use base qw( LJ::User::UserlogRecord );

sub action {'friend_invite_sent'}
sub group  {'relations'}

sub translate_create_data {
    my ( $class, %data ) = @_;

    $data{'extra'} = { 'extra' => delete $data{'recipient'} };

    return %data;
}

sub description {
    my ($self) = @_;

    my $extra     = $self->extra_unpacked;
    my $recipient = $extra->{'extra'};

    return LJ::Lang::ml( 'userlog.action.invite.sent', { recipient => $recipient } );
}

1;
