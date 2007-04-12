#!/usr/bin/perl
#

package Apache::FotoBilder::IndexPage;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED);

sub handler
{
    my $r = shift;
    my $uri = $r->uri;

    my $user;
    if ($FB::ROOT_USER && ($uri eq "/" || $uri eq '/media')) {
        $user = $FB::ROOT_USER;
    } else {
        ($user) = $uri =~ m!^/(\w*)/?$!;
    }

    return 404 unless defined $user;
    my $u = FB::load_user($user, undef, [ "styleid" ]);

    return 404 if ! $u || $u->{statusvis} =~ /[DX]/;
    return 403 if $u->{statusvis} eq 'S';

    my $remote = FB::get_remote();
    # check for gallery visible
    return 404 unless FB::get_cap($u, "gallery_enabled");
    return 403 if FB::get_cap($u, "gallery_private") &&
        (! $remote || $remote->{'userid'} != $u->{'userid'});

    my $styleid = $u->{'styleid'}+0;
    my $ctx = FB::s2_context($r, $styleid);
    FB::S2::set_context($ctx);

    my $indexpage = FB::S2::IndexPage({ 'u' => $u, 'r' => $r,
                                        'styleid' => $styleid,
                                    });

    return OK unless $ctx;
    FB::s2_run($r, $ctx, undef, "IndexPage::print()", $indexpage);
    return OK;
}

1;
