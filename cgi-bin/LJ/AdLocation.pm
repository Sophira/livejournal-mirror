package LJ::AdLocation;

use strict;
use Carp qw(croak);

# ident: top, bottom, left, right (for now)

sub new {
    my $class = shift;
    my %opts = @_;

    my $self = bless { 
        ident => $opts{ident},
        page  => $opts{page},
    }, $class;

    croak "invalid ad location: $self->{ident}"
        unless $self->is_valid_location;

    return $self;
}

sub is_valid_location {
    my $self = shift;
    
    return (grep { $self->ident eq $_ } qw(top bottom left right)) ? 1 : 0;
}

sub ident {
    my $self = shift;
    return $self->{ident};
}

1;
