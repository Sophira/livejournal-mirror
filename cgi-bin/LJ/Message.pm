package LJ::Message;
use strict;
use Carp qw/ croak /;

use Class::Autouse qw(
                      LJ::Typemap
                      );

my %singletons = (); # journalid-msgid


sub new {
    my ($class, $opts) = @_;

    my $self = bless {};

    # fields
    foreach my $f (qw(msgid journalid otherid subject body type parent_msgid
                      timesent userpic)) {
        $self->{$f} = delete $opts->{$f} if exists $opts->{$f};
    }

    # unknown fields
    croak("Invalid fields: " . join(",", keys %$opts)) if (%$opts);

    my $journalid = $self->{journalid} || undef;
    my $msgid = $self->{msgid} || undef;

    $self->set_singleton; # only gets set if msgid and journalid defined

    return $self;
}

*load = \&new;

sub send {
    my $self = shift;
    my $errors = shift;

    return 0 unless ($self->can_send($errors));

    # Set remaining message properties
    # M is the designated character code for Messaging counter
    my $msgid = LJ::alloc_global_counter('M')
                or croak("Unable to allocate global message id");
    $self->set_msgid($msgid);
    $self->set_timesent(time());

    # Send message by writing to DB and triggering event
    if ($self->save_to_db) {
        $self->_send_msg_event;
        $self->_orig_u->rate_log('usermessage', $self->rate_multiple) if $self->rate_multiple;
        return 1;
    } else {
        return 0;
    }
}

sub _send_msg_event {
    my ($self) = @_;

    my $msgid = $self->msgid;
    my $ou = $self->_orig_u;
    my $ru = $self->_rcpt_u;
    LJ::Event::UserMessageSent->new($ou, $msgid, $ru)->fire;
    LJ::Event::UserMessageRecvd->new($ru, $msgid, $ou)->fire;
}

# Write message data to tables while ensuring everything completes
sub save_to_db {
    my ($self) = @_;

    die "Missing message ID" unless ($self->msgid);

    my $orig_u = $self->_orig_u;
    my $rcpt_u = $self->_rcpt_u;

    # Users on the same cluster share the DB handle so only a single
    # transaction will exist
    my $same_cluster = $orig_u->clusterid eq $rcpt_u->clusterid;

    # Begin DB Transaction
    my $o_rv = $orig_u->begin_work;
    my $r_rv = $rcpt_u->begin_work unless $same_cluster;

    # Write to DB
    my $orig_write = $self->_save_sender_message;
    my $rcpt_write = $self->_save_recipient_message;
    if ($orig_write && $rcpt_write) {
        $orig_u->commit;
        $rcpt_u->commit unless $same_cluster;
        return 1;
    } else {
        $orig_u->rollback;
        $rcpt_u->rollback unless $same_cluster;
        return 0;
    }

}

sub _save_sender_message {
    my ($self) = @_;

    return $self->_save_db_message('out');
}
sub _save_recipient_message {
    my ($self) = @_;

    return $self->_save_db_message('in');
}
sub _save_db_message {
    my ($self, $type) = @_;

    # Message is being sent or received
    # set userid and otherid as appropriate
    my ($u, $userid, $otherid);
    if ($type eq 'out') {
        $u = $self->_orig_u;
        $userid = $self->journalid;
        $otherid = $self->otherid;
    } elsif ($type eq 'in') {
        $u = $self->_rcpt_u;
        $userid = $self->otherid;
        $otherid = $self->journalid;
    } else {
        croak("Invalid 'type' passed into _save_db_message");
    }

    return 0 unless $self->_save_msg_row_to_db($u, $userid, $type, $otherid);
    return 0 unless $self->_save_msgtxt_row_to_db($u, $userid);
    return 0 unless $self->_save_msgprop_row_to_db($u, $userid);

    return 1;
}

