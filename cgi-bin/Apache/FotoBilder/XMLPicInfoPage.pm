#!/usr/bin/perl
#

package Apache::FotoBilder::XMLPicInfoPage;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED);

sub handler {
    my $r = shift;
    my $uri = $r->uri;

    my $uri_components = FB::decode_picture_uri($uri);
    my $user = $uri_components->{'user'};
    my $upicid = $uri_components->{'upicid'};
    my $auth = $uri_components->{'auth'};
    my $separator = $uri_components->{'separator'};
    my $extra = $uri_components->{'extra'};
    my $extension = $uri_components->{'extension'};

    # load user
    $user = $FB::ROOT_USER unless defined $user;
    return 404 unless defined $user;
    my $u = FB::load_user($user, undef, { validate=>1 });
    return 404 if ! $u || $u->{statusvis} =~ /[DX]/;
    return 403 if $u->{statusvis} eq 'S';

    $upicid = FB::b28_decode($upicid);
    $auth   = FB::b28_decode($auth);

    # load pic
    my $up = FB::Upic->new($u, $upicid);
    return 404 unless $up && $up->valid;
    return 404 unless $auth == $up->randauth % (28**3);

    # all is cool, we're outputting XML
    $r->content_type("text/xml");
    $r->send_http_header();

    my $xml = '<?xml version="1.0"?>';
    $xml .= $up->info_xml();

    $r->print($xml);

    return OK;
}

1;
