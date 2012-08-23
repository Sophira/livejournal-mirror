package LJ::Message;
use strict;
use Carp qw/ croak /;

use Class::Autouse qw(
                      LJ::Typemap
                      LJ::NotificationItem
                      );

my %singletons = (); # journalid-msgid


sub new {
    my ($class, $opts) = @_;

    my $self = bless {};

    # fields
    foreach my $f (qw(msgid journalid otherid subject body type parent_msgid
                      timesent userpic preformatted)) {
        $self->{$f} = delete $opts->{$f} if exists $opts->{$f};
    }

    # unknown fields
    croak("Invalid fields: " . join(",", keys %$opts)) if (%$opts);

    # Handle renamed users
    my $other_u = LJ::want_user($self->{otherid});
    if ($other_u && $other_u->is_renamed) {
        $other_u = $other_u->get_renamed_user;
        $self->{otherid} = $other_u->{userid};
    }

    my $journalid = $self->{journalid} || undef;
    my $msgid = $self->{msgid} || undef;

    $self->set_singleton; # only gets set if msgid and journalid defined

    return $self;
}

*load = \&new;

sub send {
    my $self = shift;
    my $errors = shift;
    my $opts = shift || {};

    return 0 unless ($opts->{'nocheck'} || $self->can_send($errors));

    # Set remaining message properties
    # M is the designated character code for Messaging counter
    my $msgid = LJ::alloc_global_counter('M')
                or croak("Unable to allocate global message id");
    $self->set_msgid($msgid);
    $self->set_timesent(time());

    # Send message by writing to DB and triggering event
    if ($self->save_to_db) {
        $self->_send_msg_event;
        $self->_orig_u->rate_log('usermessage', $self->rate_multiple) if !$opts->{'nocheck'}
                                                                         and not $LJ::WHITELIST_SEND_INBOX_MESSAGES{$self->_orig_u->user}
                                                                         and $self->rate_multiple;

        # a parent message will be marked as read automatically 
        # and moved from suspicious folder to inbox if needed
        if ($self->parent_msgid) {
            my $nitem = LJ::NotificationItem->new($self->_orig_u, $self->parent_qid);
            $nitem->mark_read;
        }

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

    my $r_rv = undef;
    $r_rv = $rcpt_u->begin_work unless $same_cluster;

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
           $self->subject_raw || '',
           $self->body_raw    || '',
          );
    if ($u->err) {
        warn($u->errstr);
        return 0;
    }

    return 1;
}

