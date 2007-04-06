#!/usr/bin/perl

package FB::Protocol::GetChallenges;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars}->{GetChallenges};
    my $u    = $resp->{u};

    my $err = sub {
        $resp->add_method_error(GetChallenges => @_);
        return undef;
    };

    my $qty = $vars->{Qty};
    return $err->(212 => "Qty")
        unless defined $qty;
    return $err->(211 => "No challenges requested" => $qty)
        if $qty <= 0;
    return $err->(211 => "Too many challenges" => $qty)
        if $qty > 100;

    my @chals = ();
    foreach (1..$qty) {
        push @chals, FB::generate_challenge($u)
            or return $err->(500);
    }

    # register return value with parent Request
    $resp->add_method_vars(GetChallenges => 
                           { Challenge => \@chals });

    return 1;
}

1;
