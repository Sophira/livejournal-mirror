#!/usr/bin/perl
#

package Apache::FotoBilder::XMLGalleryInfoPage;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED);

sub handler {
    my $r = shift;
    my $uri = $r->uri;

    my $uri_components = FB::decode_gallery_uri($uri);
    my $user = $uri_components->{'user'};
    my $gallid = $uri_components->{'gallid'};
    my $auth = $uri_components->{'auth'};
    my $eurl_tag = $uri_components->{'eurl_tag'};

    $user = $FB::ROOT_USER unless defined $user;
    return 404 unless defined $user;

    my $u = FB::load_user($user);
    return 404 if ! $u || $u->{statusvis} =~ /[DX]/;
    return 403 if $u->{statusvis} eq 'S';

    if ($eurl_tag) {
        my $gal = $u->gallery_of_existing_tag(FB::durl($eurl_tag));
        if ($gal) {
            $gallid = $gal->id;
        } else { # Check if this might be an alias and redirect to primary tag
            $gal = $u->prigal_of_alias(FB::durl($eurl_tag));
            return Apache::FotoBilder::redir($r, $gal->tag_url())
                if $gal;
        }
    } else {
        $gallid = FB::b28_decode($gallid);
        $auth = FB::b28_decode($auth);
    }

    # old API
    my $gal = FB::load_gallery($u, undef, {
        'gallid' => $gallid,
        'withrels' => 1,
        'props' => [ 'styleid' ],
    });

    # new API
    my $galobj = $gal ? FB::Gallery->new($u, $gallid) : undef;

    return 404 unless $galobj && $galobj->valid;
    return 404 unless $eurl_tag || $auth == $gal->{'randauth'} % (28**3);
    return 404 if $gal->{'name'} eq ":FB_in";

    my %GET = $r->args;

    my $remote = FB::get_remote();

    # check for gallery visible
    return 404 unless FB::get_cap($u, "gallery_enabled");
    return 403 if FB::get_cap($u, "gallery_private") &&
        (! $remote || $remote->{'userid'} != $u->{'userid'});

    return 403 unless $galobj->visible;

    my $err = sub {
        my $msg = shift;
        $r->log_error("FotoBilder::GalleryPage: $msg");
        return 500;
    };

    my @allpics = FB::get_gallery_pictures($u, $gal, $u->secin);

    # all is cool, we're outputting XML
    $r->content_type("text/xml");
    $r->send_http_header();

    my $xml = '<?xml version="1.0"?>' . "\n";
    $xml .= $galobj->info_xml();

    $r->print($xml);

    return OK;
}

1;
