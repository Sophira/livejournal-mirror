#
# LiveJournal entry object.
#
# Just framing right now, not much to see here!
#

package LJ::Comment;

use strict;
use vars qw/ $AUTOLOAD /;
use Carp qw/ croak /;
use Class::Autouse qw(
                      LJ::Entry
                      );

require "$ENV{LJHOME}/cgi-bin/talklib.pl";

# internal fields:
#
#    journalid:     journalid where the commend was
#                   posted,                          always present
#    jtalkid:       jtalkid identifying this comment
#                   within the journal_u,            always present
#
#    nodetype:      single-char nodetype identifier, loaded if _loaded_row
#    nodeid:        nodeid to which this comment
#                   applies (often an entry itemid), loaded if _loaded_row
#
#    parenttalkid:  talkid of parent comment,        loaded if _loaded_row
#    posterid:      userid of posting user           lazily loaded at access
#    datepost_unix: unixtime from the 'datepost'     loaded if _loaded_row
#    state:         comment state identifier,        loaded if _loaded_row

#    body:          text of comment,                 loaded if _loaded_text
#    body_orig:     text of comment w/o transcoding, present if unknown8bit

#    subject:       subject of comment,              loaded if _loaded_text
#    subject_orig   subject of comment w/o transcoding, present if unknown8bit

#    props:   hashref of props,                    loaded if _loaded_props

#    _loaded_text:   loaded talktext2 row
#    _loaded_row:    loaded talk2 row
#    _loaded_props:  loaded props

# <LJFUNC>
# name: LJ::Comment::new
# class: comment
# des: Gets a comment given journal_u entry and jtalkid.
# args: uuserid, opts
# des-uobj: A user id or $u to load the comment for.
# des-opts: Hash of optional keypairs.
#           jtalkid => talkid journal itemid (no anum)
# returns: A new LJ::Comment object.  undef on failure.
# </LJFUNC>
sub new
{
    my $class = shift;
    my $self  = bless {};

    my $uuserid = shift;
    my $n_arg   = scalar @_;
    croak("wrong number of arguments")
        unless $n_arg && ($n_arg % 2 == 0);

    my %opts = @_;

    $self->{journalid} = LJ::want_userid($uuserid) or
        croak("invalid journalid parameter");

    $self->{jtalkid} = int(delete $opts{jtalkid});

    if (my $dtalkid = int(delete $opts{dtalkid})) {
        $self->{jtalkid} = $dtalkid >> 8;
    }

    croak("need to supply jtalkid") unless $self->{jtalkid};
    croak("unknown parameters: " . join(", ", keys %opts))
        if %opts;
    return $self;
}

sub url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $url     = $entry->url;

    return "$url?thread=$dtalkid#t$dtalkid";
}

sub reply_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $url     = $entry->url;

    return "$url?replyto=$dtalkid";
}

sub thread_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $url     = $entry->url;

    return "$url?thread=$dtalkid";
}

sub unscreen_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $journal = $entry->u->journal;

    return 
        "$LJ::SITEROOT/talkscreen.bml" . 
        "?mode=unscreen&journal=$journal" . 
        "&talkid=$dtalkid";
}

sub delete_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $journal = $entry->u->journal;

    return 
        "$LJ::SITEROOT/delcomment.bml" . 
        "?journal=$journal&id=$dtalkid";
}

# return LJ::User of journal comment is in
sub journal {
    my $self = shift;
    return LJ::load_userid($self->{journalid});
}

# return LJ::Entry of entry comment is in, or undef if it's not
# a nodetype of L
sub entry {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self ]) unless $self->{_loaded_row};
    return undef unless $self->{nodetype} eq "L";
    return LJ::Entry->new($self->journal, jitemid => $self->{nodeid});
}

sub jtalkid {
    my $self = shift;
    return $self->{jtalkid};
}

sub dtalkid {
    my $self = shift;
    my $entry = $self->entry;
    return ($self->jtalkid * 256) + $entry->anum;
}

sub parenttalkid {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self ]) unless $self->{_loaded_row};
    return $self->{parenttalkid};
}

# returns a LJ::Comment object for the parent
sub parent {
    my $self = shift;
    my $ptalkid = $self->parenttalkid or return undef;

    return LJ::Comment->new($self->journal, jtalkid => $ptalkid);
}

