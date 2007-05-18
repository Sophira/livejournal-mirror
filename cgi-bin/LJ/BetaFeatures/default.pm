package LJ::BetaFeatures::default;

use strict;
use Carp qw(croak);

#
# base class implementations, can all be overridden
#

sub new {
    my $class = shift;
    my $key   = shift;

    my $self = {
        key => $key,
    };

    return bless $self, $class;
}

sub key {
    my $self = shift;
    return $self->{key};
}

sub conf {
    my $self = shift;

    my $key  = $self->key;
    my $conf = $LJ::BETA_FEATURES{$key};
    return {} unless ref $conf eq 'HASH';
    return $conf;
}

sub remote_can_add {
    my $self = shift;

    my $remote = LJ::get_remote();
    return $self->user_can_add($remote);
}

sub user_can_add {
    my $self = shift;
    my $u     = shift;

    return 0 unless $u;
    return 1;
}

sub is_active {
    my $self = shift;

    my $conf = $self->conf;
    return 0 unless $conf;

    return 0 unless $self->is_started;
    return 0 if $self->is_expired;

    return 1;
}

# are we after the start time?
sub is_started {
    my $self = shift;

    my $conf = $self->conf;
    return 0 unless $conf;

    my $now = time();
    return 1 if ! exists $conf->{start_time};
    return 1 if $conf->{start_time} <= $now;
    return 0;
}

# are we after the end time?
sub is_expired {
    my $self = shift;

    my $conf = $self->conf;
    return 0 unless $conf;

    my $now = time();
    return 0 if ! exists $conf->{end_time};
    return 0 if $conf->{end_time} > $now;
    return 1;
}

1;
