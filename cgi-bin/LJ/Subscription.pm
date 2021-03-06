package LJ::Subscription;
use strict;
use Carp qw(croak confess cluck);
use Class::Autouse qw(
                      LJ::NotificationMethod
                      LJ::Typemap
                      LJ::Event
                      LJ::Subscription::Pending
                      LJ::Subscription::Group
                      );

use constant {
              INACTIVE => 1 << 0, # user has deactivated
              };

my @subs_fields = qw(userid subid is_dirty journalid etypeid arg1 arg2
                     ntypeid createtime expiretime flags);

sub new_by_id {
    my ($class, $u, $subid) = @_;
    croak "new_by_id requires a valid 'u' object"
        unless LJ::isu($u);
    return if $u->is_expunged;

    croak "invalid subscription id passed"
        unless defined $subid && int($subid) > 0;

    my $row = $u->selectrow_hashref
        ("SELECT userid, subid, is_dirty, journalid, etypeid, " .
         "arg1, arg2, ntypeid, createtime, expiretime, flags " .
         "FROM subs WHERE userid=? AND subid=?", undef, $u->{userid}, $subid);
    die $u->errstr if $u->err;

    return $class->new_from_row($row);
}

sub dump {
    my ($self) = @_;

    return $self->id if $self->id && $self->id != 0;

    my %props = map { $_ => $self->{$_} } @subs_fields;
    return \%props;
}

sub new_from_dump {
    my ($class, $u, $dump) = @_;

    return $class->new_by_id($u, $dump) if ref $dump eq '';
    return bless($dump, $class);
}

sub freeze {
    my $self = shift;
    return "subid-" . $self->owner->{userid} . '-' . $self->id;
}

# can return either a LJ::Subscription or LJ::Subscription::Pending object
sub thaw {
    my ($class, $data, $u, $POST) = @_;

    # valid format?
    return undef unless ($data =~ /^(pending|subid) - $u->{userid} .+ ?(-old)?$/x);

    my ($type, $userid, $subid) = split("-", $data);

    return LJ::Subscription::Pending->thaw($data, $u, $POST) if $type eq 'pending';
    die "Invalid subscription data type: $type" unless $type eq 'subid';

    unless ($u) {
        my $subuser = LJ::load_userid($userid);
        die "no user" unless $subuser;
        $u = LJ::get_authas_user($subuser);
        die "Invalid user $subuser->{user}" unless $u;
    }

    return $class->new_by_id($u, $subid);
}

sub pending { 0 }
sub default_selected { $_[0]->active }

sub query_user_subscriptions {
    my ($class, $u, %filters) = @_;
    croak "subscriptions_of_user requires a valid 'u' object"
        unless LJ::isu($u);

    return if $u->is_expunged;

    my $dbh = LJ::get_cluster_reader($u) or die "cannot get a DB handle";

    my (@conditions, @binds);

    push @conditions, 1;

    foreach my $prop (qw(journalid ntypeid etypeid flags arg1 arg2)) {
        next unless defined $filters{$prop};
        push @conditions, "$prop=?";
        push @binds, $filters{$prop};
    }

    my $conditions = join(' AND ', @conditions);
    return $dbh->selectall_arrayref(
        qq{
            SELECT
                userid, subid, is_dirty, journalid, etypeid,
                arg1, arg2, ntypeid, createtime, expiretime, flags
            FROM subs
            WHERE userid=? AND $conditions
        }, { Slice => {} }, $u->id, @binds
    );
}

