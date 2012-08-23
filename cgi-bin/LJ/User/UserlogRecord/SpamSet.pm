package LJ::User::UserlogRecord::SpamSet;
use strict;
use warnings;

use base qw( LJ::User::UserlogRecord );

sub action {'spam_set'}

sub translate_create_data {
    my ( $class, %data ) = @_;

    $data{'actiontarget'} = delete $data{'spammerid'};

    return %data;
}

sub description {
    my ($self) = @_;

    my $targetuserid = $self->actiontarget;
    if ( my $targetu = LJ::load_userid($targetuserid) ) {
        return 'Marked ' . $targetu->ljuser_display . ' as spammer';
    }

    return "Marked a bogus user ($targetuserid) as spammer";
}

1;
