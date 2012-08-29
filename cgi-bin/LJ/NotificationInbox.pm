# This package is for managing a queue of notifications
# for a user.
# Mischa Spiegelmock, 4/28/06

package LJ::NotificationInbox;

use strict;
use Carp qw(croak);
use Class::Autouse qw (LJ::NotificationItem LJ::Event LJ::NotificationArchive LJ::Event::InboxUserMessageRecvd);

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

    $self->instantiate_message_singletons;

    return @items;
}

# returns a list of all notification items except for sent user messages
sub all_items {
    my $self = shift;

    return grep { $_->{state} ne 'S' } grep { $_->event->class ne "LJ::Event::UserMessageSent" } grep {$_->event} $self->items;
}

# returns a list of friend-related notificationitems
sub friend_items {
    my $self = shift;

    my @friend_events = friend_event_list();

    my %friend_events = map { "LJ::Event::" . $_ => 1 } @friend_events;
    return grep { $friend_events{$_->event->class} } grep {$_->event} $self->items;
}

# returns a list of friend-related notificationitems
sub friendplus_items {
    my $self = shift;

    my @friend_events = friendplus_event_list();

    my %friend_events = map { "LJ::Event::" . $_ => 1 } @friend_events;
    return grep { $friend_events{$_->event->class} } grep {$_->event} $self->items;
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
    return grep { !$usermsg_events{$_->event->class} } grep {$_->event} $self->items;
}

# returns a list of non user-message recvd notificationitems
sub usermsg_recvd_items {
    my $self = shift;

    my @events = ( 'UserMessageRecvd' );
    my @items = $self->subset_items(@events);

    @items = grep { $_->{state} ne 'S' } @items if LJ::is_enabled('spam_inbox');

    return @items;
}

# returns a list of non user-message recvd notificationitems
sub usermsg_sent_items {
    my $self = shift;

    my @events = ( 'UserMessageSent' );

    return $self->subset_items(@events);
}

# returns a list of spam notificationitems
sub spam_items {
    my $self = shift;

    my @events = ( 'UserMessageRecvd' );

    return grep { $_->{state} eq 'S' } $self->subset_items(@events);
}

sub birthday_items {
    my $self = shift;

    my @events = ( 'Birthday' );

    return $self->subset_items(@events);
}

sub befriended_items {
    my $self = shift;

    my @events = ( 'Befriended' );

    return $self->subset_items(@events);
}

sub entrycomment_items {
    my $self = shift;

    my @events = entrycomment_event_list();

    return $self->subset_items(@events);
}

# return a subset of notificationitems
sub subset_items {
    my ($self, @subset) = @_;

     my %subset_events = map { "LJ::Event::" . $_ => 1 } @subset;
     return grep { $subset_events{$_->event->class} } $self->items;
}

# return flagged notifications
sub bookmark_items {
    my $self = shift;

    return grep { $self->is_bookmark($_->qid) } $self->items;
}

# return archived notifications
sub archived_items {
    my $self = shift;

    my $u = $self->u;
    my $archive = $u->notification_archive;
    return $archive->items;
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
    my $unread = LJ::MemCacheProxy::get($self->_unread_memkey);

    return $unread if defined $unread;

    # not cached, load from DB
    my $u = $self->u or die "No user";

    my $sth = $u->prepare("SELECT COUNT(*) FROM notifyqueue WHERE userid=? AND state='N' LIMIT 1000");
    $sth->execute($u->id);
    die $sth->errstr if $sth->err;
    ($unread) = $sth->fetchrow_array;

    # cache it
    LJ::MemCacheProxy::set($self->_unread_memkey, $unread, 30 * 60);

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
    LJ::MemCache::set($self->_memkey, \@item_ids, 86400);

    return @item_ids;
}

sub instantiate_comment_singletons {
    my $self = shift;

    # instantiate all the comment singletons so that they will all be
    # loaded efficiently later as soon as preload_rows is called on
    # the first comment object
    my @comment_items = grep { $_->event->class eq 'LJ::Event::JournalNewComment' } grep {$_->event} $self->items;
    my @comment_events = map { $_->event } @comment_items;
    # instantiate singletons
    LJ::Comment->new($_->event_journal, jtalkid => $_->jtalkid) foreach @comment_events;

    return 1;
}

