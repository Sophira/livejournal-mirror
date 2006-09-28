package LJ::SMS;

# LJ::SMS object
#
# wrangles LJ::SMS::Messages and the app logic associated
# with them...
#
# also contains LJ::Worker class for incoming SMS
#

use strict;
use Carp qw(croak);

sub schwartz_capabilities {
    return qw(LJ::Worker::IncomingSMS);
}

sub load_mapping {
    my $class = shift;
    my %opts = @_;
    my $uid = delete $opts{uid};
    my $num = delete $opts{num};
    croak "invalid options passed to load_mapping: " . join(",", keys %opts)
        if %opts;
    croak "can't pass both uid and num to load_mapping"
        if defined $uid && defined $num;
    croak "invalid userid: $uid"
        if defined $uid && $uid !~ /^\d+$/;
    croak "invalid number: $num"
        if defined $num && $num !~ /^\+?\d+$/;

    my $dbr = LJ::get_db_reader()
        or die "unable to contact db reader";

    # load by userid if that's what was specified
    if ($uid) {
        my $row = $LJ::SMS::REQ_CACHE_MAP_UID{$uid};

        unless (ref $row) {
            $row = $dbr->selectrow_hashref
                ("SELECT number, userid, verified, instime " .
                 "FROM smsusermap WHERE userid=?", undef, $uid) || {};
            die $dbr->errstr if $dbr->err;

            # set whichever cache bits we can
            $LJ::SMS::REQ_CACHE_MAP_UID{$uid} = $row;
            $LJ::SMS::REQ_CACHE_MAP_NUM{$row->{number}} = $row if $row->{number};
        }

        # return row hashref
        return $row;
    }

    # load by msisdn 'num'
    if ($num) {
        my $row = $LJ::SMS::REQ_CACHE_MAP_NUM{$num};

        unless (ref $row) {
            $row = $dbr->selectrow_hashref
                ("SELECT number, userid, verified, instime " .
                 "FROM smsusermap WHERE number=?", undef, $num) || {};
            die $dbr->errstr if $dbr->err;

            # set whichever cache bits we can
            $LJ::SMS::REQ_CACHE_MAP_NUM{$num} = $row;
            $LJ::SMS::REQ_CACHE_MAP_UID{$row->{userid}} = $row if $row->{userid};
        }

        return $row;
    }

    return undef;
}

sub replace_mapping {
    my ($class, $uid, $num, $verified) = @_;
    $uid = LJ::want_userid($uid);
    $verified = uc($verified);
    croak "invalid userid" unless int($uid) > 0;
    if ($num) {
        croak "invalid number" unless $num =~ /^\+\d+$/;
        croak "invalid verified flag" unless $verified =~ /^[YN]$/;
    }

    my $dbh = LJ::get_db_writer();

    # need to get currently mapped number so we can invalidate the reverse number lookup cache
    my $old_num = uid_to_num($uid);
    delete $LJ::SMS::REQ_CACHE_MAP_NUM{$old_num} if $old_num;

    # invalid user -> num cache
    delete $LJ::SMS::REQ_CACHE_MAP_UID{$uid};

    if ($num) {
        return $dbh->do("REPLACE INTO smsusermap SET number=?, userid=?, verified=?, instime=UNIX_TIMESTAMP()",
                        undef, $num, $uid, $verified);
    } else {
        return $dbh->do("DELETE FROM smsusermap WHERE userid=?", undef, $uid);
    }
}

# get the userid of a given number from smsusermap
sub num_to_uid {
    my $class = shift;
    my $num   = shift;
    my %opts  = @_;
    my $verified_only = delete $opts{verified_only};
    $verified_only = defined $verified_only ? $verified_only : 1;

    my $row = LJ::SMS->load_mapping( num => $num );

    if ($verified_only) {
        return $row->{verified} eq 'Y' ? $row->{number} : undef;
    }

    return $row->{userid};
}

sub uid_to_num {
    my $class = shift;
    my $uid  = LJ::want_userid(shift);
    my %opts  = @_;
    my $verified_only = delete $opts{verified_only};
    $verified_only = defined $verified_only ? $verified_only : 1;

    my $row = LJ::SMS->load_mapping( uid => $uid );

    if ($verified_only) {
        return $row->{verified} eq 'Y' ? $row->{number} : undef;
    }

    return $row->{number};
}

