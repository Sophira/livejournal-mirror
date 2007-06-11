package LJ::Search;
use strict;
use Carp qw (croak);

our $searcher;

sub client {
    my ($class) = @_;

    return undef unless $LJ::SEARCH_SERVER;

    unless ($searcher) {
        $searcher = LJ::run_hook("content_search_client");
    }

    return $searcher;
}