sub instantiate_message_singletons {
    my $self = shift;

    # instantiate all the message singletons so that they will all be
    # loaded efficiently later as soon as preload_rows is called on
    # the first message object
    my @message_items = grep { $_->event->class eq 'LJ::Event::UserMessageRecvd' } grep {$_->event} $self->items;
    my @message_events = map { $_->event } @message_items;
    # instantiate singletons
    LJ::Message->load({msgid => $_->arg1, journalid => $_->u->{userid}}) foreach @message_events;

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
    my $archive = delete $opts{archive} || 1;
    croak "No event" unless $evt;
    croak "Extra args passed to enqueue" if %opts;

    my $u = $self->u or die "No user";

    # if over the max, delete the oldest notification
    my $max = $u->get_cap('inbox_max');
    my $skip = $max - 1; # number to skip to get to max
    if ($max && $self->count >= $max) {

        # Get list of bookmarks and ignore them when checking inbox limits
        my $bmarks = join ',', $self->get_bookmarks_ids;
        my $bookmark_sql = ($bmarks) ? "AND qid NOT IN ($bmarks) " : '';
        my $too_old_qid = $u->selectrow_array
            ("SELECT qid FROM notifyqueue ".
             "WHERE userid=? $bookmark_sql".
             "ORDER BY qid DESC LIMIT $skip,1",
             undef, $u->id);

        if ($too_old_qid) {
            $u->do("DELETE FROM notifyqueue WHERE userid=? AND qid <= ? $bookmark_sql",
                   undef, $u->id, $too_old_qid);
            $self->expire_cache;
        }
    }

    # get a qid
    my $qid = LJ::alloc_user_counter($u, 'Q')
        or die "Could not alloc new queue ID";
    my $spam = 0;
    if ( LJ::is_enabled('spam_inbox') && $evt->etypeid == LJ::Event::UserMessageRecvd->etypeid ) {
        my $need_check = 0;
        LJ::run_hook('need_spam_check_inbox', \$need_check, $evt->arg1, $evt->userid);
        LJ::run_hook('spam_inbox_detector', \$spam, $evt->arg1, $evt->userid)
            if $need_check;
    }

    my %item = (qid        => $qid,
                userid     => $u->{userid},
                journalid  => $evt->userid,
                etypeid    => $evt->etypeid,
                arg1       => $evt->arg1,
                arg2       => $evt->arg2,
                state      => $spam ? 'S' : $evt->mark_read ? 'R' : 'N',
                createtime => $evt->eventtime_unix || time());

    # insert this event into the notifyqueue table
    $u->do("INSERT INTO notifyqueue (" . join(",", keys %item) . ") VALUES (" .
           join(",", map { '?' } values %item) . ")", undef, values %item)
        or die $u->errstr;

    if ($archive) {
        # insert into the notifyarchive table with State defaulted to space
        $item{state} = ' ';
        $u->do("INSERT INTO notifyarchive (" . join(",", keys %item) . ") VALUES (" .
               join(",", map { '?' } values %item) . ")", undef, values %item)
            or die $u->errstr;
    }

    # send notification
    $self->__send_notify( { 'u'         => $u,
                            'journal_u' => LJ::want_user($evt->arg2),
                            'msgid'     => $evt->arg1,
                            'etypeid'   => $evt->etypeid, });

    # invalidate memcache
    $self->expire_cache;

    return LJ::NotificationItem->new($u, $qid);
}

sub __send_notify {
    my ($self, $data) = @_;
    my $etypeid = $data->{'etypeid'};

    if (LJ::Event::UserMessageRecvd->etypeid == $etypeid) {
        my $msgid       = $data->{'msgid'};
        my $u           = $data->{'u'};
        my $journal_u   = $data->{'journal_u'};

        LJ::Event::InboxUserMessageRecvd->new($u, $msgid, $journal_u)->fire;
    }
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
        my @qids = unpack("N*", $row);
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

    $row = pack("N*", @$qids);
    LJ::MemCache::set($self->_bookmark_memkey, $row, 3600);

    return;
}

