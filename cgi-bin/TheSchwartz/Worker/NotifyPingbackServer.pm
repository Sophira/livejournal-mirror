package TheSchwartz::Worker::NotifyPingbackServer;
use strict;
use base 'TheSchwartz::Worker';
use LWP::UserAgent qw();
use HTTP::Request  qw();
use JSON;


sub work {
    my ($class, $job) = @_;
    my $args = $job->arg;
    my $client = $job->handle->client;
warn "start send ping...";
    my $res = eval {
        send_ping(uri  => $args->{uri},
                  text => $args->{text},
                  mode => $args->{mode},
                  );
    };
    $job->completed if $res;

}

sub send_ping {
    my %args = @_;

    my $uri  = $args{uri};
    my $text = $args{text};
    my $mode = $args{mode};
warn "   mode: $mode";
warn "   uri:  $uri";
    # TODO: move pingback's uri to config
    my $pb_server_uri = $LJ::PINGBACK->{uri};
#                            . ($LJ::PINGBACK->{uri} =~ m|/$| ? '' : '/')
#                            . 'ljping/';
warn "   pb server: $pb_server_uri";
    my $content = JSON::objToJson({ uri => $uri, text => $text, mode => $mode }) . "\r\n";

    my $headers = HTTP::Headers->new;
       $headers->header('Content-Length' => length $content);

    my $req = HTTP::Request->new('POST', $pb_server_uri, $headers, $content );

warn "REQ: " . $req->as_string;

    my $ua  = LWP::UserAgent->new;
    my $res = $ua->request($req);
warn "   response: " . $res->content;

    return 1 if $res->content eq 'OK';
    return 0;

}




1;
