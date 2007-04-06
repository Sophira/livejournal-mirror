#!/usr/bin/perl

use strict;
use lib "$ENV{FBHOME}/lib";

package FB::Singleton;

# Usage:
#    my $singleton = new FB::Singleton('SecGroup');
#    my $rv        = $singleton->set("$userid-$secid" => $secobj);
#    my $obj       = $singleton->get("$userid-$secid");
#    my %href      = $singleton->get_all;
#    my $rv        = $singleton->reset;

use Carp qw(croak);

use vars   qw(%OBJ);
use fields qw(type elem);

sub new {
    my FB::Singleton $self = shift;
    my ($type, $opts) = @_;

    # establish new or existing object
    $OBJ{$type} = fields::new($self)
        unless ref $OBJ{$type};

    # get self from singleton hash
    $self = $OBJ{$type};

    # type is fixed
    $self->{type} = $type;

    # do we need to reset the single 'elem' member before returning?
    $self->reset if $opts->{reset} || ! ref $self->{elem};

    return $self;
}

sub type {
    my FB::Singleton $self = shift;

    return $self->{type};
}

sub set {
    my FB::Singleton $self = shift;
    my ($key, $val) = @_;

    return $self->{elem}->{$key} = $val;
}

sub delete {
    my FB::Singleton $self = shift;
    my $key = shift;

    return delete $self->{elem}->{$key};
}

sub get {
    my FB::Singleton $self = shift;
    my $key = shift;

    return $self->{elem}->{$key};
}

sub get_all {
    my FB::Singleton $self = shift;

    return values %{$self->{elem}};
}

sub reset {
    my FB::Singleton $self = shift;
    my $key = shift;

    return $self->{elem} = {};
}

###############################################################################
# Class Methods
#

# reset all singleton types

sub reset_all {
    my $class = shift;
    croak "reset_all is a class method" if ref $class;

    $_->reset foreach values %OBJ;

    return 1;
}

1;