## returns array of qid of 'bookmarked' messages
sub get_bookmarks_ids {
    my $self = shift;
    
    $self->load_bookmarks unless $self->{bookmarks};
    return keys %{ $self->{bookmarks} };
}

# add a bookmark
sub add_bookmark {
    my ($self, $qid) = @_;

    my $u = $self->u;
    my $uid = $self->u->id;

    return 0 unless $self->can_add_bookmark;

    my $sql = "INSERT IGNORE INTO notifybookmarks (userid, qid) VALUES (?, ?)";
    $u->do($sql, undef, $uid, $qid);
    die "Failed to add bookmark: " . $u->errstr . "\n" if $u->err;

    # Make sure notice is in inbox
    $self->ensure_queued($qid);

    $self->{bookmarks}{$qid} = 1 if defined $self->{bookmarks};
    LJ::MemCache::delete($self->_bookmark_memkey);

    return 1;
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

    return 1;
}

# add or remove bookmark based on whether it is already bookmarked
sub toggle_bookmark {
    my ($self, $qid) = @_;

    my $ret = $self->is_bookmark($qid)
        ? $self->remove_bookmark($qid)
        : $self->add_bookmark($qid);

    return $ret;
}

# return true if can add a bookmark
sub can_add_bookmark {
    my ($self, $count) = @_;

    my $max = $self->u->get_cap('bookmark_max');
    $count = $count || 1;
    my $bookmark_count = scalar $self->bookmark_items;

    return 0 if (($bookmark_count + $count) > $max);
    return 1;
}

sub delete_all {
    my ( $self, $view, %opts ) = @_;
    my @items;

    # Unless in folder 'Bookmarks', don't fetch any bookmarks
    if ( $view eq 'all' ) {
        @items = $self->all_items;
        push @items, $self->usermsg_sent_items;
    } elsif ( $view eq 'usermsg_recvd' ) {
        @items = $self->usermsg_recvd_items;
    } elsif ( $view eq 'friendplus' ) {
        @items = $self->friendplus_items;
        push @items, $self->birthday_items;
        push @items, $self->befriended_items;
    } elsif ( $view eq 'birthday' ) {
        @items = $self->birthday_items;
    } elsif ( $view eq 'befriended' ) {
        @items = $self->befriended_items;
    } elsif ( $view eq 'entrycomment' ) {
        @items = $self->entrycomment_items;
    } elsif ( $view eq 'bookmark' ) {
        @items = $self->bookmark_items;
    } elsif ( $view eq 'usermsg_sent' ) {
        @items = $self->usermsg_sent_items;
    } elsif ( $view eq 'spam' ) {
        @items = $self->spam_items;
    }

    @items = grep { !$self->is_bookmark($_->qid) } @items
        unless $view eq 'bookmark';

    my @ret;
    foreach my $item (@items) {
        push @ret, {qid => $item->qid};
    }

    my $u = $self->u;
    my $interface = $opts{'interface'};

    LJ::User::UserlogRecord::InboxMassDelete->create( $u,
        'remote' => $u,
        'items'  => scalar @items,
        'method' => 'delete_all',
        'view'   => $view,
        'via'    => $interface,
    );

    # Delete items
    foreach my $item (@items) {
        if ($opts{spam}) {
            my $msg = $item->event->load_message();
            $msg->mark_as_spam();
        }
        $item->delete;
    }

    return @ret;
}

sub delete_all_from_sender {
    my ( $self, $senderid ) = @_;
    my @items;

    @items = grep { $_->event->class ne "LJ::Event::UserMessageSent" } grep {$_->event} $self->items;

    @items = grep { !$self->is_bookmark($_->qid) } @items;

    my @ret;
    # Delete items
    foreach my $item (@items) {
        next unless $item->event->arg2 == $senderid;
        push @ret, {qid => $item->qid};
        $item->delete;
    }

    return @ret;
}

