#!/usr/bin/perl
#

use strict;

use lib "$ENV{LJHOME}/cgi-bin";
require "ljlib.pl";

package LJ;

use Text::Wrap ();
use Time::HiRes qw//;

use Encode qw//;
use MIME::Base64 qw//;

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

use MIME::Words qw//;

# <LJFUNC>
# name: LJ::send_mail
# des: Sends email.  Character set will only be used if message is not ASCII.
# args: opt, async_caller
# des-opt: Hashref of arguments.  Required: to, from, subject, body.
#          Optional: toname, fromname, cc, bcc, charset, wrap, html.
#          All text must be in UTF-8 (without UTF flag, as usual in LJ code).
#          Body and subject are converted to recipient-user mail encoding.
#          Subject line is encoded according to RFC 2047.
#          Warning: opt can be a MIME::Lite ref instead, in which
#          case it is sent as-is.
# </LJFUNC>
sub send_mail
{
    my $opt = shift;
    my $async_caller = shift;

    init();

    my ($message_text, $from, @rcpts, $subject, $action);
    
    if (ref $opt eq 'MIME::Lite') {
        # did they pass a MIME::Lite object already?
        $message_text = $opt->as_string;
        $from = (map { $_->address } Mail::Address->parse($opt->get('From')))[0];
        foreach my $header (map { $opt->get($_) } qw(To Cc Bcc)) {
            next unless $header;
            push @rcpts, map { $_->address } Mail::Address->parse($header);
        }
        $subject = $opt->get('Subject');
        $action = 'email_send_mimelite';
    } elsif ($opt->{raw_data}) {
        $message_text = $opt->{raw_data};
        $from = (map { $_->address } Mail::Address->parse($opt->{from}))[0];
        foreach my $header (map { $opt->{$_} } qw(To Cc Bcc)) {
            next unless $header;
            push @rcpts, map { $_->address } Mail::Address->parse($header);
        }
        $subject = "Unknown (raw message)";
        $action = 'email_send_raw';
    } else {
        my $clean_name = sub {
            my ($name, $email) = @_;
            return $email unless $name;
            $name =~ s/[\n\t\"<>]//g;
            return $name ? "\"$name\" <$email>" : $email;
        };

        my $body = $opt->{'wrap'} ? Text::Wrap::wrap('','',$opt->{'body'}) : $opt->{'body'};
        my $subject = $opt->{'subject'};
        my $fromname = $opt->{'fromname'};

        # if it's not ascii, add a charset header to either what we were explictly told
        # it is (for instance, if the caller transcoded it), or else we assume it's utf-8.
        # Note: explicit us-ascii default charset suggested by RFC2854 sec 6.
        $opt->{'charset'} ||= "utf-8";
        my $charset;
        if (!LJ::is_ascii($subject)
         || !LJ::is_ascii($body)
         || ($opt->{html} && !LJ::is_ascii($opt->{html}))
         || !LJ::is_ascii($fromname)) {
            $charset = $opt->{'charset'};
        } else {
            $charset = 'us-ascii';
        }

        # Don't convert from us-ascii and utf-8 charsets.
        unless (($charset =~ m/us-ascii/i) || ($charset =~ m/^utf-8$/i)) {
            Encode::from_to($body,              "utf-8", $charset);
            # Convert also html-part if we has it.
            if ($opt->{html}) {
                Encode::from_to($opt->{html},   "utf-8", $charset);
            }
        }

        Encode::from_to($subject, "utf-8", $charset) unless $charset =~ m/^utf-8$/i;
        if (!LJ::is_ascii($subject)) {
            $subject = MIME::Words::encode_mimeword($subject, 'B', $charset);
        }

        Encode::from_to($fromname, "utf-8", $charset) unless $charset =~ m/^utf-8$/i;
        if (!LJ::is_ascii($fromname)) {
            $fromname = MIME::Words::encode_mimeword($fromname, 'B', $charset);
        }
        $fromname = $clean_name->($fromname, $opt->{'from'});

        my $msg;
        if ($opt->{html}) {
            # do multipart, with plain and HTML parts

            $msg = new MIME::Lite ('From'    => $fromname,
                                   'To'      => $clean_name->($opt->{'toname'},   $opt->{'to'}),
                                   'Cc'      => $opt->{'cc'},
                                   'Bcc'     => $opt->{'bcc'},
                                   'Subject' => $subject,
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
            $msg = new MIME::Lite ('From'    => $fromname,
                                   'To'      => $clean_name->($opt->{'toname'},   $opt->{'to'}),
                                   'Cc'      => $opt->{'cc'},
                                   'Bcc'     => $opt->{'bcc'},
                                   'Subject' => $subject,
                                   'Type'    => 'text/plain',
                                   'Data'    => $body);

            $msg->attr("content-type.charset" => $charset);
        }

        if ($opt->{headers}) {
            while (my ($tag, $value) = each %{$opt->{headers}}) {
                $msg->add($tag, $value);
            }
        }
        
        $message_text = $msg->as_string;
        $from = (map { $_->address } Mail::Address->parse($msg->get("From")))[0];
        foreach my $header (map { $msg->get($_) } qw(To Cc Bcc)) {
            next unless $header;
            push @rcpts, map { $_->address } Mail::Address->parse($header);
        }
        $subject = $msg->get('Subject');
        $action = ($opt->{html}) ? 'email_send_html' : 'email_send_text';
    }

    LJ::note_recent_action(undef, $action);
 
    my $enqueue = sub {
        my $starttime = [Time::HiRes::gettimeofday()];
        my $sclient = LJ::theschwartz() or die "Misconfiguration in mail.  Can't go into TheSchwartz.";
        my $host;
        if (@rcpts == 1) {
            $rcpts[0] =~ /(.+)@(.+)$/;
            $host = lc($2) . '@' . lc($1);   # we store it reversed in database
        }
        my $job = TheSchwartz::Job->new(funcname => "TheSchwartz::Worker::SendEmail",
                                        arg      => {
                                            env_from => $from,
                                            rcpts    => \@rcpts,
                                            data     => $message_text,
                                        },
                                        coalesce => $host,
                                        );
        my $h = $sclient->insert($job);

        LJ::blocking_report( 'the_schwartz', 'send_mail',
                             Time::HiRes::tv_interval($starttime));

        return $h ? 1 : 0;
    };

    if ($LJ::MAIL_TO_THESCHWARTZ || ($LJ::MAIL_SOMETIMES_TO_THESCHWARTZ && $LJ::MAIL_SOMETIMES_TO_THESCHWARTZ->())) {
        return $enqueue->();
    }

    return $enqueue->() if $LJ::ASYNC_MAIL && ! $async_caller;

    my $starttime = [Time::HiRes::gettimeofday()];
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
            my $len = length($message_text);
            $LJ::DMTP_SOCK->print("Content-Length: $len\r\n" .
                                  "Envelope-Sender: $from\r\n\r\n$message_text");
            my $ok = $LJ::DMTP_SOCK->getline;
            $rv = ($ok =~ /^OK/);
        }
    } else {
        # SMTP or sendmail case. Dev servers only I hope. Code is taken from MIME::Lite->send
        open( my $fh, "| /usr/lib/sendmail -t -oi -oem -f '$from'") 
            or die "Can't run sendmail: $!";
        print $fh $message_text;
        close $fh;
        $rv = 1;
    }

    unless ($async_caller) {
        my $notes = sprintf( "Direct mail send to %s %s: %s", $from, ($rv) ? "succeeded" : "failed", $subject);
        LJ::blocking_report( $LJ::SMTP_SERVER || $LJ::SENDMAIL, 'send_mail',
                             Time::HiRes::tv_interval($starttime), $notes );
    }

    return 1 if $rv;
    return 0 if $@ =~ /no data in this part/;  # encoding conversion error higher
    return $enqueue->() unless $opt->{'no_buffer'};
    return 0;
}

1;