sub _save_msg_row_to_db {
    my ($self, $u, $userid, $type, $otherid) = @_;

    my $sql = "INSERT INTO usermsg (journalid, msgid, type, parent_msgid, " .
              "otherid, timesent) VALUES (?,?,?,?,?,?)";

    $u->do($sql,
           undef,
           $userid,
           $self->msgid,
           $type,
           $self->parent_msgid,
           $otherid,
           $self->timesent,
          );

    if ($u->err) {
        warn($u->errstr);
        return 0;
    }

    return 1;
}

sub _save_msgtxt_row_to_db {
    my ($self, $u, $userid) = @_;

    my $sql = "INSERT INTO usermsgtext (journalid, msgid, subject, body) " .
              "VALUES (?,?,?,?)";

    $u->do($sql,
           undef,
           $userid,
           $self->msgid,
           $self->subject_raw,
           $self->body_raw,
          );
    if ($u->err) {
        warn($u->errstr);
        return 0;
    }

    return 1;
}

sub _save_msgprop_row_to_db {
    my ($self, $u, $userid) = @_;

    my $propval = $self->userpic;

    if ($propval) {
        my $tm = $self->typemap;
        my $propid = $tm->class_to_typeid('userpic');
        my $sql = "INSERT INTO usermsgprop (journalid, msgid, propid, propval) " .
                  "VALUES (?,?,?,?)";

        $u->do($sql,
               undef,
               $userid,
               $self->msgid,
               $propid,
               $propval,
              );
        if ($u->err) {
            warn($u->errstr);
            return 0;
        }
    }

    return 1;
}

#############
#  Accessors
#############
sub journalid {
    my $self = shift;
    return $self->{journalid};
}

sub msgid {
    my $self = shift;
    return $self->{msgid};
}

sub _orig_u {
    my $self = shift;
    return LJ::want_user($self->journalid);
}

sub _rcpt_u {
    my $self = shift;

    return LJ::want_user($self->otherid);
}

sub type {
    my $self = shift;
    return $self->_row_getter("type", "msg");
}

sub parent_msgid {
    my $self = shift;
    return $self->_row_getter("parent_msgid", "msg");
}

sub otherid {
    my $self = shift;
    return $self->_row_getter("otherid", "msg");
}

sub other_u {
    my $self = shift;
    return LJ::want_user($self->otherid);
}

sub timesent {
    my $self = shift;
    return $self->_row_getter("timesent", "msg");
}

sub subject_raw {
    my $self = shift;
    return $self->_row_getter("subject", "msgtext");
}

sub subject {
    my $self = shift;
    return LJ::ehtml($self->subject_raw) || "(no subject)";
}

sub body_raw {
    my $self = shift;
    return $self->_row_getter("body", "msgtext");
}

sub body {
    my $self = shift;
    return LJ::ehtml($self->body_raw);
}

sub userpic {
    my $self = shift;
    return $self->_row_getter("userpic", "msgprop");
}

sub valid {
    my $self = shift;
    # just check a field that requires a db load...
    return $self->type ? 1 : 0;
}

#############
#  Setters
#############

sub set_msgid {
    my ($self, $val) = @_;

    $self->{msgid} = $val;
}

sub set_timesent {
    my ($self, $val) = @_;

    $self->{timesent} = $val;
}

###################
#  Object Methods
###################

sub _row_getter {
    my ($self, $member, $table) = @_;

    return $self->{$member} if $self->{$member};
    __PACKAGE__->preload_rows($table, $self) unless $self->{"_loaded_${table}_row"};
    return $self->{$member};
}

sub absorb_row {
    my ($self, $table, %row) = @_;

    foreach (qw(journalid type parent_msgid otherid timesent state subject
                body userpic)) {
        if (exists $row{$_}) {
            $self->{$_} = $row{$_};
            $self->{"_loaded_${table}_row"} = 1;
        }
    }
    $self->set_singleton;
}

sub set_singleton {
    my ($self) = @_;

    my $msgid = $self->msgid;
    my $uid = $self->journalid;

    if ($msgid && $uid) {
        $singletons{$uid}->{$msgid} = $self;
    }
}

