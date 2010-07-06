package LJ::Identity::OpenID;
use strict;

use base qw(LJ::Identity);

sub typeid { 'O' }
sub pretty_type { 'OpenID' }
sub short_code { 'openid' }

sub url {
    my ($self) = @_;
    return $self->value;
}

1;
