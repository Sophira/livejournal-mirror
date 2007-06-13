# This package is for managing a queue of notifications
# for a user.
# Mischa Spiegelmock, 4/28/06

package LJ::NotificationInbox;

use strict;
use Carp qw(croak);
use Class::Autouse qw (LJ::NotificationItem LJ::Event);

# constructor takes a $u
sub new {
    my ($class, $u) = @_;

    croak "Invalid args to construct LJ::NotificationQueue" unless $class && $u;
    croak "Invalid user" unless LJ::isu($u);

    # return singleton from $u if it already exists
    return $u->{_notification_inbox} if $u->{_notification_inbox};

    my $self = {
        uid => $u->userid,
        count => undef, # defined once ->count is loaded/cached
        items => undef, # defined to arrayref once items loaded
        bookmarks => undef, # defined to arrayref
    };

    return $u->{_notification_inbox} = bless $self, $class;
}

# returns the user object associated with this queue
*owner = \&u;
sub u {
    my $self = shift;
    return LJ::load_userid($self->{uid});
}

# Returns a list of LJ::NotificationItems in this queue.
sub items {
    my $self = shift;

    croak "notifications is an object method"
        unless (ref $self) eq __PACKAGE__;

    return @{$self->{items}} if defined $self->{items};

    my @qids = $self->_load;

    my @items = ();
    foreach my $qid (@qids) {
        push @items, LJ::NotificationItem->new($self->owner, $qid);
    }

    $self->{items} = \@items;

    # optimization:
    #   now items are defined ... if any are comment 
    #   objects we'll instantiate those ahead of time
    #   so that if one has its data loaded they will
    #   all benefit from a coalesced load
    $self->instantiate_comment_singletons;

    return @items;
}

# returns a list of friend-related notificationitems
sub friend_items {
    my $self = shift;

    my @friend_events = qw(
                           Befriended
                           InvitedFriendJoins
                           CommunityInvite
                           NewUserpic
                           );

    @friend_events = (@friend_events, (LJ::run_hook('friend_notification_types') || ()));

    my %friend_events = map { "LJ::Event::" . $_ => 1 } @friend_events;
    return grep { $friend_events{$_->event->class} } $self->items;
}

# returns a list of non user-messaging notificationitems
sub non_usermsg_items {
    my $self = shift;

    my @usermsg_events = qw(
                           UserMessageRecvd
                           UserMessageSent
                           );

    @usermsg_events = (@usermsg_events, (LJ::run_hook('usermsg_notification_types') || ()));

    my %usermsg_events = map { "LJ::Event::" . $_ => 1 } @usermsg_events;
    return grep { !$usermsg_events{$_->event->class} } $self->items;
}

# returns a list of non user-message recvd notificationitems
sub usermsg_recvd_items {
    my $self = shift;

    my @usermsg_events = qw(
                           UserMessageRecvd
                           );

    my %usermsg_events = map { "LJ::Event::" . $_ => 1 } @usermsg_events;
    return grep { $usermsg_events{$_->event->class} } $self->items;
}

# returns a list of non user-message recvd notificationitems
sub usermsg_sent_items {
    my $self = shift;

    my @usermsg_events = qw(
                           UserMessageSent
                           );

    my %usermsg_events = map { "LJ::Event::" . $_ => 1 } @usermsg_events;
    return grep { $usermsg_events{$_->event->class} } $self->items;
}

sub count {
    my $self = shift;

    return $self->{count} if defined $self->{count};

    if (defined $self->{items}) {
        return $self->{count} = scalar @{$self->{items}};
    }

    my $u = $self->owner;
    return $self->{count} = $u->selectrow_array
        ("SELECT COUNT(*) FROM notifyqueue WHERE userid=?",
         undef, $u->id);
}

