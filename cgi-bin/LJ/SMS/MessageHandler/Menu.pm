package LJ::SMS::MessageHandler::Menu;

use base qw(LJ::SMS::MessageHandler);

use strict;
use Carp qw(croak);

sub handle {
    my ($class, $msg) = @_;

    my $resp = eval { $msg->respond
                          ("Avail.cmnds: (P)OST, (F)RIENDS, (R)EAD, (A)DD, I LIKE, HELP. " .
                           "E.g. to read username frank send \"READ frank\". STOP2stop, " .
                           "HELP4help. $LJ::SMS_DISCLAIMER");
                      };

    # FIXME: do we set error status on $resp?

    # mark the requesting (source) message as processed
    $msg->status($@ ? ('error' => $@) : 'success');
}

sub owns {
    my ($class, $msg) = @_;
    croak "invalid message passed to MessageHandler"
        unless $msg && $msg->isa("LJ::SMS::Message");

    return $msg->body_text =~ /^\s*m(?:enu)?\s*$/i ? 1 : 0;
}

1;