sub subscriptions_of_user {
    my ($class, $u) = @_;

    croak "subscriptions_of_user requires a valid 'u' object"
        unless LJ::isu($u);

    return if $u->is_expunged;

    return @{$u->{_subscriptions}} if $u->{_subscriptions};

    my @subs;

    my $val = LJ::MemCache::get('subscriptions:' . $u->id);
    if (defined $val) {
        my @ints = unpack("N*", $val);
        for (my $i = 0; $i < scalar(@ints); $i += 11) {
            my %row;
            @row{@subs_fields} = @ints[$i..$i+10];
            push @subs, $class->new_from_row(\%row);
        }
    } else {
        @subs = map { $class->new_from_row($_) }
            @{ $class->query_user_subscriptions($u) };

        my @ints;
        foreach my $sub (@subs) {
            my %row = %$sub;
            push @ints, @row{@subs_fields};
        }
        LJ::MemCache::set('subscriptions:' . $u->id, pack("N*", @ints));
    }

    @{$u->{_subscriptions}} = @subs;
    return @subs;
}

# Class method
# Look for a subscription matching the parameters: journalu/journalid,
#   ntypeid/method, event/etypeid, arg1, arg2
# Returns a list of subscriptions for this user matching the parameters
# 
# For pages with tons of comments search is divided in two stages:
#   I  prefetch    => 1
#   II postprocess => [$a, $b, $c]
# First stage is done once for request and is needed to fetch and filter out
# active user subscriptions in current journal
# Second stage is done for every comment on page and contains all additional filtering conditions
sub find {
    my ($class, $u, %params) = @_;

    my ($etypeid, $ntypeid, $arg1, $arg2, $flags, $prefetch, $postprocess);

    $prefetch    = delete $params{'prefetch'};
    $postprocess = delete $params{'postprocess'};

    if (my $evt = delete $params{event}) {
        $etypeid = LJ::Event->event_to_etypeid($evt);
    }

    if (my $nmeth = delete $params{method}) {
        $ntypeid = LJ::NotificationMethod->method_to_ntypeid($nmeth);
    }

    $etypeid ||= delete $params{etypeid};
    $ntypeid ||= delete $params{ntypeid};

    $flags   = delete $params{flags};

    my $journalid = delete $params{journalid};
    $journalid ||= LJ::want_userid(delete $params{journal}) if defined $params{journal};
    
    $arg1 = delete $params{arg1};
    $arg2 = delete $params{arg2};

    my $require_active = delete $params{require_active} ? 1 : 0;

    croak "Invalid parameters passed to ${class}->find" if keys %params;

    return () if defined $arg1 && $arg1 =~ /\D/;
    return () if defined $arg2 && $arg2 =~ /\D/;

    my @subs;
    if ( $postprocess ) {
        @subs = @$postprocess;
    } else {
        @subs = $class->subscriptions_of_user($u);
    }

    unless ( $postprocess ) {
        # This filter should be at first place because we need not to check
        # subscriptions in other journals and this can save us from tons of work later
        # Matters on pages with comments, when both journalid and require_active
        # conditions are active
        @subs = grep { $_->journalid == $journalid } @subs if defined $journalid;

        @subs = grep { $_->active } @subs if $require_active;
    }

    return @subs if $prefetch;

    # filter subs on each parameter
    @subs = grep { $_->ntypeid   == $ntypeid }   @subs if $ntypeid;
    @subs = grep { $_->{etypeid}   == $etypeid }   @subs if $etypeid;
    @subs = grep { $_->flags     == $flags }     @subs if defined $flags;

    @subs = grep { $_->{arg1} == $arg1 }           @subs if defined $arg1;
    @subs = grep { $_->{arg2} == $arg2 }           @subs if defined $arg2;

    return @subs;
}

# Instance method
# Deactivates a subscription. If this is not a "tracking" subscription,
# it will delete it instead.
sub deactivate {
    my $self = shift;

    my %opts = @_;
    my $force = delete $opts{force}; # force-delete

    croak "Invalid args" if scalar keys %opts;

    my $subid = $self->id
        or croak "Invalid subsciption";

    my $u = $self->owner;

    # if it's the inbox method, deactivate/delete the other notification methods too
    my @to_remove = ();

    my @subs = $self->corresponding_subs;

    foreach my $subscr (@subs) {
        # Don't deactivate if the Inbox is always subscribed to
        my $always_checked = $subscr->event_class->always_checked ? 1 : 0;
        unless ($force) {
            # delete non-inbox methods if we're deactivating
            if ($subscr->method eq 'LJ::NotificationMethod::Inbox' && !$always_checked) {
                $subscr->_deactivate;
            } else {
                $subscr->delete;
            }
        } else {
            $subscr->delete;
        }
    }
}

