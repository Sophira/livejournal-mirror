package LJ::Event::OfficialPost;
use strict;
use Class::Autouse qw(LJ::Entry);
use Carp qw(croak);
use base 'LJ::Event';

sub new {
    my ($class, $entry) = @_;
    croak "No entry" unless $entry;

    return $class->SUPER::new($entry->journal, $entry->ditemid);
}

sub entry {
    my $self = shift;
    my $ditemid = $self->arg1;
    return LJ::Entry->new($self->event_journal, ditemid => $ditemid);
}

sub content {
    my $self = shift;
    return $self->entry->event_text;
}

sub is_common { 1 }

sub zero_journalid_subs_means { 'all' }

sub as_email_subject {
    my $self = shift;

    if ($self->entry->subject_text) {
        return sprintf "$LJ::SITENAMESHORT Announcement: %s", $self->entry->subject_text;
    } else {
        return sprintf "$LJ::SITENAMESHORT Announcement: New %s announcement", $self->entry->journal->display_username;
    }
}

*as_email_html = \&as_html;
*as_email_string = \&as_string;

sub as_html {
    my $self = shift;
    my $entry = $self->entry or return "(Invalid entry)";
    return 'There is a new <a href="' . $entry->url . '">post</a> in ' . $entry->journal->ljuser_display;
}

sub as_string {
    my $self = shift;
    my $entry = $self->entry or return "(Invalid entry)";
    return 'There is a new post in ' . $entry->journal->display_username . ' at ' . $entry->url;
}

sub as_sms {
    my $self = shift;
    return $self->as_string;
}

sub subscription_as_html {
    my ($class, $subscr) = @_;
    return "$LJ::SITENAME makes a new announcement";
}

1;
