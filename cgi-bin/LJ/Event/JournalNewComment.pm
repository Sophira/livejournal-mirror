package LJ::Event::JournalNewComment;
use strict;
use Class::Autouse qw(LJ::Comment);
use Carp qw(croak);
use base 'LJ::Event::NewComment';

sub zero_journalid_subs_means { "friends" }

1;