# Can user reply to this message
# Return true if user received a matching message with type 'in'
sub can_reply {
    my ($self, $msgid, $remote_id) = @_;

    if ($self->journalid == $remote_id &&
        $self->msgid == $msgid &&
        $self->type eq 'in') {
        return 1;
    }

    return 0;
}

# Can user send a message to the target user
# Write errors to errors array passed in
sub can_send {
    my $self = shift;
    my $errors = shift;

    my $msgid = $self->msgid;
    my $ou = $self->_orig_u;
    my $ru = $self->_rcpt_u;

    # Can't send to yourself
    if ($ou->equals($ru)) {
        push @$errors, "Stop trying to message yourself, we're not that kind of service";
    }

    # Can only send to other individual users
    unless ($ru->is_person || $ru->is_identity) {
        push @$errors, "Message can only be sent to individual user, not " . $ru->ljuser_display;
        return 0;
    }

    # Will target user accept messages from sender
    unless ($ru->can_receive_message($ou)) {
        push @$errors, "Message can not be sent to " . $ru->ljuser_display;
        return 0;
    }

    # Will this message put sender over rate limit
    unless ($self->rate_multiple && $ou->rate_check('usermessage', $self->rate_multiple)) {
        my $up;
        $up = "<br /><a href='$LJ::SITEROOT/manage/payments/'>Upgrade your account</a> to increase your message limit."
            unless ($ou->in_class('paid'));
        push @$errors, "This message will exceed your limit and cannot be sent.$up";
        return 0;
    }

    return 1;
}

# Return the multiple to apply to the rate limit
# The base is 1, but sending messages to non-friends will have a greater multiple
# If multiple returned is 0, no need to check rate limit
sub rate_multiple {
    my $self = shift;

    my $ou = $self->_orig_u;
    my $ru = $self->_rcpt_u;

    return 10 unless ($ru->has_friend($ou) || $self->{parent_msgid});
    return 1;
}

###################
#  Class Methods
###################

sub reset_singletons {
    %singletons = ();
}

# returns an arrayref of unloaded comment singletons
sub unloaded_singletons {
    my ($self, $table) = @_;
    my @singletons;
    push @singletons, values %{$singletons{$_}} foreach keys %singletons;
    return grep { ! $_->{"_loaded_${table}_row"} } @singletons;
}

sub preload_rows {
    my ($class, $table, $self) = @_;

    my @objlist = $self->unloaded_singletons($table);
    my @msglist = (map  { [ $_->journalid, $_->msgid ] }
                     grep { ! $_->{"_loaded_${table}_row"} }
                       @objlist);

    my @rows = eval "${class}::_get_${table}_rows(\$self, \@msglist)";

    # make a mapping of journalid-msgid=> $row
    my %row_map = map { join("-", $_->{journalid}, $_->{msgid}) => $_ } @rows;

    foreach my $msg (@objlist) {
        my $row = $row_map{join("-", $msg->journalid, $msg->msgid)};
        next unless $row;

        # absorb row into given LJ::Message object
        $msg->absorb_row($table, %$row);
    }
}

