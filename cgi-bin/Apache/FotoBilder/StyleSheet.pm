#!/usr/bin/perl
#

package Apache::FotoBilder::StyleSheet;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED);

sub handler
{
    my $r = shift;
    my $uri = $r->uri;

    my ($user, $styleid) =
        $uri =~ m!^(?:/(\w+))?/res/(\d+)/stylesheet$!;
    $user = $FB::ROOT_USER unless defined $user;
    return 404 unless defined $user;
    my $dmid = FB::current_domain_id();
    my $u = FB::load_user($user, $dmid);
    return 404 if ! $u || $u->{statusvis} =~ /[DX]/;
    return 403 if $u->{statusvis} eq 'S';
    
    my $opts = {
        'use_modtime' => 0,  # *sigh* ... FIXME: don't use MAX(layer comptime), but last time styleid was changed.
        'content_type' => 'text/css',
    };
    my $ctx = FB::s2_context($r, $styleid, $opts);
    return OK unless $ctx;
    FB::s2_run($r, $ctx, $opts, "print_stylesheet()");
    return OK;
}

1;

