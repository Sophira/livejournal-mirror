package LJ::NotificationMethod::SMS;

use strict;
use Carp qw/ croak /;
use base 'LJ::NotificationMethod';
use Class::Autouse qw(LJ::SMS);

sub can_digest { 0 };

sub new {
    my $class = shift;
    my $u = shift;
    croak "invalid user object passed"
        unless LJ::isu($u);

    my $self = { u => $u };

    return bless $self, $class;
}

sub title { 'SMS' }

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

# notify a single event
sub notify {
    my $self = shift;
    croak "'notify' is an object method"
        unless ref $self eq __PACKAGE__;

    my $u = $self->u;

    croak "'notify' requires an event"
        unless @_;

    my @events = @_;

    foreach my $ev (@events) {
        croak "invalid event passed" unless ref $ev;
        my $msg_txt = $ev->as_sms;

        my $msg = LJ::SMS::Message->new(
                                        owner => $u,
                                        to    => $u,
                                        type  => 'outgoing',
                                        body_text => $msg_txt,
                                        );

        $u->send_sms($msg);
    }

    return 1;
}

sub configured {
    my $class = shift;

    # FIXME: should probably have more checks
    return LJ::SMS->configured ? 1 : 0;
}

sub configured_for_user {
    my $class = shift;
    my $u = shift;

    return LJ::SMS->configured_for_user($u) ? 1 : 0;
}

1;