# returns true if entry currently exists.  (it's possible for a given
# $u, to make a fake jitemid and that'd be a valid skeleton LJ::Entry
# object, even though that jitemid hasn't been created yet, or was
# previously deleted)
sub valid {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self ]) unless $self->{_loaded_row};
    return $self->{_loaded_row};
}

# when was this comment left?
sub unixtime {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self ]) unless $self->{_loaded_row};
    return LJ::mysqldate_to_time($self->{datepost}, 0);
}

# returns LJ::User object for the poster of this entry, or undef for anonymous
sub poster {
    my $self = shift;
    return LJ::load_userid($self->posterid);
}

sub posterid {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self ]) unless $self->{_loaded_row};
    return $self->{posterid};
}

# class method:
sub preload_rows {
    my ($class, $obj_list) = @_;

    foreach my $obj (@$obj_list) {
        next if $obj->{_loaded_row};

        my $u = $obj->journal;
        my $row = LJ::Talk::get_talk2_row($u, $obj->{journalid}, $obj->jtalkid);
        next unless $row; # FIXME: die?

        for my $f (qw(nodetype nodeid parenttalkid posterid datepost state)) {
            $obj->{$f} = $row->{$f};
        }
        $obj->{_loaded_row} = 1;
    }
}

# class method:
sub preload_props {
    my ($class, $entlist) = @_;
    foreach my $en (@$entlist) {
        next if $en->{_loaded_props};
        $en->_load_props;
    }
}

# returns true if loaded, zero if not.
# also sets _loaded_text and subject and event.
sub _load_text {
    my $self = shift;
    return 1 if $self->{_loaded_text};

    my $entry  = $self->entry;
    my $entryu = $entry->u;

    my $ret  = LJ::get_talktext2($entryu, $self->jtalkid);
    my $tt = $ret->{$self->jtalkid};
    return 0 unless $tt && ref $tt;

    # raw subject and body
    $self->{subject} = $tt->[0];
    $self->{body}    = $tt->[1];

    if ($self->prop("unknown8bit")) {
        # save the old ones away, so we can get back at them if we really need to
        $self->{subject_orig} = $self->{subject};
        $self->{body_orig}    = $self->{body};

        # FIXME: really convert all the props?  what if we binary-pack some in the future?
        LJ::item_toutf8($self->{u}, \$self->{subject}, \$self->{event}, $self->{props});
    }

    $self->{_loaded_text} = 1;
    return 1;
}

sub prop {
    my ($self, $prop) = @_;
    $self->_load_props unless $self->{_loaded_props};
    return $self->{props}{$prop};
}

sub props {
    my ($self, $prop) = @_;
    $self->_load_props unless $self->{_loaded_props};
    return $self->{props} || {};
}

sub _load_props {
    my $self = shift;
    return 1 if $self->{_loaded_props};

    my $props = {};
    LJ::load_log_props2($self->{u}, [ $self->{jitemid} ], $props);
    $self->{props} = $props->{ $self->{jitemid} };

    $self->{_loaded_props} = 1;
    return 1;
}

# raw utf8 text, with no HTML cleaning
sub subject_raw {
    my $self = shift;
    $self->_load_text  unless $self->{_loaded_text};
    return $self->{subject};
}

# raw text as user sent us, without transcoding while correcting for unknown8bit
sub subject_orig {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};
    return $self->{subject_orig} || $self->{subject};
}

# raw utf8 text, with no HTML cleaning
sub body_raw {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};
    return $self->{body};
}

# raw text as user sent us, without transcoding while correcting for unknown8bit
sub body_orig {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};
    return $self->{body_orig} || $self->{body};
}

sub subject_html {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};
    return LJ::ehtml($self->{subject});
}

sub is_active {
    my $self = shift;
    return $self->{state} eq 'A' ? 1 : 0;
}

sub is_screened {
    my $self = shift;
    return $self->{state} eq 'S' ? 1 : 0;
}

sub is_deleted {
    my $self = shift;
    return $self->{state} eq 'D' ? 1 : 0;
}

sub remote_can_delete {
    my $self = shift;

    my $remote   = LJ::User->remote;
    my $journalu = $self->journal;
    my $posteru  = $self->poster;

    return LJ::Talk::can_delete($remote, $journalu, $posteru, $posteru->user);
}

1;
