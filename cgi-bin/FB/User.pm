package FB::User;

use strict;
use Carp;

sub remote {
    return FB::get_remote();
}

sub load_user {
    my $class = shift;
    return FB::load_user(@_);
}

sub load_userid {
    my $class = shift;
    return FB::load_userid(@_);
}

sub load_userids {
    my $class = shift;
    return FB::load_userids(@_);
}

# returns username
sub user {
    my $u = shift;
    return $u->{user};
}

# construct a fb user from a lj user
sub new_from_lj_user {
    my ($class, $lju) = @_;
    my $dbr = FB::get_db_reader();
    my ($fbuid) = $dbr->selectrow_array("SELECT userid FROM useridlookup WHERE ktype='I' AND kval=?",
                                      undef, $lju->id);
    return FB::load_userid($fbuid);
}

# get a LJ::User object that corresponds to this FB::User object
sub lj_u {
    my $fb_u = shift;

    my $dbr = FB::get_db_reader();
    my ($ljuid) = $dbr->selectrow_array("SELECT kval FROM useridlookup WHERE ktype='I' AND userid=?",
                                      undef, $fb_u->id);
    return LJ::load_userid($ljuid);
}

# fields in object:
#    by default, all columns from "user" table
#
#    _loaded_props:  if true, then the 'prop' hashref is available
#    _galleries:     memoized copy of ->galleries.  (hashref of gallid -> FB::Gallery)
#    _secgroups:     memoized copy of ->secgroups.  (hashref of secid  -> FB::SecGroup)
#
#    _tag_map:       hashref, mapping of $tag to FB::Gallery
#
#    _secin:         cached comma-separated list of secids that remote user can view

# returns self (the $u object which can be used for $u->do) if
# user is writable, else 0
sub writer {
    my $u = shift;
    return $u if $u->{'_dbcm'} ||= FB::get_user_db_writer($u);
    return 0;
}

