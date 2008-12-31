#!/usr/bin/perl
#

package LJ::ModPerl;

use strict;
use lib "$ENV{LJHOME}/cgi-bin";

# very important that this is done early!  everything else in the LJ
# setup relies on $LJ::HOME being set...
$LJ::HOME = $ENV{LJHOME};

#use APR::Pool ();
#use Apache::DB ();
#Apache::DB->init();

#use strict;
#use Data::Dumper;
#use Apache2::Const -compile => qw(OK);
#use Apache2::ServerUtil ();

#Apache2::ServerUtil->server->add_config( [ 'PerlResponseHandler LJ::ModPerl', 'SetHandler perl-script' ] );

#sub handler {
#    my $r = shift;
#
#    print STDERR Dumper(\@_);
#    print STDERR Dumper(\%ENV);
#
#    die 1;
#    return Apache2::Const::OK;
#}

# Image::Size wants to pull in Image::Magick.  Let's not let it during
# the init process.
my $still_loading = 1;
unshift @INC, sub {
    my $f = $_[1];
    return undef unless $still_loading;
    return undef unless $f eq "Image/Magick.pm";
    die "Will not start with Image/Magick.pm"; # makes the require fail, which Image::Size traps
};

# pull in libraries and do per-start initialization once.
require "modperl_subs.pl";

# now we're done loading
$still_loading = 0;

# do per-restart initialization
LJ::ModPerl::setup_restart();

# delete itself from %INC to make sure this file is run again
# when apache is restarted
delete $INC{"$LJ::HOME/cgi-bin/modperl.pl"};

# remember modtime of all loaded libraries
%LJ::LIB_MOD_TIME = ();
while (my ($k, $file) = each %INC) {
    next if $LJ::LIB_MOD_TIME{$file};
    next unless $file =~ m!^\Q$LJ::HOME\E!;
    my $mod = (stat($file))[9];
    $LJ::LIB_MOD_TIME{$file} = $mod;
}

# compatibility with old location of LJ::email_check:
*BMLCodeBlock::check_email = \&LJ::check_email;

1;