sub _save_msgprop_row_to_db {
    my ($self, $u, $userid) = @_;

    for my $prop (qw(userpic preformatted)){
        my $propval = $self->$prop;
        next unless $propval;
        
        my $tm = $self->typemap;
        my $propid = $tm->class_to_typeid($prop);
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
    my $body = $self->body_raw;
    return LJ::ehtml($body) unless $self->preformatted;
    LJ::CleanHTML::clean_message(\$body);
    return $body;
}

sub userpic {
    my $self = shift;
    return $self->_row_getter("userpic", "msgprop");
}

sub preformatted {
    my $self = shift;
    return $self->_row_getter("preformatted", "msgprop");
}

sub valid {
    my $self = shift;
    # just check a field that requires a db load...
    return $self->type ? 1 : 0;
}

sub qid {
    my $self = shift;
    unless ($self->{qid}) {
        my $u = $self->_orig_u;
        my $sth = $u->prepare( "select qid from notifyqueue where userid=? and arg1=?" );
        $sth->execute( $self->journalid, $self->msgid );
        $self->{qid} = $sth->fetchrow_array();
    }
    return $self->{qid};
}

sub parent_qid {
    my $self = shift;
    unless ($self->{qid}) {
        my $u = $self->_orig_u;
        my $sth = $u->prepare( "select qid from notifyqueue where userid=? and arg1=?" );
        $sth->execute( $self->journalid, $self->parent_msgid );
        $self->{qid} = $sth->fetchrow_array();
    }
    return $self->{qid};
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
                body userpic preformatted)) {
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
        push @$errors, LJ::Lang::ml('error.message.yourself');
    }

    # Can only send to other individual users
    unless ($ru->is_person || $ru->is_identity) {
        push @$errors, LJ::Lang::ml('error.message.individual', { 'ljuser' => $ru->ljuser_display });
        return 0;
    }

    # Can not send to deleted or expunged journals
    if ($ru->is_deleted || $ru->is_expunged) {
        push @$errors,
             $ru->is_deleted
                ? LJ::Lang::ml('error.message.deleted', { 'ljuser' => $ru->ljuser_display })
                : LJ::Lang::ml('error.message.expunged', { 'ljuser' => $ru->ljuser_display });
        return 0;
    }

    # Will target user accept messages from sender
    unless ($ru->can_receive_message($ou)) {
        push @$errors, LJ::Lang::ml('error.message.canreceive', { 'ljuser' => $ru->ljuser_display });
        return 0;
    }

    # Will this message put sender over rate limit
    unless ($LJ::WHITELIST_SEND_INBOX_MESSAGES{$ou->user}
            || $self->rate_multiple && $ou->rate_check('usermessage', $self->rate_multiple) ) {
        my $up;
        $up = LJ::run_hook('upgrade_message', $ou, 'message');
        $up = "<br />$up" if ($up);
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
    my $getter;
    {
        no strict 'refs';
        $getter = *{$class . "::_get_${table}_rows"};
    }
    my @rows = $self->$getter(@msglist);
    
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
# called by preload_rows
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
            my $row = LJ::MemCache::array_to_hash('usermsgprop', $array);
            next unless $row;

            my (undef, $uid, $msgid) = split(":", $key);

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

    my $tm = __PACKAGE__->typemap;
    my %props = map {$tm->class_to_typeid($_) => $_} qw(userpic preformatted);
    my $propid = join ',', keys(%props);
    my $where = join(" OR ", @where);
    my $sth = $u->prepare
        ( "SELECT journalid, msgid, propval, propid FROM usermsgprop WHERE propid IN ($propid) AND ($where)" );
    $sth->execute(@vals);

    my %loaded;
    while (my $row = $sth->fetchrow_hashref) {
        my $uid = $row->{journalid};
        my $msgid = $row->{msgid};

        # update our needs
        $have{$uid}->{$msgid} = { journalid => $uid, msgid => $msgid }
            unless $have{$uid}->{$msgid};
        $have{$uid}->{$msgid}->{$props{$row->{'propid'}}} = $row->{'propval'};
#        delete $need{$uid}->{$msgid};
#        delete $need{$uid} unless %{$need{$uid}};
        $loaded{$uid}->{$msgid} = 1;
        # update memcache
    }


    for my $uid (keys(%loaded)){
        for my $msgid (keys(%loaded)){
            my $memkey = [$uid, "msgprop:$uid:$msgid"];
            LJ::MemCache::set($memkey, LJ::MemCache::array_to_hash("usermsgprop", $have{$uid}->{$msgid} ));
        }
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

    LJ::set_rel($self->_orig_u, $self->other_u, 'D');                                                                                                               

    LJ::User::UserlogRecord::SpamSet->create( $self->_orig_u,
        'spammerid' => $self->otherid );

    $self->_orig_u->ban_user($self->other_u);    
            
    return 1;

}

# <LJFUNC>
# name: LJ::ratecheck_multi
# class: web
# des: takes a list of msg objects and sees if they will collectively pass the
#      rate limit check.
# returns: 1 for success, 0 for failure
# </LJFUNC>
sub ratecheck_multi {
    my %opts = @_;

    my $u = LJ::want_user($opts{userid});
    my @msg_list = @{$opts{msg_list}};

    my $rate_total = 0;

    foreach my $msg (@msg_list) {
        $rate_total += $msg->rate_multiple;
    }

    return 1 if ($rate_total == 0);
    return $u->rate_check('usermessage', $rate_total);
}

1;
