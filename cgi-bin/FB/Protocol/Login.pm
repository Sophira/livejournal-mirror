#!/usr/bin/perl

package FB::Protocol::Login;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $r    = $req->{r};
    my $vars = $req->{vars}->{Login};
    my $u    = $resp->{u};

    my $err = sub {
        $resp->add_method_error(Login => @_);
        return undef;
    };

    my $ret = { ServerTime => [ FB::date_unix_to_mysql() ]};

    # store client version in $r->notes so we can log it optionally
    # to keep stats
    if (defined $vars->{ClientVersion}) {
        $r->notes(ProtocolClientVersion => $vars->{ClientVersion});
    }

    # look up quota and usage information to return with this request
    if (FB::are_hooks('disk_usage_info')) {

        my $qinf = FB::run_hook('disk_usage_info', $u);
        if (ref $qinf eq 'HASH') {
            $ret->{Quota} = {
                Total     => [ $qinf->{quota} * (1 << 10) ], # kb -> bytes
                Used      => [ $qinf->{used}  * (1 << 10) ],
                Remaining => [ $qinf->{free}  * (1 << 10) ],
            };
        }
    }

    # are there any current system messages applying to this user?
    $ret->{Message} = [ FB::get_system_message($u) . '' ];

    # register return value with parent Request
    $resp->add_method_vars( Login => $ret );

    return 1;
}

1;