# get the core message data from memcache or the DB
sub _get_msg_rows {
    my ($self, @items) = @_; # obj, [ journalid, msgid ], ...

    # what do we need to load per-journalid
    my %need    = ();
    my %have    = ();

    # get what is in memcache
    my @keys = ();
    foreach my $msg (@items) {
        my ($uid, $msgid) = @$msg;

        # we need this for now
        $need{$uid}->{$msgid} = 1;

        push @keys, [$uid, "msg:$uid:$msgid"];
    }

    # return an array of rows preserving order in which they were requested
    my $ret = sub {
        my @ret = ();
        foreach my $it (@items) {
            my ($uid, $msgid) = @$it;
            push @ret, $have{$uid}->{$msgid};
        }
        return @ret;
    };

    my $mem = LJ::MemCache::get_multi(@keys);
    if ($mem) {
        while (my ($key, $array) = each %$mem) {
            my $row = LJ::MemCache::array_to_hash('usermsg', $array);
            next unless $row;

            my (undef, $uid, $msgid) = split(":", $key);

            # add in implicit keys:
            $row->{journalid} = $uid;
            $row->{msgid} = $msgid;

            # update our needs
            $have{$uid}->{$msgid} = $row;
            delete $need{$uid}->{$msgid};
            delete $need{$uid} unless %{$need{$uid}};
        }

        # was everything in memcache?
        return $ret->() unless %need;
    }


    # Only preload messages on the same cluster as the current message
    my $u = LJ::want_user($self->journalid);

    # build up a valid where clause for this cluster's select
    my @vals = ();
    my @where = ();
    foreach my $jid (keys %need) {
        my @msgids = keys %{$need{$jid}};
        next unless @msgids;

        my $bind = join(",", map { "?" } @msgids);
        push @where, "(journalid=? AND msgid IN ($bind))";
        push @vals, $jid => @msgids;
    }
    return $ret->() unless @vals;

    my $where = join(" OR ", @where);
    my $sth = $u->prepare
        ( "SELECT journalid, msgid, type, parent_msgid, otherid, timesent " .
          "FROM usermsg WHERE $where");
    $sth->execute(@vals);

    while (my $row = $sth->fetchrow_hashref) {
        my $uid = $row->{journalid};
        my $msgid = $row->{msgid};

        # update our needs
        $have{$uid}->{$msgid} = $row;
        delete $need{$uid}->{$msgid};
        delete $need{$uid} unless %{$need{$uid}};

        # update memcache
        my $memkey = [$uid, "msg:$uid:$msgid"];
        LJ::MemCache::set($memkey, LJ::MemCache::hash_to_array('usermsg', $row));
    }

    return $ret->();
}

# get the text message data from memcache or the DB
sub _get_msgtext_rows {
    my ($self, @items) = @_; # obj, [ journalid, msgid ], ...

    # what do we need to load per-journalid
    my %need    = ();
    my %have    = ();

    # get what is in memcache
    my @keys = ();
    foreach my $msg (@items) {
        my ($uid, $msgid) = @$msg;

        # we need this for now
        $need{$uid}->{$msgid} = 1;

        push @keys, [$uid, "msgtext:$uid:$msgid"];
    }

    # return an array of rows preserving order in which they were requested
    my $ret = sub {
        my @ret = ();
        foreach my $it (@items) {
            my ($uid, $msgid) = @$it;
            push @ret, $have{$uid}->{$msgid};
        }
        return @ret;
    };

    my $mem = LJ::MemCache::get_multi(@keys);
    if ($mem) {
        while (my ($key, $row) = each %$mem) {
            next unless $row;

            my (undef, $uid, $msgid) = split(":", $key);

            # update our needs
            $have{$uid}->{$msgid} = { journalid => $uid, msgid => $msgid, subject => $row->[0], body => $row->[1] };
            delete $need{$uid}->{$msgid};
            delete $need{$uid} unless %{$need{$uid}};
        }

        # was everything in memcache?
        return $ret->() unless %need;
    }


    # Only preload messages on the same cluster as the current message
    my $u = LJ::want_user($self->journalid);

    # build up a valid where clause for this cluster's select
    my @vals = ();
    my @where = ();
    foreach my $jid (keys %need) {
        my @msgids = keys %{$need{$jid}};
        next unless @msgids;

        my $bind = join(",", map { "?" } @msgids);
        push @where, "(journalid=? AND msgid IN ($bind))";
        push @vals, $jid => @msgids;
    }
    return $ret->() unless @vals;

    my $where = join(" OR ", @where);
    my $sth = $u->prepare
        ( "SELECT journalid, msgid, subject, body FROM usermsgtext WHERE $where" );
    $sth->execute(@vals);

    while (my $row = $sth->fetchrow_hashref) {
        my $uid = $row->{journalid};
        my $msgid = $row->{msgid};

        # update our needs
        $have{$uid}->{$msgid} = $row;
        delete $need{$uid}->{$msgid};
        delete $need{$uid} unless %{$need{$uid}};

        # update memcache
        my $memkey = [$uid, "msgtext:$uid:$msgid"];
        LJ::MemCache::set($memkey, [ $row->{'subject'}, $row->{'body'} ]);
    }

    return $ret->();
}

