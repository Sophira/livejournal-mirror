package LJ::NotificationMethod::Alerts;

use strict;
use Carp qw/ croak /;
use base 'LJ::NotificationMethod';
use LJ::User;
use LWP::UserAgent qw//;
use LJ::Comet::History qw//;

sub can_digest { 1 };

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

sub title { BML::ml('notification_method.alerts.title') }

sub help_url { "alerts_full" }

sub new_from_subscription {
    my $class = shift;
    my $subs  = shift;

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

    return if $LJ::DISABLED{comet_alerts};

    my $u = $self->u;

    my @events = @_;
    croak "'notify' requires one or more events"
        unless @events;

    require JSON; # load serializer
    
    foreach my $ev (@events) {
        croak "invalid event passed" unless ref $ev;
        my $msg = $ev->as_alert($u);

        # send data to comet server
        my $rec = '';
        unless ($LJ::DISABLED{'log_comet_history'}){
            $rec = LJ::Comet::History->add(
                        u    => $u,
                        type => 'alert',
                        msg  => $msg,
                        );
            
        } else {
            # Do not save messages in comet history.
            # time() is used to set rec_id
            $rec = LJ::Comet::HistoryRecord->new({
                        rec_id  => time(),
                        uid     => $u->userid,
                        type    => "alert",
                        message => $msg,
                        added   => time(),
                        });
        }
        $self->_notify_alert($u, $rec->serialize);
    }

    return 1;
}

sub _notify_alert {
    my $self   = shift;
    my $u      = shift;
    my $msg    = shift;
    
    return unless $LJ::ALERTS_INTERFACE;

    # Create a user agent object
    my $ua = LWP::UserAgent->new;
       $ua->agent("MyApp/0.1 ");
       $ua->timeout(3);

    my $res = $ua->post($LJ::ALERTS_INTERFACE,
                        { 
                          UserId   => $u->userid,
                          Message  => $msg,
                          });

    warn "alert notify response: " . $res->code . " " . $res->content
        unless $res->is_success;

}




sub configured {
    my $class = shift;
    return 0 if $LJ::DISABLED{comet_alerts};
    return 1;
}

sub configured_for_user {
    my $class = shift;
    my $u = shift;

    # FIXME: check if user can use IM
    return $u->is_person ? 1 : 0;
}

sub url {
    my $class = shift;
    return '';
}

1;