sub sent_message_count {
    my $class = shift;
    my $u = shift;
    croak "invalid user object for message count"
        unless LJ::isu($u);

    my %opts = @_;

    return $class->message_count($u, status => 'success', type => 'outgoing', %opts);
}

sub message_count {
    my $class = shift;
    my $u = shift;
    croak "invalid user object for message count"
        unless LJ::isu($u);

    my %opts  = @_;

    my $status = delete $opts{status};
    croak "invalid status: $status"
        if $status && $status !~ /^(success|error|unknown)$/;

    my $type = delete $opts{type};
    croak "invalid message type: $type"
        if $type && $type !~ /^(incoming|outgoing|unknown)$/;

    my $class_key       = delete $opts{class_key};
    my $class_key_like  = delete $opts{class_key_like};
    my $max_age         = delete $opts{max_age};

    croak "must pass class_key OR class_key_like" if ($class_key || $class_key_like) &&
         ! ($class_key xor $class_key_like);

    croak "invalid parameters: " . join(",", keys %opts)
        if %opts;

    my @where_sql = ();
    my @where_vals = ();
    if ($status) {
        push @where_sql, "status=?";
        push @where_vals, $status;
    }
    if ($type) {
        push @where_sql, "type=?";
        push @where_vals, $type;
    }
    if ($class_key) {
        push @where_sql, "class_key=?";
        push @where_vals, $class_key;
    }
    if ($class_key_like) {
        $class_key_like = $u->quote($class_key_like);
        push @where_sql, "class_key LIKE $class_key_like";
    }
    if ($max_age) {
        my $q_max_age = int($max_age);
        my $timestamp = $LJ::_T_SMS_NOTIF_LIMIT_TIME_OVERRIDE ? time() : 'UNIX_TIMESTAMP()';
        push @where_sql, "timecreate>($timestamp-$q_max_age)";
        # don't push @where_vals
    }
    my $where_sql = @where_sql ? " AND " . join(" AND ", @where_sql) : "";

    my ($ct) = $u->selectrow_array
        ("SELECT COUNT(*) FROM sms_msg WHERE userid=?$where_sql",
         undef, $u->id, @where_vals);
    die $u->errstr if $u->err;

    return $ct+0;
}

# given a number of $u object, returns whether there is a verified mapping
sub num_is_verified {
    my $class = shift;
    my $num   = shift;

    # load smsusermap row via API, then see if the number was verified
    my $row = LJ::SMS->load_mapping(num => $num);

    return 1 if $row && $row->{verified} eq 'Y';
    return 0;
}

sub num_is_pending {
   my $class = shift;
   my $num   = shift;
   return LJ::SMS->num_is_verified($num) ? 0 : 1;
}

# get the time a number was inserted
sub num_instime {
    my $class = shift;
    my $num  = shift;

    # TODO: optimize
    my $dbr = LJ::get_db_reader();

    # select the most recently inserted time
    return $dbr->selectrow_array
        ("SELECT instime FROM smsusermap WHERE number=? LIMIT 1", undef, $num);
}

# return how much time a user has left to register their number
# returns false if no time left
sub num_register_time_remaining {
    my $class = shift;
    my $u = shift;

    return 1 unless $LJ::SMS_REGISTER_TIME_LIMIT;

    my $instime = $u->sms_num_instime;
    my $register_time = $LJ::SMS_REGISTER_TIME_LIMIT;
    if ($instime && $instime + $register_time > time()) {
        return ($instime + $register_time) - time();
    }

    return 0;
}

sub set_number_verified {
    my ($class, $uid, $verified) = @_;

    $uid = LJ::want_userid($uid);
    $verified = uc($verified);
    croak "invalid userid" unless int($uid) > 0;
    croak "invalid verified flag" unless $verified =~ /^[YN]$/;

    # clear mapping cache
    my $old_num = uid_to_num($uid);
    delete $LJ::SMS::REQ_CACHE_MAP_NUM{$old_num} if $old_num;
    delete $LJ::SMS::REQ_CACHE_MAP_UID{$uid};

    my $dbh = LJ::get_db_writer() or die "No DB handle";
    return $dbh->do("UPDATE smsusermap SET verified=? WHERE userid=?", undef, $verified, $uid);
}

