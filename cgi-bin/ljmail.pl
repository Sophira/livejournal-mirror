#!/usr/bin/perl
#

use strict;

require "$ENV{LJHOME}/cgi-bin/ljlib.pl";

package LJ;

use MIME::Lite ();
use Text::Wrap ();
use Time::HiRes ('gettimeofday', 'tv_interval');
use IO::Socket::INET ();

# determine how we're going to send mail
$LJ::OPTMOD_NETSMTP = eval "use Net::SMTP (); 1;";

if ($LJ::SMTP_SERVER) {
    die "Net::SMTP not installed\n" unless $LJ::OPTMOD_NETSMTP;
    MIME::Lite->send('smtp', $LJ::SMTP_SERVER, Timeout => 10);
} else {
    MIME::Lite->send('sendmail', $LJ::SENDMAIL);
}

# <LJFUNC>
# name: LJ::send_mail
# des: Sends email.  Character set will only be used if message is not ascii.
# args: opt[, async_caller]
# des-opt: Hashref of arguments.  <b>Required:</b> to, from, subject, body.
#          <b>Optional:</b> toname, fromname, cc, bcc, charset, wrap
# </LJFUNC>
sub send_mail
{
    my $opt = shift;
    my $async_caller = shift;

    my $msg = $opt;

    # did they pass a MIME::Lite object already?
    unless (ref $msg eq 'MIME::Lite') {

        my $clean_name = sub {
            my $name = shift;
            return "" unless $name;
            $name =~ s/[\n\t\(\)]//g;
            return $name ? " ($name)" : "";
        };

        my $body = $opt->{'wrap'} ? Text::Wrap::wrap('','',$opt->{'body'}) : $opt->{'body'};
        $msg = new MIME::Lite ('From' => "$opt->{'from'}" . $clean_name->($opt->{'fromname'}),
                                  'To' => "$opt->{'to'}" . $clean_name->($opt->{'toname'}),
                                  'Cc' => $opt->{'cc'},
                                  'Bcc' => $opt->{'bcc'},
                                  'Subject' => $opt->{'subject'},
                                  'Data' => $body);

        if ($opt->{'charset'} && ! (LJ::is_ascii($opt->{'body'}) && LJ::is_ascii($opt->{'subject'}))) {
            $msg->attr("content-type.charset" => $opt->{'charset'});
        }

        if ($opt->{'headers'}) {
            $msg->add(%{$opt->{'headers'}});
        }
    }

    # if send operation fails, buffer and send later
    my $buffer = sub {
        my $starttime = [gettimeofday()];

        # try this on each cluster
        my $frozen = Storable::freeze($msg);
        my $rval = LJ::do_to_cluster(sub {
            # first parameter is cluster id
            return LJ::cmd_buffer_add(shift(@_), 0, 'send_mail', $frozen);
        });
        return undef unless $rval;

        my $notes = sprintf( "Queued mail send to %s %s: %s",
                             $msg->get('to'),
                             $rval ? "succeeded" : "failed",
                             $msg->get('subject') );
        LJ::blocking_report( $LJ::SMTP_SERVER || $LJ::SENDMAIL, 'send_mail',
                             tv_interval($starttime), $notes );

        $rval; # return
    };

    return $buffer->($msg) if $LJ::ASYNC_MAIL && ! $async_caller;

    my $starttime = [gettimeofday()];
    my $rv;
    if ($LJ::DMTP_SERVER) {
        my $host = $LJ::DMTP_SERVER;
        unless ($host =~ /:/) {
            $host .= ":7005";
        }
        # DMTP (Danga Mail Transfer Protocol)
        $LJ::DMTP_SOCK ||= IO::Socket::INET->new(PeerAddr => $host,
                                                 Proto    => 'tcp');
        if ($LJ::DMTP_SOCK) {
            my $as = $msg->as_string;
            my $len = length($as);
            my $env = $opt->{'from'};
            $LJ::DMTP_SOCK->print("Content-Length: $len\r\n" .
                                  "Envelope-Sender: $env\r\n\r\n$as");
            my $ok = $LJ::DMTP_SOCK->getline;
            $rv = ($ok =~ /^OK/);
        }
    } else {
        # SMTP or sendmail case
        $rv = eval { $msg->send && 1; };
    }
    my $notes = sprintf( "Direct mail send to %s %s: %s",
                         $msg->get('to'),
                         $rv ? "succeeded" : "failed",
                         $msg->get('subject') );

    unless ($async_caller) {
	LJ::blocking_report( $LJ::SMTP_SERVER || $LJ::SENDMAIL, 'send_mail',
			     tv_interval($starttime), $notes );
    }

    return 1 if $rv;
    return 0 if $@ =~ /no data in this part/;  # encoding conversion error higher
    return $buffer->($msg);

}

package MIME::Lite;

# A version of MIME::Lite::send_by_smtp that speaks proper SMTP
#   -- Brad
sub send_by_smtp {
    my ($self, @args) = @_;

    ### We need the "From:" and "To:" headers to pass to the SMTP mailer:
    my $hdr  = $self->fields();
    my $from = $self->get('From');
    my $to   = $self->get('To');

    # <DANGA>
    # extract just the email from the From field, if there is one.
    # A null sender <> is permitted.
    # A bug report has been sent upstream.  This is an interim fix.
    if ($from) {
        $from = (Mail::Address->parse($from))[0]->address
            or Carp::croak "send_by_smtp: invalud 'From:' address\n";
    }
    # </DANGA>

    ### Sanity check:
    defined($to) or Carp::croak "send_by_smtp: missing 'To:' address\n";

    # <DANGA>
    ### Get the destinations as a simple array of addresses:
    my @to_all = map { $_->address } Mail::Address->parse($to);
    if ($AUTO_CC) {
	foreach my $field (qw(Cc Bcc)) {
	    my $value = $self->get($field);
            next unless defined $value;
	    push @to_all, map { $_->address } Mail::Address->parse($value);
	}
    }
    # </DANGA>

    ### Create SMTP client:
    require Net::SMTP;
    my $smtp = MIME::Lite::SMTP->new(@args)
        or Carp::croak("Failed to connect to mail server: $!\n");
    $smtp->mail($from)
        or Carp::croak("SMTP MAIL command failed: $!\n".$smtp->message."\n");
    $smtp->to(@to_all)
        or Carp::croak("SMTP RCPT command failed: $!\n".$smtp->message."\n");
    $smtp->data()
        or Carp::croak("SMTP DATA command failed: $!\n".$smtp->message."\n");

    ### MIME::Lite can print() to anything with a print() method:
    $self->print_for_smtp($smtp);
    $smtp->dataend();
    $smtp->quit;
    1;
}



1;


