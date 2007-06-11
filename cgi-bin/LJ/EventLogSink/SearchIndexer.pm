package LJ::EventLogSink::SearchIndexer;
use strict;
use base 'LJ::EventLogSink';
use SixApart::Search;

our @EVENT_TYPES = qw(new_entry new_comment edit_entry delete_comment);

sub new {
    my ($class, %opts) = @_;

    my $self = {};

    bless $self, $class;
    return $self;
}

sub should_log {
    my ($self, $evt) = @_;
    my $type = $evt->event_type;

    # don't search unless we have a client object
    return 0 unless LJ::Search->client;

    return grep { $_ eq $type }
        @LJ::EventLogSink::SearchIndexer::EVENT_TYPES;
}

sub log {
    my ($self, $evt) = @_;

    my %handlers = (
                    new_entry      => \&index_new_entry,
                    new_comment    => \&index_new_comment,
                    edit_entry     => \&index_edit_entry,
                    delete_comment => \&index_delete_comment,
                    );

    my $handler = $handlers{$evt->event_type}
        or die "No handler found for event type " . $evt->event_type;

    $handler->($evt);

    return 1;
}

sub index_new_entry {
    my $evt = shift;

    my $info = $evt->params or return 0;
    my $entry = LJ::Entry->new($info->{'journal.userid'},
                               ditemid => $info->{ditemid});

    my $id = "entry_" .  $entry->jitemid;

    LJ::Search->client->update(id => $id, $entry->event_text);
}

sub index_new_comment {
    my $evt = shift;

    my $info = $evt->params or return 0;
    my $cmt = LJ::Comment->new($info->{'journal.userid'},
                               jtalkid => $info->{jtalkid});
}

sub index_edit_entry {
    my $evt = shift;

    my $info = $evt->params or return 0;
    my $entry = LJ::Entry->new($info->{'journalid'},
                               jitemid => $info->{jitemid});

}

sub index_delete_comment {
    my $evt = shift;

    my $info = $evt->params or return 0;
    my $cmt = LJ::Comment->new($info->{'journalid'},
                               jtalkid => $info->{jtalkid});

}

1;