# enqueue an incoming SMS for processing
sub enqueue_as_incoming {
    my $class = shift;
    croak "enqueue_as_incoming is a class method"
        unless $class eq __PACKAGE__;

    my $msg = shift;
    die "invalid msg argument"
        unless $msg && $msg->isa("LJ::SMS::Message");

    return unless $msg->should_enqueue;

    my $sclient = LJ::theschwartz();
    die "Unable to contact TheSchwartz!"
        unless $sclient;

    my $shandle = $sclient->insert("LJ::Worker::IncomingSMS", $msg);
    return $shandle ? 1 : 0;
}

# is sms sending configured?
sub configured {
    my $class = shift;

    return %LJ::SMS_GATEWAY_CONFIG && LJ::sms_gateway() ? 1 : 0;
}

sub configured_for_user {
    my $class = shift;
    my $u = shift;

    # active if the user has a verified sms number
    return $u->sms_active_number ? 1 : 0;
}

sub pending_for_user {
    my $class = shift;
    my $u = shift;

    # pending if the user has a number but it is unverified
    return $u->sms_pending_number ? 1 : 0;
}

sub sms_quota_remaining {
    my ($class, $u, $type) = @_;

    return LJ::run_hook("sms_quota_remaining", $u, $type) || 0;
}

sub add_sms_quota {
    my ($class, $u, $qty, $type) = @_;

    return LJ::run_hook("modify_sms_quota", $u, delta => $qty, type => $type);
}

sub max_sms_bytes {
    my ($class, $u) = @_;

    # for now the max length for all users is 160, but
    # in the future we'll need to modify this to look
    # at their carrier cap and return a max from there
    return '160';
}

sub max_sms_substr {
    my $class = shift;
    my ($u, $text, %opts) = @_;

    my $suffix = delete $opts{suffix} || "";
    my $maxlen = delete $opts{maxlen} || undef;
    croak "invalid parameters to max_sms_substr: " . join(",", keys %opts)
        if %opts;

    $maxlen ||= $u->max_sms_bytes;

    my $gw = LJ::sms_gateway()
        or die "unable to load SMS gateway object";

    # use bytes in here for length/etc
    use bytes;

    # greedily find the largest bit of text that doesn't
    # violate the final byte length of $maxlen, stopping
    # when $maxlen == 2 and --$maxlen == 1 is tried as
    # a length
    my $currlen = $maxlen;
    while ($currlen > 1 && $gw->final_byte_length($text . $suffix) > $maxlen) {
        $text = LJ::text_trim($text, --$currlen);
    }

    return $text . $suffix;
}

sub can_append {
    my $class = shift;
    my ($u, $curr, $append) = @_;
    croak "invalid user object" unless LJ::isu($u);

    my $maxlen = $u->max_sms_bytes;

    my $gw = LJ::sms_gateway()
        or die "unable to load SMS gateway object";

    return $gw->final_byte_length($curr . $append) <= $maxlen;
}

sub subtract_sms_quota {
    my ($class, $u, $qty, $type) = @_;

    return LJ::run_hook("modify_sms_quota", $u, delta => -$qty, type => $type);
}

sub set_sms_quota {
    my ($class, $u, $qty, $type) = @_;

    return LJ::run_hook("modify_sms_quota", $u, amount => $qty, type => $type);
}

# Schwartz worker for responding to incoming SMS messages
package LJ::Worker::IncomingSMS;
use base 'TheSchwartz::Worker';

use Class::Autouse qw(LJ::SMS::MessageHandler);

sub work {
    my ($class, $job) = @_;

    my $msg = $job->arg;

    unless ($msg) {
        $job->failed;
        return;
    }

    warn "calling messagehandler";
    LJ::SMS::MessageHandler->handle($msg);

    return $job->completed;
}

sub keep_exit_status_for { 0 }
sub grab_for { 300 }
sub max_retries { 5 }
sub retry_delay {
    my ($class, $fails) = @_;
    return (10, 30, 60, 300, 600)[$fails];
}

1;