# returns number of unread items in inbox
# returns a maximum of 1000, if you get 1000 it's safe to
# assume "more than 1000"
sub unread_count {
    my $self = shift;

    # cached unread count
    my $unread = LJ::MemCache::get($self->_unread_memkey);

    return $unread if defined $unread;

    # not cached, load from DB
    my $u = $self->u or die "No user";

    my $sth = $u->prepare("SELECT COUNT(*) FROM notifyqueue WHERE userid=? AND state='N' LIMIT 1000");
    $sth->execute($u->id);
    die $sth->errstr if $sth->err;
    ($unread) = $sth->fetchrow_array;

    # cache it
    LJ::MemCache::set($self->_unread_memkey, $unread, 30 * 60);

    return $unread;
}

# load the items in this queue
# returns internal items hashref
sub _load {
    my $self = shift;

    my $u = $self->u
        or die "No user object";

    # is it memcached?
    my $qids;
    $qids = LJ::MemCache::get($self->_memkey) and return @$qids;

    # not cached, load
    my $sth = $u->prepare
        ("SELECT userid, qid, journalid, etypeid, arg1, arg2, state, createtime " .
         "FROM notifyqueue WHERE userid=?");
    $sth->execute($u->{userid});
    die $sth->errstr if $sth->err;

    my @items = ();
    while (my $row = $sth->fetchrow_hashref) {
        my $qid = $row->{qid};

        # load this item into process cache so it's ready to go
        my $qitem = LJ::NotificationItem->new($u, $qid);
        $qitem->absorb_row($row);

        push @items, $qitem;
    }

    # sort based on create time
    @items = sort { $a->when_unixtime <=> $b->when_unixtime } @items;

    # get sorted list of ids
    my @item_ids = map { $_->qid } @items;

    # cache
    LJ::MemCache::set($self->_memkey, \@item_ids);

    return @item_ids;
}

sub instantiate_comment_singletons {
    my $self = shift;

    # instantiate all the comment singletons so that they will all be
    # loaded efficiently later as soon as preload_rows is called on
    # the first comment object
    my @comment_items = grep { $_->event->class eq 'LJ::Event::JournalNewComment' } $self->items;
    my @comment_events = map { $_->event } @comment_items;
    # instantiate singletons
    LJ::Comment->new($_->event_journal, jtalkid => $_->jtalkid) foreach @comment_events;

    return 1;
}

sub _memkey {
    my $self = shift;
    my $userid = $self->u->id;
    return [$userid, "inbox:$userid"];
}

sub _unread_memkey {
    my $self = shift;
    my $userid = $self->u->id;
    return [$userid, "inbox:newct:${userid}"];
}

sub _bookmark_memkey {
    my $self = shift;
    my $userid = $self->u->id;
    return [$userid, "inbox:bookmarks:${userid}"];
}

# deletes an Event that is queued for this user
# args: Queue ID to remove from queue
sub delete_from_queue {
    my ($self, $qitem) = @_;

    croak "delete_from_queue is an object method"
        unless (ref $self) eq __PACKAGE__;

    my $qid = $qitem->qid;

    croak "no queueid for queue item passed to delete_from_queue" unless int($qid);

    my $u = $self->u
        or die "No user object";

    $u->do("DELETE FROM notifyqueue WHERE userid=? AND qid=?", undef, $u->id, $qid);
    die $u->errstr if $u->err;

    # invalidate caches
    $self->expire_cache;

    return 1;
}

sub expire_cache {
    my $self = shift;

    $self->{count} = undef;
    $self->{items} = undef;

    LJ::MemCache::delete($self->_memkey);
    LJ::MemCache::delete($self->_unread_memkey);
}

# FIXME: make this faster
sub oldest_item {
    my $self = shift;
    my @items = $self->items;

    my $oldest;
    foreach my $item (@items) {
        $oldest = $item if !$oldest || $item->when_unixtime < $oldest->when_unixtime;
    }

    return $oldest;
}

