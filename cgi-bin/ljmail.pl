#!/usr/bin/perl
#

use strict;

use lib "$ENV{LJHOME}/cgi-bin";
require "ljlib.pl";

package LJ;

use Text::Wrap ();
use Time::HiRes ('gettimeofday', 'tv_interval');

use Class::Autouse qw(
                      IO::Socket::INET
                      MIME::Lite
                      Mail::Address
                      );

my $done_init = 0;
sub init {
    return if $done_init++;
    if ($LJ::SMTP_SERVER) {
        # determine how we're going to send mail
        $LJ::OPTMOD_NETSMTP = eval "use Net::SMTP (); 1;";
        die "Net::SMTP not installed\n" unless $LJ::OPTMOD_NETSMTP;
        MIME::Lite->send('smtp', $LJ::SMTP_SERVER, Timeout => 10);
    } else {
        MIME::Lite->send('sendmail', $LJ::SENDMAIL);
    }
}

# <LJFUNC>
# name: LJ::send_mail
# des: Sends email.  Character set will only be used if message is not ascii.
# args: opt[, async_caller]
# des-opt: Hashref of arguments.  <b>Required:</b> to, from, subject, body.
#          <b>Optional:</b> toname, fromname, cc, bcc, charset, wrap, html.
#          <b>Note:</b> charset covers body parts only (FIXME - RFC2047)
#          <b>Warning:</b> opt can be a MIME::Lite ref instead, in which
#          case it is sent as-is.
# </LJFUNC>
sub send_mail
{
    my $opt = shift;
    my $async_caller = shift;

    init();

    my $msg = $opt;

    # did they pass a MIME::Lite object already?
    unless (ref $msg eq 'MIME::Lite') {

        my $clean_name = sub {
            my ($name, $email) = @_;
            return $email unless $name;
            $name =~ s/[\n\t\"<>]//g;
            return $name ? "\"$name\" <$email>" : $email;
        };

        my $body = $opt->{'wrap'} ? Text::Wrap::wrap('','',$opt->{'body'}) : $opt->{'body'};

        # if it's not ascii, add a charset header to either what we were explictly told
        # it is (for instance, if the caller transcoded it), or else we assume it's utf-8.
        # Note: explicit us-ascii default charset suggested by RFC2854 sec 6.
        # FIXME: subject charset needs different handling per RFC2047, not done
        # here yet to avoid double encoding.

        $opt->{'charset'} ||= "utf-8";
        my $charset = LJ::is_ascii($opt->{'body'}) ? 'us-ascii' : $opt->{'charset'};

        if ($opt->{html}) {
            # do multipart, with plain and HTML parts

            $msg = new MIME::Lite ('From'    => $clean_name->($opt->{'fromname'}, $opt->{'from'}),
                                   'To'      => $clean_name->($opt->{'toname'},   $opt->{'to'}),
                                   'Cc'      => $opt->{'cc'},
                                   'Bcc'     => $opt->{'bcc'},
                                   'Subject' => $opt->{'subject'},
                                   'Type'    => 'multipart/alternative');

            # add the plaintext version
            my $plain = $msg->attach(
                                     'Type'     => 'text/plain',
                                     'Data'     => "$body\n",
                                     'Encoding' => 'quoted-printable',
                                     );
            $plain->attr("content-type.charset" => $charset);

            # add the html version
            my $html = $msg->attach(
                                    'Type'     => 'text/html',
                                    'Data'     => $opt->{html},
                                    'Encoding' => 'quoted-printable',
                                    );
            $html->attr("content-type.charset" => $charset);

        } else {
            # no html version, do simple email
            $msg = new MIME::Lite ('From'    => $clean_name->($opt->{'fromname'}, $opt->{'from'}),
                                   'To'      => $clean_name->($opt->{'toname'},   $opt->{'to'}),
                                   'Cc'      => $opt->{'cc'},
                                   'Bcc'     => $opt->{'bcc'},
                                   'Subject' => $opt->{'subject'},
                                   'Type'    => 'text/plain',
                                   'Data'    => $body);

            $msg->attr("content-type.charset" => $charset);
        }

        if ($opt->{headers}) {
            while (my ($tag, $value) = each %{$opt->{headers}}) {
                $msg->add($tag, $value);
            }
        }

    }

    # at this point $msg is a MIME::Lite

    # note that we sent an email
    LJ::note_recent_action(undef, $msg->get('Type') =~ /plain/i ? 'email_send_text' : 'email_send_html');

    my $enqueue = sub {
        my $starttime = [gettimeofday()];
        my $sclient = LJ::theschwartz() or die "Misconfiguration in mail.  Can't go into TheSchwartz.";
        my ($env_from) = map { $_->address } Mail::Address->parse($msg->get('From'));
        my @rcpts;
        push @rcpts, map { $_->address } Mail::Address->parse($msg->get($_)) foreach (qw(To Cc Bcc));
        my $host;
        if (@rcpts == 1) {
            $rcpts[0] =~ /(.+)@(.+)$/;
            $host = lc($2) . '@' . lc($1);   # we store it reversed in database
        }
        my $job = TheSchwartz::Job->new(funcname => "TheSchwartz::Worker::SendEmail",
                                        arg      => {
                                            env_from => $env_from,
                                            rcpts    => \@rcpts,
                                            data     => $msg->as_string,
                                        },
                                        coalesce => $host,
                                        );
        my $h = $sclient->insert($job);

        LJ::blocking_report( 'the_schwartz', 'send_mail',
                             tv_interval($starttime));

        return $h ? 1 : 0;
    };

    if ($LJ::MAIL_TO_THESCHWARTZ || ($LJ::MAIL_SOMETIMES_TO_THESCHWARTZ && $LJ::MAIL_SOMETIMES_TO_THESCHWARTZ->($msg))) {
        return $enqueue->();
    }


    return $enqueue->() if $LJ::ASYNC_MAIL && ! $async_caller;

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
    return $enqueue->() unless $opt->{'no_buffer'};
    return 0;
}



1;