sub mark_all_read {
    my ( $self, $view ) = @_;
    my @items;

    # Only get items in currently viewed folder and subfolders
    if ( $view eq 'all' ) {
        @items = $self->all_items;
        push @items, $self->usermsg_sent_items;
    } elsif ( $view eq 'usermsg_recvd' ) {
        @items = $self->usermsg_recvd_items;
    } elsif ( $view eq 'friendplus' ) {
        @items = $self->friendplus_items;
        push @items, $self->birthday_items;
        push @items, $self->befriended_items;
    } elsif ( $view eq 'birthday' ) {
        @items = $self->birthday_items;
    } elsif ( $view eq 'befriended' ) {
        @items = $self->befriended_items;
    } elsif ( $view eq 'entrycomment' ) {
        @items = $self->entrycomment_items;
    } elsif ( $view eq 'bookmark' ) {
        @items = $self->bookmark_items;
    } elsif ( $view eq 'usermsg_sent' ) {
        @items = $self->usermsg_sent_items;
    }

    # Mark read
    $_->mark_read foreach @items;
    return @items;
}

# Copy archive notice to inbox
# Needed when bookmarking a notice that only lives in archive
sub ensure_queued {
    my ($self, $qid) = @_;

    my $u = $self->u
        or die "No user object";

    my $sth = $u->prepare
        ("SELECT userid, qid, journalid, etypeid, arg1, arg2, state, createtime " .
         "FROM notifyarchive WHERE userid=? AND qid=?");
    $sth->execute($u->{userid}, $qid);
    die $sth->errstr if $sth->err;

    my $row = $sth->fetchrow_hashref;
    if ($row) {
        my %item = (qid        => $row->{qid},
                    userid     => $row->{userid},
                    journalid  => $row->{journalid},
                    etypeid    => $row->{etypeid},
                    arg1       => $row->{arg1},
                    arg2       => $row->{arg2},
                    state      => 'R',
                    createtime => $row->{createtime});

        # insert this event into the notifyqueue table
        $u->do("INSERT IGNORE INTO notifyqueue (" . join(",", keys %item) . ") VALUES (" .
               join(",", map { '?' } values %item) . ")", undef, values %item)
            or die $u->errstr;

        # invalidate memcache
        $self->expire_cache;
    }

    return;
}

# return a count of a subset of notificationitems
sub subset_unread_count {
    my ($self, @subset) = @_;

    my %subset_events = map { "LJ::Event::" . $_ => 1 } @subset;
    my @events = grep { $subset_events{$_->event->class} && $_->unread } grep {$_->event} $self->items;
    return scalar @events;
}

sub all_event_count {
    my $self = shift;

    my @events = grep { $_->event->class ne 'LJ::Event::UserMessageSent' && $_->unread } grep {$_->event} $self->items;
    return scalar @events;
}

sub friend_event_count {
    my $self = shift;
    return $self->subset_unread_count(friend_event_list());
}

sub friendplus_event_count {
    my $self = shift;
    return $self->subset_unread_count(friendplus_event_list());
}

sub entrycomment_event_count {
    my $self = shift;
    return $self->subset_unread_count(entrycomment_event_list());
}

sub usermsg_recvd_event_count {
    my $self = shift;
    my @events = ('UserMessageRecvd' );
    return $self->subset_unread_count(@events);
}

sub usermsg_sent_event_count {
    my $self = shift;
    my @events = ('UserMessageSent' );
    return $self->subset_unread_count(@events);
}

sub spam_event_count {
    my $self = shift;

    return scalar $self->spam_items();
}

# Methods that return Arrays of Event categories
sub friend_event_list {
    my @events = qw(
                    Befriended
                    InvitedFriendJoins
                    CommunityInvite
                    NewUserpic
                    );
    @events = (@events, (LJ::run_hook('friend_notification_types') || ()));
    return @events;
}

sub friendplus_event_list {
    my @events = qw(
                    Befriended
                    InvitedFriendJoins
                    CommunityInvite
                    NewUserpic
                    NewVGift
                    Birthday
                    );
    @events = (@events, (LJ::run_hook('friend_notification_types') || ()));
    return @events;
}

sub entrycomment_event_list {
    my @events = qw( 
                     JournalNewEntry
                     JournalNewRepost
                     JournalNewComment 
                     );
    return @events;
}

1;
