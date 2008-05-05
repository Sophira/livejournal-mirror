package LJ::NotificationMethod::ICQ;

use strict;
use Carp qw/ croak /;
use base 'LJ::NotificationMethod';
use LJ::User;

sub can_digest { 0 };

# takes a $u
sub new {
    my $class = shift;

    croak "no args passed"
        unless @_;

    my $u = shift;
    croak "invalid user object passed"
        unless LJ::isu($u);

    my $self = { u => $u };

    return bless $self, $class;
}

sub title { 'ICQ' }

sub new_from_subscription {
    my $class = shift;
    my $subs = shift;

    return $class->new($subs->owner);
}

sub u {
    my $self = shift;
    croak "'u' is an object method"
        unless ref $self eq __PACKAGE__;

    if (my $u = shift) {
        croak "invalid 'u' passed to setter"
            unless LJ::isu($u);

        $self->{u} = $u;
    }

    croak "superfluous extra parameters"
        if @_;

    return $self->{u};
}

# send IMs for events passed in
sub notify {
    my $self = shift;
    croak "'notify' is an object method"
        unless ref $self eq __PACKAGE__;

    my $u = $self->u;
    
    my @events = @_;
    croak "'notify' requires one or more events"
        unless @events;

    foreach my $ev (@events) {
        croak "invalid event passed" unless ref $ev;
        my $msg = $ev->as_im($u);
        $u->send_icq(
            message => $msg,
        );
    }

    return 1;
}

sub configured {
    my $class = shift;

    # FIXME: check if jabber server is configured
    return 1;
}

sub configured_for_user {
    my $class = shift;
    my $u = shift;    
    return length $u->prop('icq') && $u->prop('icq_verified');    
}

sub url {
    my $class = shift;

    return LJ::run_hook('jabber_link');
}

1;