sub begin_work {
    my $u = shift;
    return 1 unless $FB::INNODB_DB{$u->{clusterid}};

    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    my $rv = $dbcm->begin_work;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

sub commit {
    my $u = shift;
    return 1 unless $FB::INNODB_DB{$u->{clusterid}};

    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    my $rv = $dbcm->commit;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

sub rollback {
    my $u = shift;
    return 0 unless $FB::INNODB_DB{$u->{clusterid}};

    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    my $rv = $dbcm->rollback;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

# takes query and either a $hashref of named placeholder values, or array
# of positional placeholder values
sub _fill_placeholders {
    my $db    = shift;
    my $query = shift;
    return $query unless @_;

    # add a space so scalar @parts is always number of question marks + 1
    # (assuming no question mark at beginning, which is just dumb)
    my @parts = split(/\?/, $query . " ");
    my $ret   = "";  # returned query

    if (ref $_[0] eq "HASH") {
        my $vals = shift;
        Carp::croak("Extra arguments past hashref to the 'prepare' method") if @_;
        die "FIXME: not implemented";
    } else {
        while (@_) {
            my $val = shift @_;
            Carp::croak("Too many placeholder values") unless @parts;
            $ret .= shift @parts;

            my $is_string = 1;  # by default, assume all arguments are strings

            if (ref $val eq "ARRAY") {
                # explicit type in second field of arrayref:  [ $value, <"int"|"char"> ]
                Carp::croak("Invalid type in placeholder arrayref value")
                    unless $val->[1] && $val->[1] =~ /^int|char$/;
                if ($val->[1] eq "int") {
                    $is_string = 0;
                    $val = $val->[0] + 0; # int
                } else {
                    $val = $val->[0];  # string
                }
            } elsif ($ret =~ /id=$/ && $val =~ /^\d+$/) {
                $is_string = 0;
            }

            $ret .= $is_string ? $db->quote($val) : $val;
        }
        Carp::croak("Too few placeholder values") unless @parts == 1;
        $ret .= shift @parts;
    }

    return $ret;
}

sub prepare {
    my $u = shift;
    my $stmt = shift;

    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    $stmt = _fill_placeholders($dbcm, $stmt, @_) if @_;

    my $rv = $dbcm->prepare($stmt);
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
        warn "FB::User db error ($u->{_dberr}): $u->{_dberrstr}\n";
    }
    return $rv;
}

# $u->do("UPDATE foo SET key=?", undef, $val);
sub do {
    my $u = shift;
    my $query = shift;

    my $uid = $u->{userid}+0
        or croak "Database update called on null user object";

    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    $query =~ s!^(\s*\w+\s+)!$1/* uid=$uid */ !;
    $query = _fill_placeholders($dbcm, $query, @_) if @_;

    my $rv = $dbcm->do($query);
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
        warn "FB::User db error ($u->{_dberr}): $u->{_dberrstr}\n";
    }

    $u->{_mysql_insertid} = $dbcm->{'mysql_insertid'} if $dbcm->{'mysql_insertid'};

    return $rv;
}

sub selectrow_array {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectrow_array($qry);
}

sub selectrow_hashref {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectrow_hashref($qry);
}

sub selectcol_arrayref {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectcol_arrayref($qry);
}

sub selectall_arrayref {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectall_arrayref($qry);
}

sub selectall_hashref {
    my $u = shift;
    my $qry = shift;
    my $key = shift;
    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectall_hashref($qry, $key);
}

sub err {
    my $u = shift;
    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    return $dbcm->err;
}

sub errstr {
    my $u = shift;
    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    return $dbcm->errstr;
}

sub quote {
    my $u = shift;
    my $text = shift;

    my $dbcm = $u->{'_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    return $dbcm->quote($text);
}

sub mysql_insertid {
    my $u = shift;
    if ($u->isa("FB::User")) {
        return $u->{_mysql_insertid};
    } elsif (FB::isdb($u)) {
        my $db = $u;
        return $db->{'mysql_insertid'};
    } else {
        die "Unknown object '$u' being passed to FB::User::mysql_insertid.";
    }
}

# returns hashref (gallid -> rec) of all user's galleries
sub galleries {
    my $u = shift;
    return {%{ $u->{_galleries} ||= FB::Gallery->load_gals($u) }};
}

# returns hashref (secid -> rec) of all user's secgroups
sub secgroups {
    my $u = shift;
    return {%{ $u->{_secgroups} ||= FB::SecGroup->load_secgroups($u); }};
}

# given $u and $other_u, makes $other_u a member of exactly the list of $u's
# security groups specified by @seclist
sub set_secgroup_membership {
    my $u       = shift;
    my $other_u = shift;
    my @seclist = @_;

    # what security groups did the caller ask for?
    my %want_groups = ();
    foreach (@seclist) {

        # note that 0, 251-255 will be invalid according to this test
        # -- that's fine since we don't want to explicitly add people
        #    to special groups anyway
        my $sec = ref $_ && $_->isa("FB::SecGroup") ? $_ : $u->load_secgroup_id($_);
        return FB::error("invalid security group: " . ($sec->{secid}+0))
            unless $sec && $sec->valid;

        # add to %need_groups
        my $secid = $sec->secid;
        $want_groups{$secid} = $sec;
    }

    # in which groups does $other_u already exist?
    my $all_groups = $u->secgroups || {};

    # from which groups should $other_u be removed?
    while (my ($secid, $sec) = each %$all_groups) {

        # don't delete if we want to add them to this group anyway
        next if $want_groups{$secid};

        # don't delete if they're not a member
        next unless $sec->is_member($other_u);

        $sec->delete_member($other_u);
    }

    # to which groups should $other_u be added
    while (my ($secid, $sec) = each %want_groups) {

        # don't add if already a member
        next if $sec->is_member($other_u);

        $sec->add_member($other_u);
   }

   # return new id snapshot
   return 1;
}

sub secgroups_with_member {
    my $u       = shift;
    my $other_u = shift;

    my $groups = $u->secgroups || {};

    my %ret = ();
    while (my ($secid, $sec) = each %$groups) {
        next unless grep { $_->{userid} == $other_u->{userid} } $sec->members;

        $ret{$secid} = $sec;
    }

    return \%ret;
}


# if $secref is a reference to a scalar, it is filled in with the
# default security value in the event that it is blank
sub valid_security_value {
    my $u      = shift;
    my $secref = shift;

    # coerce $secref into a scalar ref
    unless (ref $secref) {
        my $foo = $secref;
        $secref = \$foo;
    }

    if ($$secref eq "") {
        # default is 'public'
        $$secref = 255;
        return 1;
    }

    # must be an integer
    return 0 unless $$secref =~ /^\d+$/;

    # valid built-in security levels
    return 1 if $$secref == 0 || ($$secref >= 253 && $$secref <= 255);

    # check user security levels
    if ($$secref >= 1 && $$secref <= 250) {
        my $secgroups = $u->secgroups;
        return $secgroups->{$$secref} ? 1 : 0;
    }

    # everything else is bogus
    return 0;
}

sub incoming_gallery {
    my $u = shift;
    # FIXME: locking?
    my $gr = $u->selectrow_hashref("SELECT * FROM gallery WHERE userid=? AND name=':FB_in'",
                                   $u->{userid});
    return FB::Gallery->from_gallery_row($u, $gr) if $gr;
    return FB::Gallery->create($u, name => ":FB_in");
}

sub load_gallery_id {
    my $u = shift;
    my $gallid = int(shift);
    my $g = FB::Gallery->new($u, $gallid)
        or return undef;

    return undef unless $g->valid;
    return $g;
}

sub load_secgroup_id {
    my $u = shift;
    my $secid = int(shift);
    my $sec = FB::SecGroup->new($u, $secid)
        or return undef;

    return undef unless $sec->valid;
    return $sec;
}

# user's base URL, ending in slash
*url = \&url_root;
sub url_root
{
    my ($u) = @_;
    die "FB::url_user(): No user\n" unless $u && $u->{'userid'};

    my $user = FB::canonical_username($u);
    return $u->media_base_url . '/';
}

sub get_userpic_count {
    my $u = shift;
    my $count = $u->get_prop('userpic_count');

    return $count;
}

sub userpic_quota {
    my $u = shift;
    my $quota = $u->get_prop('userpic_quota');

    return $quota;
}

sub new_message_count {
    my $u = shift;
    my $msgs = $u->get_prop('new_messages');

    return $msgs;
}

sub can_use_esn {
    my $u = shift;
    my $esn = $u->get_cap('esn');

    return $esn;
}

sub can_use_sms {
    my $u = shift;
    my $sms = $u->get_cap('sms');

    return $sms;
}

# user's remaining disk space
# returns "" if no disk_usage_info hook
sub diskfree_widget {
    my $u = shift;

    my $spaceinfo = FB::run_hook("disk_usage_info", $u);

    return '' unless $spaceinfo && $spaceinfo->{quota};

    my $usedtotal = ($spaceinfo->{used} + $spaceinfo->{external});
    my $pct = sprintf("%0.2f", $usedtotal/$spaceinfo->{quota} * 100);
    my $free = $spaceinfo->{free};
    $usedtotal = sprintf("%0.2f", $usedtotal/1024);
    my $total = $spaceinfo->{quota} / 1024;
    return qq {
        <div class = "FBDiskFreeWidget">
            <span class="FBDiskAvailable">Available storage space</span>
            <div class="FBDiskUsedBarContainer"><div class="FBDiskUsedBar" style="width: $pct%;"></div></div>
            <div><div class="FBDiskUsed">$usedtotal MB</div><div class="FBDiskTotal">$total MB</div></div>
        </div>
    };
}

sub security_widget
{
    my ($u, $name, $default) = @_;
    $default = 255 unless defined $default; # public

    my @extra;
    if ($u) {
        $u->{'_secgroups'} ||= FB::load_secgroups($u);

        my $h = $u->{'_secgroups'};
        foreach (sort { $h->{$a}->{'grpname'} cmp $h->{$b}->{'grpname'} }
                 keys %$h) {
            push @extra, $_, $h->{$_}->{'grpname'},
        }
        unshift @extra, '', "----------" if @extra;
    }

    return LJ::html_select({ 'name' => $name,
                             'selected' => $default,
                             'disabled' => ! $u, },
                           255 => "Public",
                           0 => "Private",
                           253 => "Registered Users",
                           254 => "All Groups",
                           @extra);
}

sub secgroup_name   ## DEPRECATED: use $u->secgroup_name
{
    my ($u, $secid) = @_;
    return undef unless $u && defined $secid;
    $secid = int($secid);

    my %reserved = ( 0   => 'Private',
                     253 => 'Registered Users',
                     254 => 'All Groups',
                     255 => 'Public', );

    return $reserved{$secid} if $reserved{$secid};

    # custom security group
    my $sec = $u->load_secgroup_id($secid)
        or return undef;
    return $sec->grpname;
}

# parent/child may be FB::Gallery objects, or scalar integers.  parent
# may be 0 (for top-level), but not the child
sub setup_gal_link
{
    my ($u, $parent, $child, $on_off) = @_;

    my $pid = ref $parent ? $parent->id : $parent;
    my $cid = ref $child  ? $child->id  : $child;

    die "bogus child id"  unless defined $cid && $cid =~ /^\d+$/;
    die "bogus parent id" unless defined $pid && $pid =~ /^\d+$/;

    return 0 unless $u->writer;

    if ($on_off) {
        $u->do("REPLACE INTO galleryrel (userid, gallid, gallid2, type, sortorder) ".
               "VALUES (?,?,?,'C',0)", $u->{'userid'}, $pid, $cid);
        return 0 if $u->err;
    } else {
        $u->do("DELETE FROM galleryrel WHERE userid=? AND gallid=? AND gallid2=? AND type='C'",
               $u->{'userid'}, $pid, [$cid, "int"]);
        return 0 if $u->err;
    }
    return 1;
}

sub _load_props {
    my $u = shift;
    return 1 if $u->{_loaded_props};

    my $ps = FB::get_props() or die;
    $u->{prop} = {};

    my $sth = $u->prepare("SELECT propid, value FROM userprop WHERE userid=?",
                          $u->{userid});
    $sth->execute;
    return 0 if $sth->err;

    while (my ($id, $value) = $sth->fetchrow_array) {
        my $name = $ps->{$id};
        next unless $name;
        $u->{prop}{$name} = $value;
    }

    $u->{_loaded_props} = 1;
    return 1;
}

*get_prop = \&prop;

sub prop {
    my ($u, $prop) = @_;
    ($u->_load_props or die "Can't load props for user") unless $u->{_loaded_props};
    return $u->{prop}{$prop};
}

sub set_prop {
    my ($u, $prop, $value) = @_;

    # bail out early, if we know the value's already the same
    return 1 if $u->{_loaded_props} && $u->{prop}{$prop} eq $value;

    my $ps  = FB::get_props() or return 0;  # fixme: die
    my $pid = $ps->{$prop}    or return 0;  # fixme: die

    if (defined $value) {
        $u->do("REPLACE INTO userprop (userid, propid, value) ".
               "VALUES (?,?,?)", $u->{'userid'}, $pid, $value)
            or return 0;
        $u->{prop}{$prop} = $value if $u->{_loaded_props};
    } else {
        $u->do("DELETE FROM userprop WHERE userid=? AND propid=?",
               $u->{'userid'}, $pid) or return 0;
        delete $u->{prop}{$prop} if $u->{_loaded_props};
    }
    return 1;
}

# given undef $parentid, returns hashref of { $gallid_or_zero -> [ FB::Gallery+ ] }
# given a $parentid, returns array of FB::Gallery objects
sub galleries_by_parent {
    my $u = shift;
    my $parentid = shift;

    if (my $gbp = $u->{_galleries_by_parent}) {
        return @{ $gbp->{$parentid} || [] } if defined $parentid;
        return { %$gbp };  # return a copy, so they can't mess with it
    }

    my $ret = {};
    my $gals = $u->galleries or die;

    my $sth = $u->prepare("SELECT gallid, gallid2 ".
                          "FROM galleryrel WHERE userid=? AND type='C'",
                          $u->{userid});
    $sth->execute;
    while (my ($g1, $g2) = $sth->fetchrow_array) {
        next unless $g1 == 0 || defined $gals->{$g1};
        my $gal = $gals->{$g2};
        next unless defined $gal;
        push @{$ret->{$g1} ||= []}, $gal;
    }

    $u->{_galleries_by_parent} = $ret;

    # recurse, now that we have our super-structure populated
    return $u->galleries_by_parent($parentid);
}

# returns array of [ FB::Gallery, depth ] where depth is 0 if at top-level.
# an FB::Gallery of "undef" means the "Unreachable" placeholder gallery,
# from which all unreachable galleries are under
sub galleries_with_depth {
    my $u = shift;
    my $gals  = $u->galleries     or die;

    my %unreachable = %$gals;

    my @ret;
    my $populate;
    $populate = sub {
        my ($gid, $depth, $seen) = @_;
        foreach my $gal (sort { $a->raw_name cmp $b->raw_name }
                         $u->galleries_by_parent($gid))
        {
            my $cid = $gal->id;
            next if $seen->{$cid};
            my $seencopy = { %{$seen} };
            $seencopy->{$cid} = 1;
            delete $unreachable{$cid};
            push @ret, [ $gal, $depth ];
            $populate->($cid, $depth+1, $seencopy);
        }
    };
    $populate->(0, 0, {});

    if (%unreachable) {
        push @ret, [ undef, 0 ];
        while (my ($k, $v) = each %unreachable) {
            push @ret, [ $v, 1 ];
        }
    }

    return @ret;
}

# loads hashref of all tags for a user, keyed by tag, values being Gallery objects
sub tag_galleries {
    my $u = shift;
    return FB::Gallery->load_tag_galleries($u);
}

# hashref (gallid -> rec) of all user's gals without aliased/associated tags
sub untag_galleries {
    my $u = shift;

    # take all galleries, then remove tag galleries:
    my $tag_gals = $u->tag_galleries;  # loads hashref of all Galleries for a user, keyed by tag
    my $all_gals = $u->galleries;      # hashref (gallid -> rec) of all user's gals

    while (my ($tag, $taggal) = each %$tag_gals) {
        delete $all_gals->{$taggal->id};
    }

    return $all_gals;
}

# returns JavaScript array of user's tags, from most to least popular, in JSON notation
sub image_tags_as_js {
    my $u = shift;
    my $gals = FB::Gallery->load_tag_galleries($u);
    my @tags = sort { $gals->{$b}->pic_count <=> $gals->{$a}->pic_count } keys %$gals;
    return JSON::objToJson(\@tags);
}

sub gallery_of_tag {
    my ($u, $tag, $no_create_flag) = @_;
    return undef unless $tag;
    $u->{_tag_map} ||= {};
    return $u->{_tag_map}{$tag} ||= FB::Gallery->load_gallery_of_tag($u, $tag, no_create => $no_create_flag);
}

# Given an alias, returns a Gallery object of the gallery the alias
# points to
sub prigal_of_alias {
    my ($u, $alias) = @_;
    return undef unless $alias;

    my $aliases = $u->get_aliases();
    return undef unless defined $aliases->{$alias}; # Is this an existing alias?

    my $gallid = $aliases->{$alias}->{gallid};
    my $gal = FB::Gallery->new($u, $gallid);
    return $gal;
}

sub get_aliases {
    my $u = shift;

    my $sth = $u->prepare("SELECT alias, gallid FROM aliases " .
                          "WHERE userid=? AND is_primary=0") or return undef;

    $sth->execute($u->{'userid'}) or return undef;
    my $aliases = $sth->fetchall_hashref('alias');

    return $aliases;
}

sub gallery_of_existing_tag {
    my ($u, $tag) = @_;
    return $u->gallery_of_tag($tag, 1);
}

sub generate_challenge {
    my $u = shift;

    $u->do("DELETE FROM challenges WHERE userid=? AND ".
           "timecreate < UNIX_TIMESTAMP()-60",
           $u->{'userid'});

    my $chal = FB::rand_chars(40);
    my $auth = FB::domain_plugin($u);
    return $auth->generate_challenge($u) if $auth;

    $u->do("INSERT INTO challenges (userid, timecreate, challenge) VALUES (?,UNIX_TIMESTAMP(),?)",
           $u->{'userid'}, $chal);

    return $u->err ? undef : $chal;
}

# comma-separated list of secids that remote user can view
sub secin {
    my $u = shift;
    return $u->{_secin} if $u->{_secin};

    my $remote = FB::User->remote;
    return (255) unless $remote;   # if no remote, only applicable for public.

    my @out;
    if ($u->{userid} == $remote->{userid}) {
        # remote is owner, so can see private & all custom groups
        push @out, 0, 1..250;
    } else {
        my $groups = $u->secgroups_with_member($remote);
        if (ref $groups) {
            push @out, map { $_->secid } values %$groups;
        }
    }
    push @out, 254 if @out;  # 'all groups'
    push @out, 253, 255;     # registered user & public

    return $u->{_secin} ||= join(",", @out);
}

sub alloc_secid {
    my ($u, $type) = @_;

    my $groups = $u->secgroups || {};
    my @range = $type eq 'user' ? 1..125 : 126..250;

    # find first untaken groupid in the valid range
    return (grep { ! $groups->{$_} } @range)[0] || undef;
}

# Moves any gallery tags from the idents table to the aliases table
# and then deletes the data from the idents table
sub migrate_idents {
    my $u = shift;

    # Do we know we already did this?
    return 1 if $u->{'_idents_migrated'};

    # See if they have any old short names
    my $sth = $u->prepare("SELECT did AS gallid, ident AS tag FROM " .
                          "idents WHERE userid=? AND itype='S' AND " .
                          "dtype='G'");
    $sth->execute($u->{'userid'});
    die $u->errstr if $u->err;

    # Did we find any?
    return 1 unless $sth->rows > 0;

    # Build up our variables for the insert into aliases
    my (@vars, @bind);
    while (my $row = $sth->fetchrow_hashref) {
        push @vars, $u->{'userid'};
        push @vars, $row->{'tag'};
        push @vars, $row->{'gallid'};
        push @bind, "(?, ?, ?, 1)";
    }
    my $bindstr = join(',', @bind);

    # Since we only should ever migrate once, if this insert fails
    # there is a problem
    $u->do("INSERT INTO aliases (userid, alias, gallid, is_primary) VALUES $bindstr", @vars);
    die $u->errstr if $u->err;

    # Delete their old short names
    $u->do("DELETE FROM idents WHERE userid=? AND itype='S' ".
           "AND dtype='G'", $u->{'userid'});

    # Mark them as migrated
    $u->{'_idents_migrated'} = 1;
    return 1;
}

# create a new user in the database
# args: opts, usercs field required
# returns userid
# class method
sub create {
    my $class = shift;
    my $ref = shift;

    my $err = sub { $@ = $_[0], return undef; };

    return $err->("invalid arguments: '$ref'") unless ref $ref;
    return $err->("no usercs specified") unless defined $ref->{'usercs'};

    # only accept usercs, then make (and overwrite even) user with that
    my $user = FB::canonical_username($ref->{'usercs'});
    return $err->("non-canonical username: $ref->{usercs}")
        unless length($user); # means it was bogus format

    $ref->{'r_userid'}  += 0;
    $ref->{'domainid'}  = FB::current_domain_id() unless defined $ref->{'domainid'};
    $ref->{'domainid'}  += 0;
    $ref->{'clusterid'} ||= FB::new_user_cluster();
    $ref->{'caps'}      ||= $FB::DEFAULT_CAPS+0;
    $ref->{'emailgood'} ||= 'N';
    $ref->{'statusvis'} ||= 'V';
    $ref->{'email'} ||= '';

    my $dbh = FB::get_db_writer()
        or return $err->("couldn't get database writer");

    # make sure only one caller tries to create this user in this domain
    # at a time
    my $lockname = "createuser-$ref->{'domainid'}-$user";
    my $got_lock = $dbh->selectrow_array("SELECT GET_LOCK(?,5)",
                                         undef, $lockname);
    return $err->("couldn't get lock: $lockname") unless $got_lock;
    my $unlock = sub {
        $dbh->do("SELECT RELEASE_LOCK(?)", undef, $lockname);
        return @_ ? $err->(@_) : undef;
    };

    # first, see if it wasn't already created in the meantime.
    my $exist_uid = $dbh->selectrow_array("SELECT userid FROM useridlookup WHERE ".
                                          "domainid=? AND ktype='N' AND kval=?",
                                          undef, $ref->{'domainid'}, $user);
    if ($exist_uid) {

        # local users have no 'I' useridlookup mapping, so we now know
        # the account is already made in that case
        return $unlock->("local user already exists: $user")
            unless $ref->{'domainid'} && $ref->{'r_userid'};

        # remote users have a mapping from remote userid to local userid.
        # so, in order to tell if the current user being created has already
        # been made (while we were waiting for a lock), we need to see if the
        # 'I' row for the current remote userid points to the user we just
        # found.
        #
        # because if so, that means that there has already been a local fb user
        # created that has a mapping from the remote userid we are trying to
        # load (r_userid) to it.
        #
        # aside from properly checking post-lock, this also verifies that the
        # local userid found above isn't mapped from an old remote userid, which
        # happens if the remote site creates a new account with a new userid
        # but re-using an old (possibly deleted) name.

        # does the userid above have an I mapping to our remote userid?
        my $mapped_uid = $dbh->selectrow_array
            ("SELECT userid FROM useridlookup WHERE " .
             "domainid=? AND ktype='I' AND kval=?",
             undef, $ref->{domainid}, $ref->{r_userid});

        # now we know that it has already been done, so we return
        return $unlock->("remote user already exists: $user")
            if $mapped_uid && $exist_uid == $mapped_uid;

        # remote username points to an old local account still
        # need to make a new local userid for them
    }

    $dbh->do("INSERT INTO user (domainid, usercs, clusterid, caps, email, ".
             "emailgood, password, statusvis, statusvisdate) VALUES ".
             "(?,?,?,?,?,?,?,?,UNIX_TIMESTAMP())", undef, $ref->{'domainid'},
             $ref->{'usercs'}, $ref->{'clusterid'}, $ref->{'caps'},
             $ref->{'email'}, $ref->{'emailgood'}, $ref->{'pass'}, $ref->{'statusvis'});
    return $unlock->($dbh->errstr) if $dbh->err;

    my $userid = $dbh->{'mysql_insertid'};
    return $unlock->("no userid from insert") unless $userid;

    # insert useridlookup mappings for new user
    my $sql = "REPLACE INTO useridlookup (domainid, ktype, kval, userid) VALUES (?,?,?,?)";
    my @vals = ($ref->{'domainid'}, 'N', $user, $userid); # username mapping

    # optional remote userid mapping
    if ($ref->{'domainid'} && $ref->{'r_userid'}) {
        $sql .= ",(?,?,?,?)";
        push @vals, ($ref->{'domainid'}, 'I', $ref->{'r_userid'}, $userid);
    }

    # create username/userid mapping in db
    $dbh->do($sql, undef, @vals);
    return $unlock->($dbh->errstr) if $dbh->err;

    $unlock->();
    return $userid;
}

# class method
# look up the userid for a user
# args: $username, [$domainid], [$opts]
# opts: 'create' to vivify account
sub get_userid
{
    my ($class, $user, $domainid, $opts) = @_;
    $opts = ref $opts eq "HASH" ? $opts : {};

    if ($user =~ /\@/) {
        # error for a user to include an @ sign when the caller
        # is giving an explicit domainid
        return undef if defined $domainid;
        ($user, $domainid) = parse_userdomain($user);
    } else {
        $user = FB::canonical_username($user);
    }

    unless (defined $domainid) {
        $domainid = FB::current_domain_id();
    }
    $domainid += 0;

    my $uid = $FB::REQ_CACHE{"uidlookup:$domainid:$user"};
    return $uid if $uid;

    # check memcache
    my $memkey = "loc_uid_n:$domainid:$user";
    $uid = FB::MemCache::get($memkey);
    return $uid if $uid;

    # subref to set $uid (already in scope) in memcache and request cache
    my $set = sub {
        my $id = $_[0];
        $FB::REQ_CACHE{"uidlookup:$domainid:$user"} = $id;
        FB::MemCache::set($memkey => $id);
        return $id;
    };

    my $db = @FB::MEMCACHE_SERVERS ? FB::get_db_writer() : FB::get_db_reader();

    # don't use placeholders!  If username is numeric, DBD::mysql
    # won't quote it, and mysql won't case an integer to a varchar,
    # and thus the query optimizer won't use all parts of the key.
    # Lame.  (Nov 22nd, 2004 -- MySQL 4.0.20, DBD::mysql 1.2216-2)
    my $quser = $db->quote($user);

    $uid = $db->selectrow_array("SELECT userid FROM useridlookup " .
                                "WHERE domainid=? AND ktype='N' AND kval=$quser",
                                undef, $domainid);
    return $set->($uid) if $uid;

    # no hope now
    return undef;
}

# returns userid
sub id {
    my $u = shift;
    return $u->{userid};
}

# returns domainuserid
sub domainid {
    my $u = shift;
    return $u->{domainid};
}

# returns true, unless there exists a mapping from the local userid
# to an external user in domain $domainid with an external userid
# that's not $external_userid.
sub check_remoteuserid_uniqueness
{
    my ($u, $domainid, $external_userid) = @_;
    my $userid = $u->id;

    # "I already know of one external (lj) to local userid mapping
    # are there any others?  If so my mapping is not unique."

    my $dbr = FB::get_db_reader();
    my $uid = $dbr->selectrow_array("SELECT kval FROM useridlookup " .
                                    "WHERE userid=? AND domainid=? AND ktype='I' " .
                                    "AND kval <> ? LIMIT 1", undef,
                                    $userid, $domainid, $external_userid);

    # if we found something, it's not unique
    return $uid ? 0 : 1;
}


# returns true if this $u is equal to another user
sub equals {
    my ($u1, $u2) = @_;
    return $u1 && $u2 && $u1->id == $u2->id;
}

sub kill_sessions
{
    my ($u, @sessids) = @_;
    return undef unless $u;

    my $in = join(',', map { $_+0 } @sessids);
    return 1 unless $in;

    my $udbh = FB::get_user_db_writer($u);
    $udbh->do("DELETE FROM sessions WHERE userid=? AND ".
              "sessid IN ($in)", undef, $u->{'userid'});
    return 1;
}

sub kill_session
{
    my $u = shift;
    return 0 unless $u;
    return 0 unless exists $u->{'_session'};
    $u->kill_sessions($u->{'_session'}->{'sessid'});
    undef $BML::COOKIE{'fbsession'};
    return 1;
}

sub get_cap
{
    my ($u, $cname) = @_;
    return FB::get_cap($u, $cname);
}

# returns a dropdown menu for choosing a gallery. This menu will be javascript-enabled for
# creating and selecting galleries. Remember to include all the necessary javascript files!
sub gallery_select_menu
{
    my $u = shift;

    my $ret = LJ::html_select({ 'name' => 'gallid',
                                'id' => 'gal_select_js',
                              },
                              '' => "(Unsorted)",
                              'new' => "[New Gallery...]",
                              'sel' => "[Choose Gallery...]",
                              '' => "----",
                              FB::gallery_select_list($u),
                              );

    $ret .= qq {
        <script>
            setTimeout(setup_gal_select_menu, 400); // set up after page loads
            function setup_gal_select_menu () {
                var themenu = new GallerySelectMenu(\$("gal_select_js"));
            }
        </script>
    };

    return $ret;
}

# returns true if is an identity user
sub identity {
    my $u = shift;

    return $u->get_prop('is_identity') ? 1 : 0;
}


# a little place to stash persistant user info
sub cache {
    my ($u, $key) = @_;
    my $val = $u->selectrow_array("SELECT value FROM userblobcache WHERE userid=? AND bckey=?",
                                  $u->{userid}, $key);
    return undef unless defined $val;
    if (my $thaw = eval { Storable::thaw($val); }) {
        return $thaw;
    }
    return $val;
}

sub set_cache {
    my ($u, $key, $value, $expr) = @_;
    my $now = time();
    $expr ||= $now + 86400;
    $expr += $now if $expr < 315532800;  # relative to absolute time
    $value = Storable::nfreeze($value) if ref $value;
    $u->do("REPLACE INTO userblobcache (userid, bckey, value, timeexpire) VALUES (?,?,?,?)",
           $u->{userid}, $key, $value, $expr);
}

# values for $dom: 'U' upic, 'G' gallery.
sub alloc_counter {
    my ($u, $dom, $opts) = @_;
    $opts ||= {};

    ##################################################################
    # IF YOU UPDATE THIS MAKE SURE YOU ADD INITIALIZATION CODE BELOW #
    die "Bogus domain."
        unless $dom =~ /^[UG]$/;
    ##################################################################

    my $dbh = FB::get_db_writer()
        or die "Unable to allocate user counter for domain '$dom'";

    my $newmax;
    my $uid = $u->{'userid'}+0
        or die "Bogus userid";

    my $memkey = [$uid, "auc:$uid:$dom"];

    # in a master-master DB cluster we need to be careful that in
    # an automatic failover case where one cluster is slightly behind
    # that the same counter ID isn't handed out twice.  use memcache
    # as a sanity check to record/check latest number handed out.
    my $memmax = int(FB::MemCache::get($memkey) || 0);

    my $rs = $dbh->do("UPDATE usercounter SET max=LAST_INSERT_ID(GREATEST(max,$memmax)+1) ".
                      "WHERE userid=? AND area=?", undef, $uid, $dom);
    if ($rs > 0) {
        $newmax = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");

        # if we've got a supplied callback, lets check the counter
        # number for consistency.  If it fails our test, wipe
        # the counter row and start over, initializing a new one.
        # callbacks should return true to signal 'all is well.'
        if ($opts->{callback} && ref $opts->{callback} eq 'CODE') {
            my $rv = 0;
            eval { $rv = $opts->{callback}->($u, $newmax) };
            if ($@ or ! $rv) {
                $dbh->do("DELETE FROM usercounter WHERE " .
                         "userid=? AND area=?", undef, $uid, $dom);
                return $u->alloc_counter($dom);
            }
        }

        FB::MemCache::set($memkey, $newmax);
        return $newmax;
    }

    if ($opts->{recurse}) {
        # We shouldn't ever get here if all is right with the world.
        return undef;
    }

    if ($dom eq "U") {
        $newmax = $u->selectrow_array("SELECT MAX(upicid) FROM upic WHERE userid=?",
                                      $uid);
    } elsif ($dom eq "G") {
        $newmax = $u->selectrow_array("SELECT MAX(gallid) FROM gallery WHERE userid=?",
                                      $uid);
    } else {
        die "No user counter initializer defined for area '$dom'.\n";
    }
    $newmax += 0;
    $dbh->do("INSERT IGNORE INTO usercounter (userid, area, max) VALUES (?,?,?)",
             undef, $uid, $dom, $newmax) or die "database failure inserting new max";

    # The 2nd invocation of the alloc_user_counter sub should do the
    # intended incrementing.
    return $u->alloc_counter($dom, { recurse => 1 });
}

# returns a url to the base path of the user's media
sub media_base_url {
    my $u = shift;

    return "http://" . $u->user . ".$LJ::USER_DOMAIN/media";
}


sub diskusage_bytes {
    my ($u) = @_;

    # get LJ diskusage
    my $lj_u = $u->lj_u;
    return $lj_u->diskusage;
}

######## deprecated APIs

package FB;

use strict;

sub new_user_cluster
{
    return $FB::DEFAULT_CLUSTER || 1;
}

# $opts is either hashref of keys 'create' => 1
#       or arrayref of props to load
sub load_user
{
    my ($user, $domainid, $opts) = @_;

    if ($user =~ /\@/) {
        # error for a user to include an @ sign when the caller
        # is giving an explicit domainid
        return undef if defined $domainid;
        ($user, $domainid) = parse_userdomain($user);
    } else {
        $user = FB::canonical_username($user);
    }

    $domainid = 1 unless defined $domainid;

    if (ref $opts eq "ARRAY") {
        $opts = { 'props' => $opts };
    }
    $opts = ref $opts eq "HASH" ? $opts : {};

    my $uid = FB::User->get_userid($user, $domainid);
    my $u = $uid ? FB::load_userid($uid) : undef;
    return $u;
}

sub load_userid
{
    &nodb;
    my $userid = shift;
    return undef unless $userid;

    my $u = $FB::REQ_CACHE{"userid:$userid"};

    unless ($u) {
        my $db = FB::get_db_reader();
        my $n_userid = $userid + 0;
        $u = $db->selectrow_hashref("SELECT * FROM user WHERE userid=$n_userid");
        bless $u, "FB::User";
        FB::add_u_user($u);
        $FB::REQ_CACHE{"userid:$userid"} = $u;
    }
    if ($u && @_) { load_user_props($u, @_); }

    return $u;
}

# given an arrayref of ids, return a hashref
# uid => u
sub load_userids
{
    my $id_list = ref $_[0] ? $_[0] : \@_;
    return {} unless ref $id_list eq 'ARRAY' && scalar @$id_list;

    #TODO: add a per-request cache like LJ

    my $db = FB::get_db_reader();
    my $ids = join(', ', map { $_ + 0 } @$id_list);
    my $q = qq{
        SELECT * FROM user WHERE userid IN ($ids)
    };

    my $ret = $db->selectall_hashref($q, 'userid', undef);
    while (my ($id) = each %$ret) {
        bless $ret->{$id}, "FB::User";
    }
    return $ret;
}
*load_userid_multi = \&load_userids;

sub load_user_domain_userid
{
    my ($domainid, $duserid) = @_;


    my $memkey = [ $duserid, "loc_uid_i:$domainid:$duserid" ];
    my $uid = FB::MemCache::get($memkey);

    unless ($uid) {
        my $db = @FB::MEMCACHE_SERVERS ? FB::get_db_writer() : FB::get_db_reader();

        # don't use placeholders!  If username is numeric, DBD::mysql
        # won't quote it, and mysql won't case an integer to a varchar,
        # and thus the query optimizer won't use all parts of the key.
        # Lame.  (Nov 22nd, 2004 -- MySQL 4.0.20, DBD::mysql 1.2216-2)
        my $qkval = $db->quote($duserid);

        $uid = $db->selectrow_array("SELECT userid FROM useridlookup " .
                                    "WHERE domainid=? AND ktype='I' AND kval=$qkval",
                                    undef, $domainid);
        FB::MemCache::set($memkey => $uid) if $uid;
    }
    return undef unless $uid;

    my $u = FB::load_userid($uid);
    FB::add_u_user($u);
    return $u;
}

# user object, cap limit name
sub get_cap
{
    my ($u, $cname) = @_;
    my $caps = $u->{'caps'};
    my $max = undef;

    # user caps
    foreach my $bit (keys %FB::CAP) {
        next unless ($caps & (1 << $bit));
        my $v = $FB::CAP{$bit}->{$cname};
        next unless defined $v;
        next if defined $max && $max > $v;
        $max = $v;
    }
    return defined $max ? $max : $FB::CAP_DEF{$cname};
}

sub update_dcaps {
    my ($u, $dcaps) = @_;
    return undef unless ref $u && defined $dcaps;

    return $dcaps if $dcaps == $u->{dcaps};

    FB::update_user($u, {'dcaps' => $dcaps});

    return $dcaps;
}

sub add_u_user {
    my $u = shift;
    $u->{'user'} = FB::canonical_username($u);
    return $u;
}

sub make_upic  ## DEPRECATED: use FB::Upic->create
{
    my ($u, $gpicid, $opts) = @_;

    my $err = sub { $@ = $_[0], return undef; };

    return $err->("no u object") unless $u;
    return $err->("no gpicid") unless $gpicid;

    return $err->("Couldn't connect to user db writer") unless $u->writer;

    # see if this user already has this gpic
    my $p = $u->selectrow_hashref("SELECT * FROM upic WHERE gpicid=? AND userid=?",
                                  $gpicid, $u->{'userid'});
    return $err->($u->errstr) if $u->err;
    if ($p) {
        ${$opts->{'exist_flag'}} = 1 if ref $opts->{'exist_flag'};
        ${$opts->{'randauth'}} = $p->{randauth} if ref $opts->{'randauth'};
        $p->{picsec} = $p->{secid}; # dirty conventions, both expected to exist
        return $p;
    }

    # if not, we need to make one for them.

    # first of all, grab the gpic data, since
    # the upic row will have most the same data.
    my $dbr = get_db_reader()
        or return $err->("Couldn't connect to db reader");
    my $n_gpicid = $gpicid + 0;
    my $g = $dbr->selectrow_hashref("SELECT * FROM gpic WHERE gpicid=$n_gpicid");
    return $err->("No gpic row: $gpicid") unless $g;

    # allocate a new upicid
    my $upicid = FB::alloc_uniq($u, "upic_ctr")
        or return $err->("couldn't allocate uniq id");

    my $randauth = FB::rand_auth();
    ${$opts->{'randauth'}} = $randauth if ref $opts->{'randauth'};

    my $secid = ($opts->{'picsec'} || $opts->{'secid'})+0;

    # insert the real row
    $u->do("INSERT INTO upic (userid, upicid, secid, width, ".
           "height, fmtid, bytes, gpicid, datecreate, randauth) VALUES ".
           "(?,?,?,?,?,?,?,?,UNIX_TIMSETAMP(),?)", $u->{'userid'},
           $upicid, $secid, $g->{'width'}, $g->{'height'}, $g->{'fmtid'},
           $g->{'bytes'}, $gpicid, $randauth);
    return $err->("Couldn't insert upic row") if $u->err;

    # call the hook to record disk space usage
    if (FB::are_hooks("use_disk")) {
        FB::run_hook("use_disk", $u, $g->{'bytes'})
            or die ("Hook 'use_disk' returned false");
    }

    $p = FB::load_upic($u, $upicid, { force => 1})
        or return $err->("load_upic returned false");

    return $p;
}

sub user_upic_bytes {
    my ($u, $opts) = @_;

    return $u->selectrow_array("SELECT SUM(bytes) FROM upic WHERE userid=?", $u->{'userid'})+0;
}

sub load_user_props
{
    my ($u, @props)= @_;
    return undef unless $u;
    my $ps = FB::get_props();
    my $in;
    foreach (@props) {
        my $num = $ps->{$_}+0;
        next unless $num;
        $in .= "," if $in;
        $in .= $num;
    }
    my $where;
    if (@props) {
        if ($in) { $where = "AND propid IN ($in)"; }
        else { return $u; }
    }

    my $sth = $u->prepare("SELECT propid, value FROM userprop WHERE userid=? ". $where,
                          $u->{userid});
    $sth->execute;
    while (my ($id, $value) = $sth->fetchrow_array) {
        my $name = $ps->{$id};
        next unless $name;
        $u->{$name} = $value;
    }
    return $u;
}

sub update_user
{
    my ($arg, $ref) = @_;
    my @uid;

    if (ref $arg eq "ARRAY") {
        @uid = @$arg;
    } else {
        @uid = want_userid($arg);
    }
    @uid = grep { $_ } map { $_ + 0 } @uid;
    return 0 unless @uid;

    my @sets;
    my @bindparams;
    while (my ($k, $v) = each %$ref) {
        if ($k eq "raw") {
            push @sets, $v;
        } else {
            push @sets, "$k=?";
            push @bindparams, $v;
        }
    }
    return 1 unless @sets;
    my $dbh = FB::get_db_writer();
    return 0 unless $dbh;
    {
        local $" = ",";
        my $where = @uid == 1 ? "userid=$uid[0]" : "userid IN (@uid)";
        $dbh->do("UPDATE user SET @sets WHERE $where", undef,
                 @bindparams);
        return 0 if $dbh->err;
    }
    delete $FB::REQ_CACHE{"userid:$_"} foreach @uid;

    return 1;
}

# name: FB::get_num_pics
# des: Returns the number of public, friends only, gallery default,
# and registered user pictures for the given user.  This doesn't need
# to be an exact amount since it is just used to tell LJ.
# args: u
sub estimate_pub_upics
{
    my $u = shift;
    my $ct = $u->selectrow_array
        ("SELECT COUNT(*) FROM upic WHERE userid=? AND secid IN (253,254,255)",
         $u->{'userid'});
    return $ct+0;
}

sub get_domain_userid
{
    my ($userid, $dmid) = @_;
    if (!defined $dmid && ref $userid) {
        my $u = $userid;
        $dmid = $u->{domainid};
    }
    $userid = FB::want_userid($userid);
    $dmid = defined $dmid ? ($dmid+0) : FB::current_domain_id();
    return undef unless $userid && defined $dmid;

    my $memkey = [ $userid, "dom_uid_i:$dmid:$userid" ];
    my $duid = FB::MemCache::get($memkey);
    return $duid if $duid;

    my $db = @FB::MEMCACHE_SERVERS ? FB::get_db_writer() : FB::get_db_reader();
    return undef unless $db;

    my $n_userid = $userid + 0;
    $duid = $db->selectrow_array("SELECT kval FROM useridlookup " .
                                 "WHERE domainid=$dmid AND ktype='I' AND userid=$n_userid");
    if ($duid) {
        FB::MemCache::set($memkey => $duid);
        return $duid;
    }

    return undef;
}

# accepts list of local userids, returns hashref of local userid => domain userid
sub get_domain_userid_multi
{
    return undef unless @_;

    my $opts = ref $_[0] eq 'HASH' ? shift : {};
    my $dmid = defined $opts->{domainid} ? $opts->{domainid}+0 : FB::current_domain_id();

    my $dbr = FB::get_db_reader() or return undef;
    my $userid_in = join(",", map { $_ + 0 } @_);
    my $idmap = $dbr->selectall_arrayref
        ("SELECT userid, kval FROM useridlookup WHERE ktype='I' AND domainid=$dmid AND userid IN ($userid_in)");
    return undef unless $idmap;

    # local_userid => domain_userid
    return { map { @$_ } @$idmap };
}

# accepts list of domain userids, returns hashref of domain userid => local userid
sub get_local_userid_multi
{
    return undef unless @_;

    my $opts = ref $_[0] eq 'HASH' ? shift : {};
    my $dmid = defined $opts->{domainid} ? $opts->{domainid}+0 : FB::current_domain_id();

    my $dbr = FB::get_db_reader() or return undef;
    my $id_in = join(",", map { $dbr->quote($_) } @_);
    my $idmap = $dbr->selectall_arrayref
        ("SELECT kval, userid FROM useridlookup WHERE ktype='I' AND domainid=$dmid AND kval IN ($id_in)");
    return undef unless $idmap;

    # domain_userid => local_userid
    return { map { @$_ } @$idmap };
}


sub get_remote
{
    my $lju = LJ::get_remote() or return undef;
    my $remote = FB::User->new_from_lj_user($lju);

    eval { Apache->request->notes('fb_userid' => $remote ? $remote->{'userid'} : 0); };
    return $remote;
}

sub canonical_username
{
    my ($arg, $dmid) = @_;
    my $usercs;
    if (ref $arg) {
        $dmid = $arg->{'domainid'};
        $usercs = $arg->{'usercs'};
    } else {
        $usercs = $arg;
    }
    # FIXME: if defined $dmid, then call auth domain's canonical_user func
    my $user = lc($usercs);
    return undef if length($user) > 35;
    $user =~ s/\s+//g;
    return undef if length($user) > 30;
    return undef if $user =~ /\W/;
    return $user;
}

# return a hashref of all galleries for given $u
sub gals_of_user
{
    my $u = shift;
    return undef unless ref $u;

    return undef unless $u->writer;

    my $sql = q{
        SELECT * FROM gallery WHERE userid=?
    };

    my $gals = $u->selectall_hashref($sql, 'gallid', $u->{userid});

    foreach my $gallid (keys %$gals) {
        my $g = $gals->{$gallid};
        FB::label_gallery_flags($g);
    }

    return $gals;
}

sub load_gallery_incoming
{
    my $u = shift;
    return load_gallery($u, ":FB_in", { 'createsec' => 0, 'core' => 1 });
}

sub load_gallery_id
{
    &nodb;

    my ($u, $gallid, $opts) = @_;

    my $g = $FB::REQ_CACHE{"gallid:$u->{'userid'}:$gallid"};

    unless ($g) {
        $g = $u->selectrow_hashref("SELECT * FROM gallery WHERE userid=? AND gallid=?",
                                   $u->{'userid'}, $gallid);
        if ($g) {
            $g->{galsec} = $g->{secid};
            FB::label_gallery_flags($g);
            $FB::REQ_CACHE{"gallid:$u->{'userid'}:$gallid"} = $g;
        }
    }
    return undef unless $g;

    # load other metadata?
    FB::load_gallery_props($u, $g, @{$opts->{'props'}})
        if $opts->{'props'};

    return $g;
}

sub load_gallery
{
    &nodb;

    my ($u, $gname, $opts) = @_;

    return undef unless $u->writer;

    my $g;
    if (exists $opts->{'gallid'}) {
        return undef unless $opts->{'gallid'};
        $g = FB::load_gallery_id($u, $opts->{'gallid'});
        return undef unless $g;
    } else {
        $g = $u->selectrow_hashref("SELECT * FROM gallery WHERE userid=? AND name=?",
                                   $u->{'userid'}, $gname);
        $g->{galsec} = $g->{secid} if $g;
    }

    # don't return built-in galleries if caller doesn't want.
    return undef if ($g && $opts->{'useronly'} && $g->{'name'} =~ /^:FB_/);

    FB::label_gallery_flags($g) if $g;

    # load relations?
    if ($g && $opts->{'withrels'}) {
        # relations to us (find our parents, for example)
        my $sth;
        $sth = $u->prepare("SELECT gallid, type FROM galleryrel ".
                           "WHERE userid=? AND gallid2=?",
                           $u->{'userid'}, [$g->{'gallid'}, "int"]);
        $sth->execute;
        while (my ($sid, $type) = $sth->fetchrow_array) {
            $g->{'_rel_from'}->{$type}->{$sid} = 1;
        }

        # relations from us (find our children)
        $sth = $u->prepare("SELECT gallid2, type, sortorder FROM galleryrel ".
                           "WHERE userid=? AND gallid=?",
                           $u->{'userid'}, $g->{'gallid'});
        $sth->execute;
        while (my ($did, $type, $so) = $sth->fetchrow_array) {
            $g->{'_rel_to'}->{$type}->{$did} = $so;
        }
    }

    # load other metadata?
    if ($g && $opts->{'props'}) {
        FB::load_gallery_props($u, $g, @{$opts->{'props'}});
    }

    return $FB::REQ_CACHE{"gallid:$u->{userid}:$g->{gallid}"} = $g if $g;
    return undef unless defined $opts->{'createsec'};
    return undef if $gname =~ /^:FB_/ && ! defined $opts->{'core'};
    my $secid = $opts->{'createsec'}+0;
    return undef unless FB::valid_security_value($u, $secid);

    $g = FB::create_gallery($u, $gname, $secid, 0);
    return undef unless $g;

    ${$opts->{'created_flag'}} = 1 if ref $opts->{'created_flag'} eq "SCALAR";
    return $FB::REQ_CACHE{"gallid:$u->{userid}:$g->{gallid}"} = $g;
}

# return array of upics in any gallery
# return undef on caller err
sub user_galleryrel
{
    my ($u, $opts) = @_;
    return undef unless ref $u;
    return undef unless wantarray;

    # get reference counts of user upics
    my $limit = $opts->{limit} ? "LIMIT " . ($opts->{limit}+0) : '';
    my $q = qq{
        SELECT gallid, gallid2, type, sortorder
        FROM galleryrel WHERE userid=? $limit
    };
    my $sth = $u->prepare($q, $u->{userid});
    $sth->execute or return undef;
    my @rows = ();
    my $rel;
    push @rows, $rel while $rel = $sth->fetchrow_hashref;

    return @rows;
}

# return array of upics in any of a user's galleries
# return undef on caller err
sub user_gallerypics
{
    my ($u, $opts) = @_;
    return undef unless ref $u;
    return undef unless wantarray;

    # get reference counts of user upics
    my $limit = $opts->{limit} ? "LIMIT " . ($opts->{limit}+0) : '';
    my $q = qq{
        SELECT gallid, upicid, dateins, sortorder
        FROM gallerypics WHERE userid=? $limit
    };
    my $sth = $u->prepare($q, $u->{userid});
    $sth->execute or return undef;
    my @rows = ();
    my $pr;
    push @rows, $pr while $pr = $sth->fetchrow_hashref;

    return @rows;
}

sub generate_challenge # DEPRECATED (for users):  use $u->generate_challenge
{
    my $u = shift;
    my $db = $u ? FB::get_user_db_writer($u) : FB::get_db_writer();
    return undef unless $db;
    if ($u) {
        $db->do("DELETE FROM challenges WHERE userid=? AND ".
                "timecreate < UNIX_TIMESTAMP()-60",
                undef, $u->{'userid'});
    } else {
        $db->do("DELETE FROM challengesanon WHERE ".
                "timecreate < UNIX_TIMESTAMP()-120");
    }
    my $chal = FB::rand_chars(40);
    if ($u) {
        my $auth = FB::domain_plugin($u);
        return $auth->generate_challenge($u) if $auth;
        $db->do("INSERT INTO challenges (userid, timecreate, challenge) VALUES (?,UNIX_TIMESTAMP(),?)",
                undef, $u->{'userid'}, $chal);
    } else {
        $db->do("INSERT INTO challengesanon (timecreate, challenge) VALUES (UNIX_TIMESTAMP(),?)",
                undef, $chal);
    }
    return $db->err ? undef : $chal;
}

sub generate_session
{
    my ($u, $opts) = @_;
    return undef unless $u->writer;

    my $sess = {};
    $opts->{'exptype'} = "short" unless $opts->{'exptype'} eq "long";
    $sess->{'auth'} = FB::rand_chars(10);
    my $expsec = $FB::SESSION_LENGTH{$opts->{'exptype'}};
    $u->do("INSERT INTO sessions (userid, sessid, auth, exptype, ".
           "timecreate, timeexpire, ipfixed) VALUES (?,NULL,?,?,UNIX_TIMESTAMP(),".
           "UNIX_TIMESTAMP()+$expsec,?)",
           $u->{'userid'}, $sess->{'auth'}, $opts->{'exptype'}, $opts->{'ipfixed'});
    return undef if $u->err;
    $sess->{'sessid'} = $u->mysql_insertid;
    $sess->{'userid'} = $u->{'userid'};
    $sess->{'ipfixed'} = $opts->{'ipfixed'};

    # clean up old sessions
    my $old = $u->selectcol_arrayref("SELECT sessid FROM sessions WHERE ".
                                     "userid=? AND ".
                                     "timeexpire < UNIX_TIMESTAMP()",
                                     $u->{'userid'});
    $u->kill_sessions(@$old) if $old;

    return $sess;
}


sub check_auth
{
    my $uuser = shift;
    my $cred = shift;

    my $u;
    if (defined $uuser) {
        $u = want_user($uuser);
    }

    if ($cred =~ /^plain:(.+)$/) {
        return undef unless $u;
        return undef unless $u->{'password'} ne "" && $u->{'password'} eq $1;
        return $u;
    }

    my @parts = split(/:/, $cred);
    my $scheme = shift @parts;

    # web session
    if ($scheme eq "ws") {
        my ($user, $sessid, $auth) = @parts;
        $u = FB::load_user($user);
        return undef unless $u;
        my $sess = $u->selectrow_hashref(qq{
            SELECT *, UNIX_TIMESTAMP() AS 'now' FROM sessions
            WHERE userid=? AND sessid=? AND auth=?
        }, $u->{'userid'}, $sessid, $auth);
        return undef unless $sess;
        return undef if ($sess->{'ipfixed'} &&
                         $sess->{'ipfixed'} ne FB::get_remote_ip());

        # renew login sessions
        my $sess_length = $FB::SESSION_LENGTH{$sess->{exptype}};
        if ($sess_length && ($sess->{'timeexpire'} - $sess->{'now'}) < $sess_length/2) {

            my $sess_future = $sess->{now} + $sess_length;
            my $cookie_future = $sess->{exptype} eq 'long' ? $sess_future : 0;

            my $udbh = FB::get_user_db_writer($u);

            # extend session length in the database
            if ($udbh && $udbh->do("UPDATE sessions SET timeexpire=? WHERE userid=? AND sessid=?",
                                   undef, $sess_future, $u->{userid}, $sess->{sessid}))
            {
                # renew non-session-length cookies
                $BML::COOKIE{'fbsession'} = [ "ws:$u->{'user'}:$1:$2", $cookie_future ] if $cookie_future;
            }
        }

        # augment hash with session data;
        $u->{'_session'} = $sess;

        return $u;
    }

    # challenge/response
    if ($scheme eq "crp" || $scheme eq "anoncrp") {
        # optionally, username can go after
        if (! $u && $parts[2]) {
            my $user = $parts[2];
            $u = FB::load_user($user);  # uses current domainid
        }
        return undef unless $u;
        my $chal = $parts[0];
        my $res = $parts[1];
        unless ($u->{'domainid'}) {
            # bail out early if we can (since we know the password)
            my $res_correct = Digest::MD5::md5_hex($chal . Digest::MD5::md5_hex($u->{'password'}));
            return undef unless $res eq $res_correct;
        }

        # see if challenge is even valid.  do so by deleting it, and seeing
        # if it deleted.
        my $anon = $scheme eq "anoncrp"; # (web login...)
        my $db = $anon ? get_db_writer() : get_user_db_writer($u);
        return undef unless $db;
        my $del;
        if ($anon) {
            $del = $db->do("DELETE FROM challengesanon WHERE challenge=?",
                           undef, $chal);
        } else {
            my $extra;
            if ($u->{'domainid'}) {
                # with an external domain, we don't know the plain text password,
                # so we can't determine the response, so need to check the database
                # which the auth module's generate_challenge put in
                $extra = "AND resp=" . $db->quote($res);
            }
            $del = $db->do("DELETE FROM challenges WHERE userid=? AND challenge=? ".
                           $extra, undef, $u->{'userid'}, $chal);
        }
        return undef unless $del > 0;
        return $u; # true, but also useful if caller only had $user
    }

    # unknown scheme
    return undef;
}

sub url_user  ## DEPRECATED: use $u->url
{
    my ($u) = @_;
    die "FB::url_user(): No user\n" unless $u && $u->{'userid'};
    return $u->url;
}

sub gallery_select_list
{
    my $u = shift;
    return @{$u->{'_gal_select_list'}} if exists $u->{'_gal_select_list'};
    my @ret;
    $u->{'_gal_select_list'} = \@ret;
    return unless $u->writer;
    my $sth;

    my %gal;
    $sth = $u->prepare("SELECT gallid, name FROM gallery WHERE userid=?",
                       $u->{'userid'});
    $sth->execute;
    while (my ($id, $name) = $sth->fetchrow_array) {
        next if $name =~ /^:FB_/;
        $gal{$id} = $name;
    }

    my %nest;
    $sth = $u->prepare("SELECT gallid, gallid2, sortorder ".
                       "FROM galleryrel WHERE userid=? AND type='C'",
                       $u->{userid});
    $sth->execute;
    while (my ($g1, $g2, $so) = $sth->fetchrow_array) {
        next unless $g1 == 0 || defined $gal{$g1};
        next unless defined $gal{$g2};
        $nest{$g1}->{$g2} = $so;
    }

    my $pop_nest_from = sub {
        my ($self, $gid, $depth, $seen) = @_;

        foreach my $cid (sort { $nest{$gid}->{$a} <=> $nest{$gid}->{$b} }
                         sort { $gal{$a} cmp $gal{$b} }
                         keys %{$nest{$gid}})
        {
            next if grep { $_ == $cid } @$seen;
            my $name;
            if ($depth) { $name .= "  "x$depth . "- "; }
            $name .= $gal{$cid};
            push @ret, $cid, $name;

            push @$seen, $cid;
            $self->($self, $cid, $depth+1, $seen);
            pop @$seen;
        }
    };
    $pop_nest_from->($pop_nest_from, 0, 0, []);

    return @ret;
}

sub get_large_gals  #DEPRECATED
{
    my ($u, $opts) = @_;
    my $userid = FB::want_userid($u);
    return undef unless $userid;

    my $limit = defined $opts->{'limit'} ? $opts->{'limit'} : 5;

    return undef unless $limit =~ /\d+/;

    my $dbr = FB::get_db_reader();
    return undef unless $dbr;

    my $n_userid = $userid + 0;
    my $gals = $dbr->selectall_arrayref("SELECT gp.gallid, SUM(up.bytes) AS galsize FROM " .
                                        "gallerypics gp, upic up WHERE gp.userid=$n_userid AND " .
                                        "up.userid=gp.userid AND up.upicid=gp.upicid " .
                                        "GROUP BY gp.gallid ORDER BY galsize DESC LIMIT $limit");
    return @$gals;
}

# loads all of the given privs for a given user into a hashref
# inside the user record ($u->{_privs}->{$priv}->{$arg} = 1)
# <WCMFUNC>
# name: FB::load_user_privs
# class:
# des:
# info:
# args:
# des-:
# returns:
# </WCMFUNC>
sub load_user_privs  #DEPRECATED
{
    &nodb;
    my $remote = shift;
    my @privs = @_;

    return unless $remote && @privs;

    # return if we've already loaded these privs for this user.
    my $db = FB::get_db_reader();
    @privs = map { $db->quote($_) }
             grep { ! $remote->{'_privloaded'}->{$_}++ } @privs;

    return unless (@privs);

    my $n_userid = $remote->{userid} + 0;
    my $sth = $db->prepare("SELECT pl.privcode, pm.arg ".
                           "FROM privmap pm, privlist pl ".
                           "WHERE pm.prlid=pl.prlid AND ".
                           "pl.privcode IN (" . join(',',@privs) . ") ".
                           "AND pm.userid=$n_userid");
    $sth->execute;
    while (my ($priv, $arg) = $sth->fetchrow_array)
    {
        unless (defined $arg) { $arg = ""; }  # NULL -> ""
        $remote->{'_priv'}->{$priv}->{$arg} = 1;
    }
}

# <WCMFUNC>
# name: FB::check_priv
# des: Check to see if a user has a certain privilege.
# info: Usually this is used to check the privs of a $remote user.
#       See [func[FB::get_remote]].  As such, a $u argument of undef
#       is okay to pass: 0 will be returned, as an unknown user can't
#       have any rights.
# args: db?, u, priv, arg?
# des-priv: Priv name to check for (see [dbtable[privlist]])
# des-arg: Optional argument.  If defined, function only returns true
#          when $remote has a priv of type $priv also with arg $arg, not
#          just any priv of type $priv, which is the behavior without
#          an $arg
# returns: boolean; true if user has privilege
# </WCMFUNC>
sub check_priv  #DEPRECATED
{
    &nodb;
    my ($u, $priv, $arg) = @_;
    return 0 unless $u;

    if (! $u->{'_privloaded'}->{$priv}) {
        load_user_privs($u, $priv);
    }

    if (defined $arg) {
        return (defined $u->{'_priv'}->{$priv} &&
                defined $u->{'_priv'}->{$priv}->{$arg});
    } else {
        return (defined $u->{'_priv'}->{$priv});
    }
}

sub get_user_db_reader  #DEPRECATED
{
    my $u = shift;
    my $id = ref $u ? $u->{'clusterid'} : $u;
    return FB::get_dbh("user${id}slave", "user$id");
}

sub get_user_db_writer  #DEPRECATED
{
    my $u = shift;
    my $id = ref $u ? $u->{'clusterid'} : $u;
    return FB::get_dbh("user$id");
}

sub can_view_secid  #DEPRECATED
{
    my ($u, $remote, $secid) = @_;
    return undef unless $u && defined $secid;

    $secid+=0;

    return 1 if $u->equals($remote);        # owner
    return 0 if $secid == 0;                # private, not owner
    return 1 if $secid == 255;              # public
    return 1 if $secid == 253 && $remote;   # any registered user
    return 0 unless $remote;                # any security w/ anonymous user

    # which of $u's sec groups does $remote belong to?
    return grep { $_ == $secid } FB::sec_groups($u, $remote);
}

sub secgroup_name   ## DEPRECATED: use $u->secgroup_name
{
    my ($u, $secid) = @_;
    return undef unless $u && defined $secid;
    $secid = int($secid);

    my %reserved = ( 0   => 'Private',
                     253 => 'Registered Users',
                     254 => 'All Groups',
                     255 => 'Public', );

    return $reserved{$secid} if $reserved{$secid};

    # custom security group
    my $sec = $u->load_secgroup_id($secid)
        or return undef;
    return $sec->grpname;
}

# exists in FB::User as a method, we'll just wrap as a
# function call in FB package
sub valid_security_value #DEPRECATED: use $u->valid_security_value
{
    return FB::User::valid_security_value(@_);
}

1;