# This will enqueue an event object
# Returns the enqueued item
sub enqueue {
    my ($self, %opts) = @_;

    my $evt = delete $opts{event};
    croak "No event" unless $evt;
    croak "Extra args passed to enqueue" if %opts;

    my $u = $self->u or die "No user";

    # if over the max, delete the oldest notification
    my $max = $u->get_cap('inbox_max');
    if ($max && $self->count >= $max) {
        my $too_old_qid = $u->selectrow_array
            ("SELECT qid FROM notifyqueue ".
             "WHERE userid=? ".
             "ORDER BY qid DESC LIMIT $max,1",
             undef, $u->id);

        if ($too_old_qid) {
            $u->do("DELETE FROM notifyqueue WHERE userid=? AND qid <= ?",
                   undef, $u->id, $too_old_qid);
            $self->expire_cache;
        }
    }

    # get a qid
    my $qid = LJ::alloc_user_counter($u, 'Q')
        or die "Could not alloc new queue ID";

    my %item = (qid        => $qid,
                userid     => $u->{userid},
                journalid  => $evt->u->{userid},
                etypeid    => $evt->etypeid,
                arg1       => $evt->arg1,
                arg2       => $evt->arg2,
                state      => $evt->mark_read ? 'R' : 'N',
                createtime => $evt->eventtime_unix || time());

    # insert this event into the notifyqueue table
    $u->do("INSERT INTO notifyqueue (" . join(",", keys %item) . ") VALUES (" .
           join(",", map { '?' } values %item) . ")", undef, values %item)
        or die $u->errstr;

    # insert into the notifyarchive table without State
    delete $item{state};
    $u->do("INSERT INTO notifyarchive (" . join(",", keys %item) . ") VALUES (" .
           join(",", map { '?' } values %item) . ")", undef, values %item)
        or die $u->errstr;

    # invalidate memcache
    $self->expire_cache;

    return LJ::NotificationItem->new($u, $qid);
}

# return true if item is bookmarked
sub is_bookmark {
    my ($self, $qid) = @_;

    # load bookmarks if they don't already exist
    $self->load_bookmarks unless defined $self->{bookmarks};

    return $self->{bookmarks}{$qid} ? 1 : 0;
}

# populate the bookmark hash
sub load_bookmarks {
    my ($self) = @_;

    my $u = $self->u;
    my $uid = $self->u->id;
    my $row = LJ::MemCache::get($self->_bookmark_memkey);

    $self->{bookmarks} = ();
    if ($row){
        my @qids = unpack("NNNNN", $row);
        foreach my $qid (@qids) {
            $self->{bookmarks}{$qid} = 1;
        }
        return;
    }

    my $sql = "SELECT qid FROM notifybookmarks WHERE userid=?";
    my $qids = $u->selectcol_arrayref($sql, undef, $uid);
    die "Failed to load bookmarks: " . $u->errstr . "\n" if $u->err;

    foreach my $qid (@$qids) {
        $self->{bookmarks}{$qid} = 1;
    }

    $row = pack("NNNNN", @$qids);
    LJ::MemCache::set($self->_bookmark_memkey, $row);

    return;
}

# add a bookmark
sub add_bookmark {
    my ($self, $qid) = @_;

    my $u = $self->u;
    my $uid = $self->u->id;

    my $sql = "INSERT INTO notifybookmarks (userid, qid) VALUES (?, ?)";
    $u->do($sql, undef, $uid, $qid);
    die "Failed to add bookmark: " . $u->errstr . "\n" if $u->err;

    $self->{bookmarks}{$qid} = 1 if defined $self->{bookmarks};
    LJ::MemCache::delete($self->_bookmark_memkey);

    return;
}

# remove bookmark
sub remove_bookmark {
    my ($self, $qid) = @_;

    my $u = $self->u;
    my $uid = $self->u->id;

    my $sql = "DELETE FROM notifybookmarks WHERE userid=? AND qid=?";
    $u->do($sql, undef, $uid, $qid);
    die "Failed to remove bookmark: " . $u->errstr . "\n" if $u->err;

    delete $self->{bookmarks}->{$qid} if defined $self->{bookmarks};
    LJ::MemCache::delete($self->_bookmark_memkey);

    return;
}

# add or remove bookmark based on whether it is already bookmarked
sub toggle_bookmark {
    my ($self, $qid) = @_;

    $self->is_bookmark($qid)
        ? $self->remove_bookmark($qid)
        : $self->add_bookmark($qid);

    return;
}

1;
