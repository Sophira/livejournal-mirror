package LJ::Comet::AuthToken;
use strict;
use LJ::User;

sub generate {
    my $class  = shift;
    my $userid = shift;
    die "No userid" unless $userid;

    my $auth = join('-', $userid, LJ::rand_chars(10));
    my $chal = LJ::challenge_generate(24*60*60, $auth);
    return $chal;
}

sub token_valid_for {
    my $class  = shift;
    my $token  = shift;
   
    my $opts = {dont_check_count => 1};
    if (LJ::challenge_check($token, $opts)){
        my ($auth_userid, undef) = split '-' => $opts->{rand}, 2;
        return $auth_userid if int $auth_userid eq $auth_userid;
    }
    return undef;
}


1;
