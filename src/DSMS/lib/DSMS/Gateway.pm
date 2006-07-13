#!/usr/bin/perl

# DSMS Gateway object
#
# internal fields:
#
#    config     hashref of config key/value pairs
#    

package DSMS::Gateway;

use strict;
use Carp qw(croak);

sub new {
    my $class = shift;
    my $self  = {};

    my %args  = @_;

    foreach (qw(config)) {
        $self->{$_} = delete $args{$_};
    }
    croak "invalid parameters: " . join(",", keys %args)
        if %args;

    # $self->{config} is opaque

    return bless $self, $class;
}

sub config {
    my $self = shift;
    croak "config is an object method"
        unless ref $self;

    my $key = shift;
    croak "no config key specified for retrieval"
        unless length $key;

    die "config key '$key' does not exist"
        unless exists $self->{config}->{$key};

    return $self->{config}->{$key};
}

sub send_msg {
    my $self = shift;
    croak "send_msg is an object method"
        unless ref $self;

    warn "DUMMY: send_msg";

    return 1;
}

sub recv_msg {
    my $self = shift;
    croak "recv_sms is an object method"
        unless ref $self;

    warn "DUMMY: recv_sms";

    return 1;
}

1;
