#!/usr/bin/perl

package FB::Protocol::GetChallenge;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars};
    my $u    = $resp->{u};

    my $err = sub {
        $resp->add_method_error(GetChallenge => @_);
        return undef;
    };

    my $chal = FB::generate_challenge($u)
        or return $err->(500);

    # register return value with parent Request
    $resp->add_method_vars(GetChallenge => 
                           { Challenge => [ $chal ] });

    return 1;
}

1;
