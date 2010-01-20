package LJ::Request;
use strict;

use constant MP2 => (exists $ENV{MOD_PERL_API_VERSION} &&
                     $ENV{MOD_PERL_API_VERSION} == 2) ? 1 : 0;

BEGIN {
    if (MP2){
        require LJ::Request::Apache2;
    } else {
        require LJ::Request::Apache;
    }
}


1;

