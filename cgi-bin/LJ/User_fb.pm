use strict;
package LJ::User;

#### Mixin class for LJ::User with fotobilder support functions, to eventually be eliminated
sub fb_writer {
    my $u = shift;
    return $u if $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u);
    return 0;
}

sub fb_begin_work {
    my $u = shift;
    return 1 unless $FB::INNODB_DB{$u->{clusterid}};

    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    my $rv = $dbcm->begin_work;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

sub fb_commit {
    my $u = shift;
    return 1 unless $FB::INNODB_DB{$u->{clusterid}};

    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    my $rv = $dbcm->commit;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

sub fb_rollback {
    my $u = shift;
    return 0 unless $FB::INNODB_DB{$u->{clusterid}};

    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
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

sub fb_prepare {
    my $u = shift;
    my $stmt = shift;

    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
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
sub fb_do {
    my $u = shift;
    my $query = shift;

    my $uid = $u->{userid}+0
        or croak "Database update called on null user object";

    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
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

sub fb_selectrow_array {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectrow_array($qry);
}

sub fb_selectrow_hashref {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectrow_hashref($qry);
}

sub fb_selectcol_arrayref {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectcol_arrayref($qry);
}

sub fb_selectall_arrayref {
    my $u = shift;
    my $qry = shift;
    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectall_arrayref($qry);
}

sub fb_selectall_hashref {
    my $u = shift;
    my $qry = shift;
    my $key = shift;
    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    $qry = _fill_placeholders($dbcm, $qry, @_) if @_;
    return $dbcm->selectall_hashref($qry, $key);
}

sub fb_err {
    my $u = shift;
    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    return $dbcm->err;
}

sub fb_errstr {
    my $u = shift;
    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";
    return $dbcm->errstr;
}

sub fb_quote {
    my $u = shift;
    my $text = shift;

    my $dbcm = $u->{'_fb_dbcm'} ||= FB::get_user_db_writer($u)
        or croak "Database handle unavailable";

    return $dbcm->quote($text);
}

sub fb_mysql_insertid {
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

##########

sub fb_userid {
    my $u = shift;
    return $u->fb_u->id;
}


############ FROM FB::User ############

# returns hashref (gallid -> rec) of all user's galleries
sub galleries {
    my $u = shift;
    $u = $u->fb_u;
    return {%{ $u->{_galleries} ||= FB::Gallery->load_gals($u) }};
}

sub incoming_gallery {
    my $u = shift;
    # FIXME: locking?
    my $gr = $u->fb_selectrow_hashref("SELECT * FROM gallery WHERE userid=? AND name=':FB_in'",
                                      $u->fb_userid);
    return FB::Gallery->from_gallery_row($u->fb_u, $gr) if $gr;
    return FB::Gallery->create($u->fb_u, name => ":FB_in");
}

sub load_gallery_id {
    my $u = shift;
    my $gallid = int(shift);
    my $g = FB::Gallery->new($u->fb_u, $gallid)
        or return undef;

    return undef unless $g->valid;
    return $g;
}

sub diskfree_widget {
    my $u = shift;

    my $used = $u->diskusage_bytes;
    my $quota = $u->diskquota_bytes;

    my $pct = sprintf("%0.2f", $used / $quota * 100);

    my $free = $quota - $used;
    $free = 0 if $free < 0;

    my $usedtotal = sprintf("%0.2f", $used / 1024 / 1024);
    my $total = $quota / 1024 / 1024;

    return qq {
        <div class = "FBDiskFreeWidget">
            <span class="FBDiskAvailable">Available storage space</span>
            <div class="FBDiskUsedBarContainer"><div class="FBDiskUsedBar" style="width: $pct%;"></div></div>
            <div><div class="FBDiskUsed">$usedtotal MB</div><div class="FBDiskTotal">$total MB</div></div>
            <div class="ljclear">&nbsp;</div>
        </div>
    };
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
        $u->fb_do("REPLACE INTO galleryrel (userid, gallid, gallid2, type, sortorder) ".
                  "VALUES (?,?,?,'C',0)", $u->{'userid'}, $pid, $cid);
        return 0 if $u->err;
    } else {
        $u->fb_do("DELETE FROM galleryrel WHERE userid=? AND gallid=? AND gallid2=? AND type='C'",
                  $u->{'userid'}, $pid, [$cid, "int"]);
        return 0 if $u->err;
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

    my $sth = $u->fb_prepare("SELECT gallid, gallid2 ".
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

    my $sth = $u->fb_prepare("SELECT alias, gallid FROM aliases " .
                             "WHERE userid=? AND is_primary=0") or return undef;

    $sth->execute($u->{'userid'}) or return undef;
    my $aliases = $sth->fetchall_hashref('alias');

    return $aliases;
}

sub gallery_of_existing_tag {
    my ($u, $tag) = @_;
    return $u->gallery_of_tag($tag, 1);
}

# Moves any gallery tags from the idents table to the aliases table
# and then deletes the data from the idents table
sub migrate_idents {
    my $u = shift;

    # Do we know we already did this?
    return 1 if $u->{'_idents_migrated'};

    # See if they have any old short names
    my $sth = $u->fb_prepare("SELECT did AS gallid, ident AS tag FROM " .
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
    $u->fb_do("INSERT INTO aliases (userid, alias, gallid, is_primary) VALUES $bindstr", @vars);
    die $u->errstr if $u->err;

    # Delete their old short names
    $u->fb_do("DELETE FROM idents WHERE userid=? AND itype='S' ".
              "AND dtype='G'", $u->{'userid'});

    # Mark them as migrated
    $u->{'_idents_migrated'} = 1;
    return 1;
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

# returns a url to the base path of the user's media
sub media_base_url {
    my $u = shift;

    return "http://" . $u->user . ".$LJ::USER_DOMAIN/media";
}



# returns count of all images for this user
sub picture_count {
    my $u = shift;

    my $memkey = [$u->id, "piccnt:" . $u->id];
    my $total = LJ::MemCache::get($memkey);

    return $total if defined $total;

    $total = 0;

    foreach my $gal (values %{$u->galleries}) {
        $total += $gal->pic_count;
    }

    LJ::MemCache::set($memkey, $total, 3600);

    return $total;
}

# takes old and new usernames, fixes useridlookup table and usercs column
# should be called after renames to keep the usernames in sync 
sub update_fb_user_mapping {
    my ($lju, $from, $to) = @_;

    my $fbu = $lju->fb_u or die "Could not get FB::User for LJ::User $lju->{user}";

    my $ljdomainid = $FB::LJ_DOMAINID or die "FB::LJ_DOMAINID must be defined";

    my $dbh = FB::get_db_writer() or die "Could not get FB DB writer";

    # replace and then delete any old values (don't just do an update because the user
    # might not be in sync)
    $dbh->do("REPLACE INTO useridlookup (domainid, ktype, kval, userid) " .
             "VALUES (?, ?, ?, ?)", undef, $ljdomainid, 'N', $to, $fbu->id);
    die $dbh->errstr if $dbh->err;

    $dbh->do("DELETE FROM useridlookup WHERE ktype='N' AND kval=?",
             undef, $from);
    die $dbh->errstr if $dbh->err;

    FB::update_user($fbu, { 'usercs' => $lju->user });

    # update user/usercs in memory
    $fbu->{'usercs'} = $to;
    FB::add_u_user($fbu);

    # delete old memcache
    FB::MemCache::delete([$from, "loc_uid_n:$ljdomainid:$from" ]); # old username => loc userid mapping
}

############ END FB::User METHODS ############


1;