# deletes a subscription
sub delete {
    my $self = shift;
    my $u = $self->owner;

    my @subs = $self->corresponding_subs;
    foreach my $subscr (@subs) {
        $u->do("DELETE FROM subs WHERE subid=? AND userid=?", undef, $subscr->id, $u->id);
    }

    # delete from cache in user
    undef $u->{_subscriptions};

    $self->invalidate_cache($u);

    return 1;
}

# class method, nukes all subs for a user
sub delete_all_subs {
    my ($class, $u) = @_;

    return if $u->is_expunged;
    $u->do("DELETE FROM subs WHERE userid = ?", undef, $u->id);
    undef $u->{_subscriptions};

    $class->invalidate_cache($u);

    return 1;
}

# class method, nukes all inactive subs for a user
sub delete_all_inactive_subs {
    my ($class, $u, $dryrun) = @_;

    return if $u->is_expunged;

    my $set = LJ::Subscription::GroupSet->fetch_for_user($u);
    my @inactive_groups = grep { !$_->active } $set->groups;

    unless ($dryrun) {
        $set->drop_group($_) foreach (@inactive_groups);
    }

    return scalar(@inactive_groups);
}

# find matching subscriptions with different notification methods
sub corresponding_subs {
    my $self = shift;

    my @subs = ($self);

    if ($self->method eq 'LJ::NotificationMethod::Inbox') {
        push @subs, $self->owner->find_subscriptions(
                                           journalid => $self->journalid,
                                           etypeid   => $self->etypeid,
                                           arg1      => $self->arg1,
                                           arg2      => $self->arg2,
                                           );
    }

    return @subs;
}

# Class method
sub new_from_row {
    my ($class, $row) = @_;

    return undef unless $row;
    my $self = bless {%$row}, $class;
    # TODO validate keys of row.
    return $self;
}

sub create {
    my ($class, $u, %args) = @_;

    # easier way for eveenttype
    if (my $evt = delete $args{'event'}) {
        $args{etypeid} = LJ::Event->event_to_etypeid($evt);
    }

    # easier way to specify ntypeid
    if (my $ntype = delete $args{'method'}) {
        $args{ntypeid} = LJ::NotificationMethod->method_to_ntypeid($ntype);
    }

    # easier way to specify journal
    if (my $ju = delete $args{'journal'}) {
        $args{journalid} = $ju->{userid} 
            if !$args{journalid} && $ju;
    }

    $args{arg1} ||= 0;
    $args{arg2} ||= 0;

    $args{journalid} ||= 0;

    foreach (qw(ntypeid etypeid)) {
        croak "Required field '$_' not found in call to $class->create" unless defined $args{$_};
    }
    foreach (qw(userid subid createtime)) {
        croak "Can't specify field '$_'" if defined $args{$_};
    }

    my ($existing) = grep {
        $args{etypeid} == $_->{etypeid} &&
        $args{ntypeid} == $_->{ntypeid} &&
        $args{journalid} == $_->{journalid} &&
        $args{arg1} == $_->{arg1} &&
        $args{arg2} == $_->{arg2} &&
        $args{flags} == $_->{flags}
    } $class->subscriptions_of_user($u);

    return $existing 
        if defined $existing;

    my $subid = LJ::alloc_user_counter($u, 'E')
        or die "Could not alloc subid for user $u->{user}";

    $args{subid}      = $subid;
    $args{userid}     = $u->{userid};
    $args{createtime} = time();

    my $self = $class->new_from_row( \%args );

    my @fields;
    foreach (@subs_fields) {
        if (exists( $args{$_} )) {
            push @fields, { name => $_, value => delete $args{$_} };
        }
    }

    croak( "Extra args defined, (" . join( ', ', keys( %args ) ) . ")" ) if keys %args;

    # DELETE FROM subs records with all selected field values
    # without 'subid', 'flags' and 'createtime'.
    my $sql_filter = sub { $_->{'name'} !~ /subid|flags|createtime/ };

    my $sth = $u->prepare( 'DELETE FROM subs WHERE ' .
        join( ' AND ', map { $_->{'name'} . '=?' } grep { $sql_filter->($_) } @fields )
    );

    $sth->execute( map { $_->{'value'} } grep { $sql_filter->($_) } @fields );

    $sth = $u->prepare(
        'INSERT INTO subs (' . join( ',', map { $_->{'name'} } @fields ) . ')' .
            'VALUES (' . join( ',', map {'?'} @fields ) . ')' );

    $sth->execute( map { $_->{'value'} } @fields );
    LJ::errobj($u)->throw if $u->err;

    push @{$u->{_subscriptions}}, $self;

    $self->invalidate_cache($u);

    return $self;
}

