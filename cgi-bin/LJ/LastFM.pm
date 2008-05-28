#!/usr/bin/perl

# LastFM - API to LastFM
package LJ::LastFM;

use strict;

use LWP::UserAgent;
use HTML::TokeParser;
use HTML::Entities;

# Get current track
sub current {
    my $username = shift;
    my %ret;

    my $ua = LJ::get_useragent( role=>'last_fm', timeout=>$LJ::LAST_FM_TIMEOUT );
    my $url = 'http://www.lastfm.com/user/' . LJ::eurl($username) . '/';
    my $response = $ua->get($url);
    my $content = $response->content();

    my $p = HTML::TokeParser->new(\$content);

    my $first = 0;
    my $subject = 0;
    my @nowlistening;

    while ( my $token = $p->get_token ) {
        if ( $subject ) {
             last if $token->[0] eq 'E' && $token->[1] eq 'td'; 
             if ( $token->[0] eq 'T' ) {
                push @nowlistening, $token->[1] if $token->[1] =~ /\w/ && $token->[0] eq 'T';
             }
        } elsif ( $first ) {
            if ( $token->[0] eq 'S' && $token->[4] =~ 'subject' && $token->[4] !~ 'colspan') {
                $subject = 1;
            }
        } elsif ( $token->[0] eq 'S' && $token->[1] eq 'tr' && $token->[4] =~ /\"nowListening\"/) {
            $first = 1;
        }
    }

    $ret{track} = $nowlistening[0];
    
    $ret{track} .= ( $ret{track} && $nowlistening[1] ) ?
        ' - ' . $nowlistening[1] :
        $nowlistening[1];

    $ret{track} = HTML::Entities::decode( $ret{track} ) . ' | Scrobbled by Last.fm'
        if $ret{track};

    $ret{error} = 'Failed to get current track'
        unless $first;

    return %ret;
}


1;
