package LJ::Event::CommunityNewComment;
use base 'LJ::Event::NewComment';
use strict;
use Class::Autouse qw(LJ::Comment);
use Carp qw(croak);
use base 'LJ::Event';

sub zero_journalid_subs_means { "method" }

# return list of userids of communities we match on
sub wildcard_matches {
    my $self = shift;

    my $poster = $self->comment->poster;
    return () unless $poster;
    return ($poster->userid);
}


1;