# returns a hash of arguments representing this subscription (useful for passing to
# other functions, such as find)
sub sub_info {
    my $self = shift;
    return (
            journalid => $self->journalid,
            etypeid   => $self->etypeid,
            ntypeid   => $self->ntypeid,
            arg1      => $self->arg1,
            arg2      => $self->arg2,
            flags     => $self->flags,
            );
}

# returns a nice HTML description of this current subscription
sub as_html {
    my $self = shift;

    my $evtclass = LJ::Event->class($self->etypeid);
    return undef unless $evtclass;
    return $evtclass->subscription_as_html($self);
}

sub activate {
    my $self = shift;
    $self->clear_flag(INACTIVE);
}

sub _deactivate {
    my $self = shift;
    $self->set_flag(INACTIVE);
}

sub set_flag {
    my ($self, $flag) = @_;

    my $flags = $self->flags;

    # don't bother if flag already set
    return if $flags & $flag;

    $flags |= $flag;

    if ($self->owner && ! $self->pending) {
        $self->owner->do("UPDATE subs SET flags = flags | ? WHERE userid=? AND subid=?", undef,
                         $flag, $self->owner->userid, $self->id);
        die $self->owner->errstr if $self->owner->errstr;

        $self->{flags} = $flags;
        delete $self->owner->{_subscriptions};
    }
}

sub clear_flag {
    my ($self, $flag) = @_;

    my $flags = $self->flags;

    # don't bother if flag already cleared
    return unless $flags & $flag;

    # clear the flag
    $flags &= ~$flag;


    if ($self->owner && ! $self->pending) {
        $self->owner->do("UPDATE subs SET flags = flags & ~? WHERE userid=? AND subid=?", undef,
                         $flag, $self->owner->userid, $self->id);
        die $self->owner->errstr if $self->owner->errstr;

        $self->{flags} = $flags;
        delete $self->owner->{_subscriptions};
    }
}

sub id {
    my $self = shift;

    return $self->{subid};
}

sub createtime {
    my $self = shift;
    return $self->{createtime};
}

sub flags {
    my $self = shift;
    return $self->{flags} || 0;
}

sub active {
    my $self = shift;
    return ! ($self->flags & INACTIVE);
}

sub expiretime {
    my $self = shift;
    return $self->{expiretime};
}

sub journalid {
    my $self = shift;
    return $self->{journalid};
}

sub journal {
    my $self = shift;
    return LJ::load_userid($self->{journalid});
}

sub arg1 {
    my $self = shift;
    return $self->{arg1};
}

sub arg2 {
    my $self = shift;
    return $self->{arg2};
}

sub ntypeid {
    my $self = shift;
    return $self->{ntypeid};
}

sub method {
    my $self = shift;
    return LJ::NotificationMethod->class($self->ntypeid);
}

sub notify_class {
    my $self = shift;
    return LJ::NotificationMethod->class($self->{ntypeid});
}