# get the userpic data from memcache or the DB
sub _get_msgprop_rows {
    my ($self, @items) = @_; # obj, [ journalid, msgid ], ...

    # what do we need to load per-journalid
    my %need    = ();
    my %have    = ();

    # get what is in memcache
    my @keys = ();
    foreach my $msg (@items) {
        my ($uid, $msgid) = @$msg;

        # we need this for now
        $need{$uid}->{$msgid} = 1;

        push @keys, [$uid, "msgprop:$uid:$msgid"];
    }

    # return an array of rows preserving order in which they were requested
    my $ret = sub {
        my @ret = ();
        foreach my $it (@items) {
            my ($uid, $msgid) = @$it;
            push @ret, $have{$uid}->{$msgid};
        }
        return @ret;
    };

    my $mem = LJ::MemCache::get_multi(@keys);
    if ($mem) {
        while (my ($key, $array) = each %$mem) {
            my $row = LJ::MemCache::array_to_hash('usermsg', $array);
            next unless $row;

            my (undef, $uid, $msgid) = split(":", $key);

            # update our needs
            $have{$uid}->{$msgid} = { userpic => $row };
            delete $need{$uid}->{$msgid};
            delete $need{$uid} unless %{$need{$uid}};
        }

        # was everything in memcache?
        return $ret->() unless %need;
    }


    # Only preload messages on the same cluster as the current message
    my $u = LJ::want_user($self->journalid);

    # build up a valid where clause for this cluster's select
    my @vals = ();
    my @where = ();
    foreach my $jid (keys %need) {
        my @msgids = keys %{$need{$jid}};
        next unless @msgids;

        my $bind = join(",", map { "?" } @msgids);
        push @where, "(journalid=? AND msgid IN ($bind))";
        push @vals, $jid => @msgids;
    }
    return $ret->() unless @vals;

    my $tm = __PACKAGE__->typemap;
    my $propid = $tm->class_to_typeid('userpic');
    my $where = join(" OR ", @where);
    my $sth = $u->prepare
        ( "SELECT journalid, msgid, propval FROM usermsgprop WHERE propid = ? AND ($where)" );
    $sth->execute($propid, @vals);

    while (my $row = $sth->fetchrow_hashref) {
        my $uid = $row->{journalid};
        my $msgid = $row->{msgid};
        $row->{'userpic'} = $row->{'propval'};

        # update our needs
        $have{$uid}->{$msgid} = $row;
        delete $need{$uid}->{$msgid};
        delete $need{$uid} unless %{$need{$uid}};

        # update memcache
        my $memkey = [$uid, "msgprop:$uid:$msgid"];
        LJ::MemCache::set($memkey, $row->{'userpic'});
    }

    return $ret->();
}

# get the typemap for usermsprop
sub typemap {
    my $self = shift;

    return LJ::Typemap->new(
        table       => 'usermsgproplist',
        classfield  => 'name',
        idfield     => 'propid',
    );
}

# <LJFUNC>
# name: LJ::mark_as_spam
# class: web
# des: Copies a message into the global [dbtable[spamreports]] table.
# returns: 1 for success, 0 for failure
# </LJFUNC>
sub mark_as_spam {
    my $self = shift;

    my $msgid = $self->msgid;
    return 0 unless $msgid;

    # get info we need
    my ($subject, $body, $posterid) = ($self->subject, $self->body, $self->other_u->userid);
    return 0 unless $body;

    # insert into spamreports
    my $dbh = LJ::get_db_writer();
    $dbh->do('INSERT INTO spamreports (reporttime, posttime, ip, journalid, ' .
             'posterid, report_type, subject, body) ' .
             'VALUES (UNIX_TIMESTAMP(), ?, ?, ?, ?, ?, ?, ?)',
             undef, $self->timesent, undef, $self->journalid, $posterid,
             'message', $subject, $body);
    return 0 if $dbh->err;
    return 1;

}

1;