sub etypeid {
    my $self = shift;
    return $self->{etypeid};
}

sub event_class {
    my $self = shift;
    return LJ::Event->class($self->{etypeid});
}

# returns the owner (userid) of the subscription
sub userid {
    my $self = shift;
    return $self->{userid};
}

sub owner {
    my $self = shift;
    return LJ::load_userid($self->{userid});
}

sub dirty {
    my $self = shift;
    return $self->{is_dirty};
}

sub notification {
    my $subscr = shift;
    my $class = LJ::NotificationMethod->class($subscr->{ntypeid});

    my $note;
    if ($LJ::DEBUG{'official_post_esn'} && $subscr->etypeid == LJ::Event::OfficialPost->etypeid) {
        # we had (are having) some problems with subscriptions to millions of people, so
        # this exists for now for debugging that, without actually emailing/inboxing
        # those people while we debug
        $note = LJ::NotificationMethod::DebugLog->new_from_subscription($subscr, $class);
    } else {
        $note = $class->new_from_subscription($subscr);
    }

    return $note;
}

sub process {
    my ($self, $opts, @events) = @_;
    my $note = $self->notification or return;

    return 1 if $self->etypeid == LJ::Event::OfficialPost->etypeid && $LJ::DISABLED{"officialpost_esn"};

    # process events for unauthorised users;
    return 1 if LJ::Event->class($self->etypeid) eq 'LJ::Event::SupportRequest' && 
                !$self->{userid};

    # significant events (such as SecurityAttributeChanged) must be processed even for inactive users.
    return 1
        unless $self->notify_class->configured_for_user($self->owner)
            || LJ::Event->class($self->etypeid)->is_significant;

    return $note->notify($opts, @events);
}

sub unique {
    my $self = shift;

    my $note = $self->notification or return undef;
    return $note->unique . ':' . $self->owner->{user};
}

# returns true if two subscriptions are equivilant
sub equals {
    my ($self, $other) = @_;

    return 1 if $self->id == $other->id;

    my $match = $self->ntypeid == $other->ntypeid &&
        $self->etypeid == $other->etypeid && $self->flags == $other->flags;

    $match &&= $other->arg1 && ($self->arg1 == $other->arg1) if $self->arg1;
    $match &&= $other->arg2 && ($self->arg2 == $other->arg2) if $self->arg2;

    $match &&= $self->journalid == $other->journalid;

    return $match;
}

sub available_for_user {
    my ($self, $u) = @_;

    $u ||= $self->owner;

    return $self->group->event->available_for_user($u);
}

sub group {
    my ($self) = @_;
    return LJ::Subscription::Group->group_from_sub($self);
}

sub event {
    my ($self) = @_;
    return $self->group->event;
}

sub enabled {
    my ($self) = @_;

    my $ret = $self->group->enabled;
    return $ret;
}

sub invalidate_cache {
    my ($class, $u) = @_;
    LJ::MemCache::delete('subscriptions:'.$u->id);
    LJ::MemCache::delete('subscriptions_count:'.$u->id);
}

package LJ::Error::Subscription::TooMany;
sub fields { qw(subscr u); }

sub as_html { $_[0]->as_string }
sub as_string {
    my $self = shift;
    my $max = $self->field('u')->get_cap('subscriptions');
    return 'The subscription "' . $self->field('subscr')->as_html . '" was not saved because you have' .
        " reached your limit of $max active subscriptions. Subscriptions need to be deactivated before more can be added.";
}

# Too many subscriptions exist, not necessarily active
package LJ::Error::Subscription::TooManySystemMax;
sub fields { qw(subscr u max); }

sub as_html { $_[0]->as_string }
sub as_string {
    my $self = shift;
    my $max = $self->field('max');
    return 'The subscription "' . $self->field('subscr')->as_html . '" was not saved because you have' .
        " more than $max existing subscriptions. Subscriptions need to be completely removed before more can be added.";
}

1;
