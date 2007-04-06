package FB::Gallery;

use strict;
use vars qw/ $AUTOLOAD /;
use Carp qw/ croak /;

# hashref innards:
#    u       -- FB::User, always
#    gallid  -- always
#    _loaded_gal -- zero until gallery is lazily loaded
#    _loaded_kib -- zero until gallery KiB is loaded
#    _loaded_props -- zero until props hashref is loaded
#    _loaded_pic_count -- zero until 'pic_count' field is loaded
#
# once _loaded_props:
#    prop  -- hashref of { propname -> propvalue}
#
# once _loaded_gal:
#    name secid randauth nextsortorder dategal timeupdate flags
#
# once _loaded_kib:
#    kib              -- KiB of pictures in gallery.  not exclusive pics.  may be in other gals
#
# once _loaded_pic_counts"
#    pic_counts         -- hashref of { secid => piccount }
#

my %singletons;  # "userid-gallid" -> FB::Gallery object


sub reset_singletons {
    my $class = shift;
    die "this is a class method" if ref $class;
    %singletons = ();
}

# creates skeleton/unverified/lazily-loaded object.
# FB::Gallery->new( {$u | $userid} , $gallid )
sub new
{
    my $class = shift;
    my $self  = bless {};

    my $uuserid = shift;
    my $gallid  = int(shift)
        or croak "Invalid gallid";

    die "bogus extra args" if @_;

    my $userid = int(ref $uuserid ? $uuserid->{userid} : $uuserid);
    my $single_key = "$userid-$gallid";
    return $singletons{$single_key} if $singletons{$single_key};

    if (ref $uuserid) {
        $self->{u} = $uuserid;
    } else {
        $self->{u} = FB::load_userid($uuserid)
            or die("couldn't load user from userid when creating gallery");
    }

    $self->{gallid}      = $gallid;
    $self->{_loaded_gal} = 0;
    return $singletons{$single_key} = $self;
}

# class method;
#SYN:   my $gal = FB::Gallery->from_gallery_row($u, $row)
# where $row is a hashref from the "gallery" table
sub from_gallery_row {
    my $class = shift;
    my $u     = shift;
    die "should be a u" unless ref $u && $u->isa("FB::User");
    my $row   = shift;
    die "row has no gallid" unless $row->{gallid};
    die "row's userid doesn't match the provided \$u" unless $row->{userid} == $u->{userid};

    my @all_fields = qw(name secid randauth nextsortorder dategal timeupdate flags);

    my $g = FB::Gallery->new($u, $row->{gallid});
    for my $f (@all_fields) {
        $g->{$f} = $row->{$f};
    }
    $g->{_loaded_gal} = 1;
    return $g;
}

# opts:
#    name -- required
#    secid -- optional, defaults to 255 (public)
#    noclean -- optional, don't clean gallery name
sub create
{
    my ($class, $u, %opts) = @_;
    $u->writer or return FB::error("nodb");

    my $name = delete $opts{name};
    return FB::error("utf8") unless FB::is_utf8(\$name);

    my $noclean = delete $opts{noclean};
    if (!$noclean) {
        $name = FB::Gallery->clean_name($name);
        return FB::error("invalid_gal_name") unless $name;
    }

    my $secid = delete $opts{secid};
    if (defined $secid) {
        return FB::error("invalid_opts") unless $secid =~ /^\d+/;
    } else {
        $secid = 255; # public
    }

    die "invalid opts (@{[ keys %opts ]})" if %opts;

    my $gallid = FB::alloc_uniq($u, "gallery_ctr");
    return FB::error("db") unless $gallid;

    my $ra = FB::rand_auth();
    $u->do("INSERT INTO gallery (userid, gallid, name, secid, randauth, ".
           "flags) VALUES (?,?,?,?,?,0)", $u->{'userid'},
           $gallid, $name, $secid, $ra);
    return undef if $u->err;

    my $g = FB::Gallery->new($u, $gallid) or return undef;
    $g->touch;

    return $g;
}

# class method.  given a user-proposed gallery names, returns either a
# clean gallery name, or undef if the name is bogus.
sub clean_name {
    my $class = shift; die "not instance method" if ref $class;
    my $galname = shift;

    # replace all whitespace with spaces
    $galname =~ s/\s/ /g;

    # can't start with a colons or spaces
    $galname =~ s/^[:\s]+//;

    # remove trailing whitespace
    $galname =~ s/\s+$//;

    return undef unless $galname =~ /\S/;
    return $galname;
}

# class method, returns true if tag exists, false if not
sub tag_exists {
    my ($class, $u, $tag) = @_;

    my $row = $u->selectrow_hashref("SELECT * FROM aliases ".
                                    "WHERE userid=? ".
                                    "AND alias=?",
                                    $u->{'userid'}, $tag);
    return $row ? 1 : 0;
}

# class method
sub load_gallery_of_tag {
    my $class = shift;
    die "this is a class method" if ref $class;
    my ($u, $tag, %opts) = @_;
    $tag =~ s/^\s+//; $tag =~ s/\s+$//;
    return undef unless $tag;

    my $no_create = delete $opts{no_create};
    die if %opts;

    # Fast path, data has been moved, so we retun the loaded gallery
    my $row = $u->selectrow_hashref("SELECT g.* FROM gallery g, aliases a ".
                                    "WHERE a.userid=? AND g.userid=a.userid ".
                                    "AND a.alias=? AND a.gallid=g.gallid AND is_primary=1",
                                    $u->{'userid'}, $tag);

    die $u->errstr if $u->err;
    return FB::Gallery->from_gallery_row($u, $row) if $row;

    # Check if their data hasn't been moved yet
    {
        my $old_row = $u->selectrow_hashref("SELECT g.* FROM gallery g, idents i ".
                                            "WHERE i.userid=? AND g.userid=i.userid ".
                                            "AND i.itype='S' AND i.ident=? AND i.dtype='G' ".
                                            "AND i.did=g.gallid",
                                            $u->{'userid'}, $tag);
        die $u->errstr if $u->err;

        if ($old_row) {
            $u->migrate_idents();
            return FB::Gallery->from_gallery_row($u, $old_row);
        }
    }

    return undef if $no_create;

    # TODO: locking?
    my $g = FB::Gallery->create($u,
                                name  => "Tag: $tag",
                                secid => 255,
                                )
        or die "failed to create gallery based on tag";
    $g->set_tag($tag);

    return $g;
}

#   FB::Gallery->load_tag_galleries($u);  # loads all tag galleries for user, keyed by tag
sub load_tag_galleries {
    my $class = shift;
    die "this is a class method" if ref $class;
    my $u = shift;
    $u->migrate_idents();

    my $sth = $u->prepare("SELECT a.alias, g.* FROM gallery g, aliases a ".
                          "WHERE a.userid=? AND g.userid=a.userid ".
                          "AND a.gallid=g.gallid AND is_primary=1",
                          $u->{'userid'});
    $sth->execute;
    my $ret = {};
    while (my $row = $sth->fetchrow_hashref) {
        my $g = FB::Gallery->from_gallery_row($u, $row);
        next unless $g;
        $g->{_loaded_tag} = 1;
        # FIXME: deal with multiple tags mapping to same gallery.  how to
        # represent that in the gallery object?  for now just store one:
        $g->{tag}         ||= $row->{alias};
        $ret->{$row->{alias}} = $g;
    }
    return $ret;
}

#   FB::Gallery->load_upic_galleries($up);  # returns array of all galleries that upic is in
sub load_upic_galleries {
    my $class = shift;
    die "this is a class method" if ref $class;
    my $up = shift;
    my $u = $up->{u};

    my $sth = $u->prepare("SELECT g.* FROM gallery g, gallerypics gp ".
                          "WHERE g.userid=? AND gp.userid=g.userid ".
                          "AND gp.upicid=? AND g.gallid=gp.gallid",
                          $u->{'userid'}, $up->id);
    $sth->execute;
    die $u->errstr if $u->err;
    my @ret;
    while (my $row = $sth->fetchrow_hashref) {
        my $g = FB::Gallery->from_gallery_row($u, $row);
        next unless $g;
        push @ret, $g;
    }
    return @ret;
}

# class method:
#   FB::Gallery->load_gals($u, [ FB::Gallery* ])
#   FB::Gallery->load_gals($u);    # loads all galleries for user, returning hashref of 'em all, keyed by gallid
sub load_gals {
    my $class = shift;
    die "this is a class method" if ref $class;
    my $u       = shift;
    my $listref = shift;
    die "too many arguments" if @_;

    my $where = "";
    my @needload;
    if ($listref) {
        @needload = grep { ! $_->{_loaded_gal} } @$listref;
        return 1 unless @needload;
        $where = _gallid_where("gallid", \@needload);
    }

    Carp::confess("bogus \$u") unless ref $u eq "FB::User";

    my $loaded = $u->selectall_hashref("SELECT userid, gallid, name, secid, randauth, nextsortorder, dategal, timeupdate, flags ".
                                       "FROM gallery WHERE userid=? $where",
                                       "gallid",
                                       $u->{'userid'})
        or return FB::error($u);

    # if no listref, we're returning hashref (keyd by gallid) of all a
    # user's galleries
    if (!$listref) {
        my $ret = {};
        foreach my $gallid (keys %$loaded) {
            my $rec = $loaded->{$gallid};  # the unblessed hashref form database
            $ret->{$gallid} = FB::Gallery->from_gallery_row($u, $rec)
                or die "failed to create record $rec->{'gallid'}";
        }
        return $ret;
    }

    # otherwise we're just filling in $g objects for them
    my $missing = 0;
    foreach my $g (@needload) {
        my $rec = $loaded->{$g->{gallid}};
        unless ($rec) {
            $missing = 1;
            next;
        }

        # don't need to modify $g, because $g is a singleton, and from_gallery_row
        # will get the same record that we have, and fill it in
        FB::Gallery->from_gallery_row($u, $rec)
    }

    return $missing ? 0 : 1;
}

sub gals_needing_field {
    my $class = shift;
    die "this is a class method" if ref $class;

    my $u       = shift;
    die "not a u" unless ref $u && $u->isa("FB::User");
    my $field   = shift;
    die "extra args" if @_;

    return grep { $_->{u}{userid} == $u->{userid} &&
                  ! $_->{$field}
              } values %singletons;
}

sub kib {
    my $self = shift;
    unless ($self->{_loaded_kib}) {
        # while we're loading for one, load for any outstanding we might have skeletons for
        __PACKAGE__->load_gal_kib($self->{u}, [ __PACKAGE__->gals_needing_field($self->{u}, "_loaded_kib") ]) or die;
    }
    return $self->{kib};
}

# helper function
sub _gallid_where {
    my ($col, $list, $all_thres) = @_;
    # if list is greater than $all_thres threshold, don't return a
    # WHERE query and let's just load everything.
    return "" if defined $all_thres && @$list > $all_thres;
    # impossible where, to prevent queries, if caller didn't check
    # their list being empty.
    return "AND 1=0" unless @$list;
    return "AND $col=" . int($list->[0]{gallid}) if @$list == 1;
    return "AND $col IN (" . join(",", map { int($_->{gallid}) } @$list) . ")";
}

# class method:  load all/some disk usage (non-unique) per gallery, in KiB.
#
#   FB::Gallery->load_gal_kib($u, [ FB::Gallery* ])
sub load_gal_kib {
    my $class = shift;
    die "this is a class method" if ref $class;

    my $u       = shift;
    die "not a u" unless ref $u && $u->isa("FB::User");

    my $listref = shift;
    die "too many arguments" if @_;

    my @needload = grep { ! $_->{_loaded_kib} } @$listref;
    return 1 unless @needload;

    my $where = _gallid_where("g.gallid", \@needload, 50);
    my $kibmap = $u->selectall_hashref("SELECT g.gallid, floor(sum(p.bytes) / 1024) as 'kib' ".
                                       "FROM upic p, gallerypics g WHERE p.userid=? AND g.userid=p.userid AND p.upicid=g.upicid $where ".
                                       "GROUP BY 1",
                                       "gallid", $u->{userid})
        or return FB::error($u);


    # otherwise we're just filling in $g objects for them
    foreach my $g (@needload) {
        my $rec = $kibmap->{$g->{gallid}};
        $g->{kib} = $rec ? $rec->{kib} : 0;
        $g->{_loaded_kib} = 1;
    }

    return 1;
}

*count = \&pic_count;
sub pic_count {
    my $self = shift;
    unless ($self->{_loaded_pic_counts}) {
        # while we're loading for one, load for any outstanding we might have skeletons for
        __PACKAGE__->load_pic_counts($self->{u}, [ __PACKAGE__->gals_needing_field($self->{u}, "_loaded_pic_counts") ]) or die;
    }

    my $phash = $self->{pic_counts} or die "pic_counts hash should be loaded for $self->{gallid}";
    my $sum = 0;
    foreach my $secid (keys %$phash) {
        my $ct = $phash->{$secid};
        $sum += $ct;
    }

    return $sum;
}

# class method:  load all/some gallery picture counts.
#
#   FB::Gallery->load_pic_counts($u, [ FB::Gallery* ])
sub load_pic_counts {
    my $class = shift;
    die "this is a class method" if ref $class;

    my $u       = shift;
    die "not a u" unless ref $u && $u->isa("FB::User");

    my $listref = shift;
    die "too many arguments" if @_;

    my @needload = grep { ! $_->{_loaded_pic_counts} } @$listref;
    return 1 unless @needload;

    my $where = _gallid_where("gallid", \@needload, 50);
    my $sth = $u->prepare("SELECT gallid, secid, count " .
                          "FROM gallerysize WHERE userid=? $where AND count > 0",
                          $u->{userid})
        or return FB::error($u);

    $sth->execute;
    return FB::error($u) if $u->err;

    my %size;
    while (my ($gid, $secid, $ct) = $sth->fetchrow_array) {
        $size{$gid}{$secid} = $ct;
    }

    # otherwise we're just filling in $g objects for them
    foreach my $g (@needload) {
        $g->{pic_counts} = $size{$g->{gallid}} || {};
        $g->{_loaded_pic_counts} = 1;
    }

    return 1;
}

sub _load {
    return 1 if $_[0]->{_loaded_gal};
    my $self = shift;
    return __PACKAGE__->load_gals($self->{u}, [ $self ]);
}

sub id {
    return $_[0]->{'gallid'};
}

sub valid {
    return $_[0]->_load;
}

sub url {
    my $self = shift;
    $self->_load or die "can't load gallery";

    my $u = $self->{u};

    my $code = FB::make_code($self->{'gallid'}, $self->{'randauth'});
    return $u->url_root . "gallery/$code";
}

sub tag_url {
    my $self = shift;
    $self->_load or die "can't load gallery";

    my $u = $self->{u};
    my $tag = $self->tag
        or die "no tag for gallery";

    return $u->url_root . "tags/" . FB::eurl($tag) . "/";
}

sub manage_url {
    my $self = shift;
    return "/manage/gal?id=" . $self->id;
}

sub date {
    my $self = shift;
    $self->_load or die "can't load gallery";
    return FB::date_without_zero($self->{dategal});
}

sub timeupdate_unix {
    my $self = shift;
    $self->_load or die "can't load gallery";
    return $self->{timeupdate};
}

sub set_date {
    my ($self, $date) = @_;

    $self->_load or die "can't load gallery";
    my $old = $self->{dategal};

    $date = FB::date_from_user($date);

    return 1 if $old eq $date;

    my $u = $self->{u};
    $u->do("UPDATE gallery SET dategal=? WHERE userid=? AND gallid=?",
           $date, $u->{userid}, $self->{gallid})
        or return 0;

    $self->{dategal} = $date;
    $self->touch;
    return 1;
}

sub visible {
    my $self = shift;
    return $self->visible_to(FB::User->remote);
}

sub visible_to {
    my ($self, $remote) = @_;
    # FIXME: make this more efficient
    return FB::can_view_secid($self->{u}, $remote, $self->secid);
}

sub visible_to_secid {
    my ($self, $remote, $secid) = @_;
    return FB::can_view_secid($self->{u}, $remote, $secid);
}

sub secid {
    my $self = shift;
    $self->_load or die "can't load gallery";
    return $self->{secid};
}

sub randauth {
    my $self = shift;
    $self->_load or die "can't load gallery";
    return $self->{randauth};
}

sub owner {
    my $self = shift;
    $self->_load or die "can't load gallery";
    return $self->{u};
}

sub raw_name {
    my $self = shift;
    $self->_load or die "can't load gallery";
    return $self->{name};
}

sub display_name {
    my $self = shift;
    $self->_load or die "can't load gallery";

    my $name = $self->{name};
    my %mappings = (
                    ':FB_in' => "Unsorted",
                    ':FB_copies' => "Copies",
                    );

    return $mappings{$name} if exists $mappings{$name};
    return "Day: $1-$2-$3" if $name =~ /^day(\d\d\d\d)(\d\d)(\d\d)$/;
    return $name;
}

sub prop {
    my ($self, $prop) = @_;
    unless ($self->{_loaded_props}) {
        __PACKAGE__->load_props($self->{u}, [ __PACKAGE__->gals_needing_field($self->{u}, "_loaded_props") ]) or die;
    }
    return $self->{prop}{$prop};
}

# class method:  load props on given galleries
#
#   FB::Gallery->load_props($u, [ FB::Gallery* ])
sub load_props {
    my $class = shift;
    die "this is a class method" if ref $class;

    my $u       = shift;
    die "not a u" unless ref $u && $u->isa("FB::User");

    my $listref = shift;
    die "too many arguments" if @_;

    my @needload = grep { ! $_->{_loaded_props} } @$listref;
    return 1 unless @needload;

    my $where = _gallid_where("gallid", \@needload);

    # prop names
    my $ps = FB::get_props();

    my $prop = {};  # gallid -> propname -> value
    my $sth = $u->prepare("SELECT gallid, propid, value FROM galleryprop " .
                          "WHERE userid=? $where",
                          $u->{'userid'});
    $sth->execute;
    while (my ($gallid, $id, $value) = $sth->fetchrow_array) {
        my $name = $ps->{$id};
        unless ($name) {
            warn("loaded unknown prop: id=$id");
            next;
        }
        $prop->{$gallid} ||= {};
        $prop->{$gallid}{$name} = $value;
    }

    foreach my $gal (@needload) {
        $gal->{prop}          = $prop->{$gal->id} || {};
        $gal->{_loaded_props} = 1;
    }

    return 1;
}

sub set_prop {
    my ($self, $prop, $value) = @_;
    my $u = $self->{u};

    # bail out early, if we know the value's already the same
    return 1 if $self->{_loaded_props} && $self->{prop}{$prop} eq $value;

    my $ps  = FB::get_props() or return 0;
    my $pid = $ps->{$prop}    or return 0;

    if ($value) {
        $u->do("REPLACE INTO galleryprop (userid, gallid, propid, value) ".
               "VALUES (?,?,?,?)", $u->{'userid'}, $self->{'gallid'},
               $pid, $value) or return 0;
        $self->{prop}{$prop} = $value if $self->{_loaded_props};
    } else {
        $u->do("DELETE FROM galleryprop WHERE userid=? AND gallid=? AND propid=?",
               $u->{'userid'}, $self->{'gallid'}, $pid) or return 0;
        delete $self->{prop}{$prop} if $self->{_loaded_props};
    }
    $self->touch;
    return 1;
}

sub des {
    my $self = shift;
    return $self->{des} if $self->{_loaded_des};
    my $u = $self->{u};

    my $des = $u->selectrow_array("SELECT des FROM des WHERE userid=? AND ".
                                  "itemtype=? AND itemid=?",
                                  $u->{userid}, "G", $self->{gallid});

    $self->{_loaded_des} = 1;
    return $self->{des} = $des;
}

sub set_des {
    my ($self, $des) = @_;
    my $old = $self->des;
    return 1 if $old eq $des;
    return 0 unless FB::is_utf8($des);
    my $u = $self->{u};

    if ($des) {
        $u->do("REPLACE INTO des (userid, itemtype, itemid, des) VALUES ".
               "(?,?,?,?)", $u->{'userid'}, "G", $self->{gallid}, $des);
        $self->{'des'} = $des;
    } else {
        $u->do("DELETE FROM des WHERE userid=? AND itemtype=? AND itemid=?",
               $u->{'userid'}, "G", $self->{gallid});
        delete $self->{'des'};
    }
    $self->{_loaded_des} = 1;
    $self->touch;
    return 1;
}

sub set_secid
{
    my ($self, $secid) = @_;
    return undef unless defined $secid;
    $secid += 0;

    # return immediate if unchanged
    return 1 if $self->{_loaded_gal} && $self->{secid} == $secid;

    my $u = $self->{u};
    $u->do("UPDATE gallery SET secid=? WHERE userid=? AND gallid=?",
           $secid, $u->{userid}, $self->{gallid})
        or return undef;

    $self->touch;

    return 1;
}

sub tag {
    my $self = shift;
    return $self->{tag} if $self->{_loaded_tag};

    my $u = $self->{u};
    $u->migrate_idents();

    my $tag = $u->selectrow_array("SELECT alias FROM aliases " .
                                  "WHERE userid=? AND gallid=? AND is_primary=1",
                                  $u->{'userid'}, $self->{'gallid'});

    # FIXME: how to deal with errors?  returning undef is meaningful
    # here (no tag) die, I suppose.

    $self->{_loaded_tag} = 1;
    return $self->{tag} = $tag;
}

sub aliases {
    my $self = shift;
    return $self->{aliases} if $self->{_loaded_aliases};

    my $u = $self->{u};

    my $aliases = $u->selectall_arrayref("SELECT alias FROM aliases " .
                                         "WHERE userid=? AND gallid=? AND is_primary=0",
                                         $u->{'userid'}, $self->{'gallid'});

    # FIXME: how to deal with errors?  returning undef is meaningful
    # here (no tag) die, I suppose.

    $self->{_loaded_aliases} = 1;
    return $self->{aliases} = $aliases;
}

# set primary tag to represent this gallery
sub set_tag {
    my ($self, $tag) = @_;
    my $old = $self->tag;
    return 1 if $old eq $tag;
    return 0 unless FB::is_utf8(\$tag);

    my $u = $self->{u};
    $u->migrate_idents();

    if ($tag) {
        if (!$old && !FB::Gallery->tag_exists($u, $tag)) {
            $u->do("INSERT INTO aliases (userid, gallid, alias, is_primary) " .
                   "VALUES (?, ?, ?, 1)",
                   $u->{'userid'}, $self->{'gallid'}, $tag) or return 0;
        } else {
            $u->do("UPDATE aliases SET alias=? WHERE userid=? AND gallid=? AND is_primary=1",
                   $tag, $u->{'userid'}, $self->{'gallid'}) or return 0;
        }
    } else {
        # As we are deleting the tag, so it is no longer
        # a tag gallery, also delete the aliases
        $u->do("DELETE FROM aliases WHERE userid=? AND gallid=?",
               $u->{'userid'}, $self->{'gallid'}) or return 0;
    }

    $self->{tag} = $tag;
    $self->{_loaded_tag} = 1;
    $self->touch;
    return 1;
}

# add alias tags to represent this gallery
sub add_aliases {
    my ($self, $aliases) = @_;

    return 0 unless ref $aliases eq 'ARRAY';

    my $u = $self->{u};

    my @bindvars;
    foreach my $tag (@$aliases) {
        return 0 unless FB::is_utf8(\$tag);

        push @bindvars, $u->{'userid'};
        push @bindvars, $self->{'gallid'};
        push @bindvars, $tag;
    }

    # userid, A, tag, G, gall id
    my $bind = join(',', map { "(?, ?, ?, 0)" } @$aliases);

    # Don't care if these are dupes
    $u->do("INSERT IGNORE INTO aliases (userid, gallid, alias, is_primary) VALUES $bind",
           @bindvars) or return 0;

    $self->{aliases} = $aliases;
    $self->{_loaded_aliases} = 1;
    return 1;
}

sub delete_alias {
    my ($self, $alias) = @_;

    return 0 unless $alias;

    my $u = $self->{u};
    $u->do("DELETE FROM aliases WHERE userid=? AND gallid=? AND alias=?",
           $u->{'userid'}, $self->{'gallid'}, $alias) or return 0;

    $self->{_loaded_aliases} = 0;
    return 1;
}

sub name {
    my ($self) = @_;
    $self->valid or die;
    return $self->{'name'};
}

sub set_name {
    my ($self, $name) = @_;
    $self->_load or return undef;
    my $old = $self->{'name'};

    $name =~ s/[\n\r]//g;
    $name =~ s/^\s+//;
    $name =~ s/\s+$//;

    return 1 if $old eq $name;
    return 0 unless $name =~ /\S/;
    return 0 unless FB::is_utf8(\$name);
    my $u = $self->{u};

    $u->do("UPDATE gallery SET name=? WHERE userid=? AND gallid=?",
           $name, $u->{'userid'}, $self->{gallid})
        or return 0;

    $self->{name} = $name;
    $self->touch;
    return 1;
}

sub is_unsorted {
    my $self = shift;
    $self->_load;
    return $self->{'name'} eq ":FB_in";
}

sub preview_pic {
    my $self = shift;

    my $getpic = sub {
        my $upicid = $self->previewpicid;
        return undef unless $upicid;
        return FB::Upic->new($self->{u}, $upicid);
    };

    # try first time...
    my $up = $getpic->();

    # been deleted?
    if ($up && ! $up->valid) {
        $self->set_prop("previewpicid", "");
        # try again...
        $up = $getpic->();
    }

    return $up;
}

# returns previewpicid of a gallery, auto-vivifying the value to first pic in
# gallery, if prop isn't "none" in database.
sub previewpicid {
    my $self = shift;
    return undef if $self->is_unsorted;

    my $pval = $self->prop("previewpicid");

    # pval can be "none" (explictly none, by user) or "none@<epoch>",
    # where that means the system tried to vivify one and found none
    # at time <epoch> if the gallery's modtime is since that time, we
    # should ignore that none.
    if ($pval) {
        if ($pval =~ /^none(?:\@(\d+))?$/) {
            my $none_since = $1;
            return 0 unless $none_since;
            return 0 unless $self->_load;
            return 0 if $self->{timeupdate} < $none_since;
        } else {
            $pval =~ s/\?$//;  # remove trailing question mark, which implies it was system-chosen, not user-chosen
            return $pval;
        }
    }

    # let's see if we can find a picture to use instead
    my @pics = $self->get_pictures(limit => 1);
    if (@pics) {
        my $firstid = $pics[0]->{upicid};
        $self->set_prop("previewpicid", "$firstid?");
        return $firstid;
    } else {
        $self->set_prop("previewpicid", "none\@" . time());
        return 0;
    }
}

sub visible_pictures {
    my $self   = shift;
    my $remote = FB::User->remote;
    die "bogus args" if @_;
    my $u = $self->{u};
    my @secids = FB::sec_groups($u, $remote);
    my %secok = map { $_, 1 } @secids;

    my @pre = $self->pictures;
    return grep { $secok{$_->secid} } $self->pictures;
}

*pictures = \*get_pictures;
sub get_pictures {
    my ($self, %opts) = @_;

    my $u      = $self->{u};
    my $gallid = $self->{gallid};

    my $limit  = int(delete $opts{limit});
    die "bogus opts" if %opts;

    return undef unless $u->writer;

    my $q = "SELECT u.userid, u.upicid, u.width, u.height, u.fmtid, u.randauth, u.bytes, " .
        "u.secid, gp.sortorder, u.gpicid " .
        "FROM upic u, gallerypics gp " .
        "WHERE u.userid=? AND gp.userid=u.userid AND gp.gallid=? " .
        "AND gp.upicid=u.upicid";
    $q .= " ORDER BY gp.sortorder, u.upicid LIMIT $limit" if $limit;

    my %pics = %{ $u->selectall_hashref($q, 'upicid', $u->{userid}, $gallid) || {} };

    map { delete $pics{$_} if FB::fmtid_is_video( $pics{$_}->{'fmtid'} ) } keys %pics;

    # FIXME: cache this list on the gallery object, with all data, then apply secid filtering afterwards?
    return map { FB::Upic->from_upic_row($u, $_) } sort {
        $a->{'sortorder'} <=> $b->{'sortorder'} ||
        $a->{'upicid'} <=> $b->{'upicid'}
    } values %pics;
}


# returns list of FB::Gallery objects linking to/from this gallery.
# the magical value of "0" means top-level gallery, which doesn't
# have an object or pseudo-gallery (yet? debatable.)
*gals_linked_from = _createfunc_gals_linked("from");
*gals_linked_to   = _createfunc_gals_linked("to");
sub _createfunc_gals_linked {
    my $rel = shift;
    return sub {
        my $self = shift;
        my $u = $self->{u};

        my @ret;

        # type='C' means child (our old terminology before we thought
        # about users understanding it)
        my $selcol   = $rel eq "from" ? "gallid" : "gallid2";
        my $wherecol = $rel eq "from" ? "gallid2" : "gallid";
        my $sth = $u->prepare("SELECT $selcol FROM galleryrel ".
                              "WHERE userid=? AND $wherecol=? AND type='C'",
                              [$u->{'userid'}, "int"], [$self->{'gallid'}, "int"]);
        $sth->execute;
        my $include_top_level = 0;
        while (my ($gid) = $sth->fetchrow_array) {
            unless ($gid) {
                # no galleryid implies the magical top-level
                next unless $rel eq "from";
                $include_top_level = 1;
                next;
            }
            push @ret, ($gid ? FB::Gallery->new($u, $gid) : 0);
        }

        FB::Gallery->load_gals($u, \@ret);

        @ret = sort { $a->{'name'} cmp $b->{'name'}  } @ret;
        unshift @ret, 0 if $include_top_level;
        return @ret;
    };
}

# no return value
sub link_from_tags {
    my ($self, $tags) = @_;

    $tags =~ s/^\s+//;
    $tags =~ s/\s+$//;

    my $u = $self->{u};
    foreach my $tag (split(/\s*,\s*/, $tags)) {
        my $gal = $u->gallery_of_tag($tag);
        next unless $gal;
        $self->link_from($gal);
    }
}

# may be 0 for top-level
sub link_from {
    my ($self, $parent) = @_;
    $self->{u}->setup_gal_link($parent, $self, 1);
    $self->touch;
}

sub unlink_from {
    my ($self, $parent) = @_;
    $self->{u}->setup_gal_link($parent, $self, 0);
    $self->touch;
}

sub unlink_from_all {
    my ($self) = @_;
    foreach my $p ($self->gals_linked_from) {
        return 0 unless $self->unlink_from($p);
    }
    return 1;
}

sub link_to {
    my ($self, $child) = @_;
    $self->{u}->setup_gal_link($self, $child, 1);
    $self->touch;
}

sub unlink_to {
    my ($self, $child) = @_;
    $self->{u}->setup_gal_link($self, $child, 0);
    $self->touch;
}

sub add_picture
{
    my ($self, $up) = @_;

    my $u       = $self->{u};
    my $gallid = $self->{gallid};
    die "Gallery doesn't exist.  Can't add picture" unless $self->valid;
    die "Upic doesn't exist.  Can't add picture" unless $up->valid;

    $u->writer
        or return FB::error("Couldn't connect to user database writer");

    my $rows = $u->do("INSERT IGNORE INTO gallerypics (userid, gallid, upicid, ".
                      "dateins, sortorder) VALUES (?,?,?,UNIX_TIMESTAMP(),?)",
                      $u->{userid}, $gallid, $up->id,
                      $self->{'nextsortorder'}+0);
    if ($rows > 0) {
        FB::change_gal_size($u, $self, $up->secid, +1)
            or return undef; # error was set inside function

        # FIXME: racy.  use MySQL's LAST_INCREMENT(..) function to
        # snag the real value on the way back from the update
        $self->{'nextsortorder'}++;

        $u->do("UPDATE gallery SET timeupdate=UNIX_TIMESTAMP(), nextsortorder=nextsortorder+1 ".
               "WHERE userid=? AND gallid=?", $u->{userid}, $self->{gallid});
    }

    $self->touch;

    return FB::error($u) if $u->err;
    return 1;
}

sub remove_picture
{
    my ($self, $up) = @_;

    my $u       = $self->{u};
    my $gallid = $self->{gallid};
    die "Gallery doesn't exist.  Can't remove picture" unless $self->valid;
    die "Upic doesn't exist.  Can't remove picture" unless $up->valid;

    $u->writer
        or return FB::error("Couldn't connect to user database writer");

    my $rows = $u->do("DELETE FROM gallerypics WHERE userid=? AND gallid=? ".
                      "AND upicid=?", $u->{'userid'}, $gallid,
                      $up->id);
    return FB::error($u) if $u->err;

    FB::change_gal_size($u, $self, $up->secid, -1) if $rows > 0;
    $self->touch;
    return 1;
}

# class method.  takes 2 galleries (in the future, 2+) and returns
# either undef on failure, or the resultant gallery, which will likely
# be one of the two that were passed in.
sub merge {
    my $class = shift;
    die "This is a class method" if ref $class;

    my %opts = @_;
    my $gals    = delete $opts{'galleries'};
    my $err_ref = delete $opts{'errors'} || [];
    croak("Unknown options: " . join(", ", keys %opts)) if %opts;
    croak("Expecting 'galleries' arrayref") unless ref $gals eq "ARRAY";
    croak("Expecting 2 items in gallery") unless scalar @$gals == 2;

    my $cant = sub {
        my $reason = shift;
        push @$err_ref, $reason;
        return 0;
    };

    return $cant->("one_not_valid") if grep { ! $_->valid } @$gals;

    my %ct;
    my %owners;
    foreach my $g (@$gals) {
        if (++$ct{$g->id} > 1) {
            return $cant->("multiple_of_same");
        }
        $owners{$g->{u}{userid}}++;
    }
    return $cant->("different_owners") if scalar keys %owners > 1;

    # sort by not tag ||
    #   sort by create date

    my @to_merge_in = sort {
        ($a->tag ? 1 : 0) <=> ($b->tag ? 1 : 0)
            ||
        ($a->id <=> $b->id)
    } @$gals;

    # so the first item will be the gallery that lives, and the rest
    # will just merge into $pri(mary)
    my $pri = shift @to_merge_in;
    my $u = $pri->{u};

    # figure out the resultant tag for the entire merged gallery, which
    # is the tag with the most pictures
    my $max_tag      = undef;
    my $max_pics = 0;
    my @tag_aliases;
    foreach my $gal ($pri, @to_merge_in) {
        my $tag = $gal->tag;
        next unless $tag;
        my $ct = $gal->count;
        unless ($ct > $max_pics) {
            push @tag_aliases, $tag;
            next;
        }
        $max_pics = $ct;
        $max_tag = $tag;
    }

    # figure out the resultant title, ignoring "Tag: <foo>" names
    my $best_name = undef;
    foreach my $gal ($pri, @to_merge_in) {
        my $name = $gal->name;
        next if $name =~ /^Tag: /;
        $best_name = $name if
            ! $best_name ||
            length($name) > length($best_name);
    }
    $best_name ||= $max_tag ? ("Tag: " . $max_tag) : "";

    foreach my $other (@to_merge_in) {
        # merge the pictures
        foreach my $op ($other->pictures) {
            next if $pri->add_picture($op);
            return $cant->("add_pictures_error");
        }

        # merge the links
        foreach my $g ($other->gals_linked_from) {
            $pri->link_from($g);
        }
        foreach my $g ($other->gals_linked_to) {
            $pri->link_to($g);
        }
    }

    # merge the description
    $pri->set_des(join("\n---\n", grep { $_ } map { $_->des } ($pri, @to_merge_in)));
    $pri->set_tag($max_tag);
    $pri->set_name($best_name);

    # delete the losers
    foreach my $other (@to_merge_in) {
        $other->delete;
    }

    # Add the tags we merged into this gallery as aliases
    $pri->add_aliases(\@tag_aliases);

    $pri->touch;

    return $pri;
}

# delete all orphaned pictures in this gallery
sub delete_orphan_pictures {
    my $self = shift;
    $self->_delete_pictures(
                         unsorted => 'delete',
                         );
}

# move all pictures that don't belong to any other galleries in this gallery to "unsorted"
sub move_orphan_pictures {
    my $self = shift;
    $self->_delete_pictures(
                         unsorted => 'move',
                         );
}

# delete all pictures in this gallery
# careful!
sub delete_pictures {
    my $self = shift;
    $self->_delete_pictures(
                         deleteall => 'delete',
                         );
}

# %opts: unsorted => move/delete, deleteall => true/false
sub _delete_pictures {
    my $self = shift;
    my $u = $self->{u};

    my %opts = @_;

    my $unsortedopt = delete $opts{unsorted};
    my $deleteunsorted = $unsortedopt eq 'delete' ? 1 : 0;
    my $deleteallopt = delete $opts{deleteall};
    my $deleteall = $deleteallopt eq 'delete' ? 1 : 0;

    die "Invalid arguments to _delete_pictures" if %opts;

    my @pics = $self->pictures;

    foreach my $pic (@pics) {
        if ($deleteall) {
            # delete picture
            $pic->delete;
            next;
        }

        my @gals = grep { $_->id != $self->id } $pic->galleries;
        next if @gals;

        if ($deleteunsorted) {
            # if picture doesn't belong to any other galleries, delete it
            $pic->delete;
        } else {
            my $unsorted = $u->incoming_gallery;
            # move the pics to unsorted, unless they're elsewhere
            $unsorted->add_picture($pic);
        }
    }

    $self->touch;
}

sub delete {
    my $g = shift;
    return 0 unless $g->valid;
    my $u = $g->{u};
    return 0 unless $u->writer;

    # move orphans to "unsorted"
    $g->move_orphan_pictures;

    foreach my $t (qw(gallery gallerysize gallerypics)) {
        $u->do("DELETE FROM $t WHERE userid=? AND gallid=?",
               $u->{'userid'}, $g->{'gallid'});
    }

    # both sides of galleryrel
    foreach my $c (qw(gallid gallid2)) {
        $u->do("DELETE FROM galleryrel WHERE userid=? AND $c=?",
               $u->{'userid'}, [$g->{'gallid'}, "int"]);
    }

    # kill identifiers pointing to this
    $u->do("DELETE FROM idents WHERE dtype='G' AND did=? AND userid=?",
           $g->{gallid}, $u->{'userid'});
    $u->do("DELETE FROM aliases WHERE gallid=? AND userid=?",
           $g->{gallid}, $u->{'userid'});

    return 1;
}

sub info_xml {
    my $g = shift;

    my $url = FB::exml($g->url());
    my $title = FB::exml($g->name);
    my $desc = FB::exml($g->des);
    my $previewpic = $g->preview_pic;
    my $preview;

    if ($previewpic) {
        my $previewpicinfourl = FB::exml($previewpic->info_url);
        $preview = qq {
            <previewPicInfoUrl>
                $previewpicinfourl
            </previewPicInfoUrl>
        };
    }

    my @linked_from = $g->gals_linked_from;
    my @linked_to = $g->gals_linked_to;

    my $linked_from_xml;
    my $linked_to_xml;

    foreach my $gal (@linked_from) {
        next unless $gal;

        my $linkedurl = FB::exml($gal->info_url);
        $linked_from_xml .= qq{
                <infoUrl>$linkedurl</infoUrl>
                };
    }
    foreach my $gal (@linked_to) {
        next unless $gal;

        my $linkedurl = FB::exml($gal->info_url);
        $linked_to_xml .= qq{
                <infoUrl>$linkedurl</infoUrl>
                };
    }

    my $items;

    my @pics = $g->get_pictures();
    foreach my $pic (@pics) {
        next unless $pic;
        $items .= $pic->info_xml;
    }

    # todo: tags, allowcopy, pub/priv, date

    my $xml = '';
    my $infoUrl = FB::exml($g->info_url);

    $xml .= qq {
        <mediaSet xmlns="http://www.picpix.com/doc/mediaSetSchema">
            <infoUrl>$infoUrl</infoUrl>
            <displayUrl>$url</displayUrl>
            <title>$title</title>
            <description>$desc</description>
            $preview
            <linkedFrom>
            $linked_from_xml
            </linkedFrom>
            <linkedTo>
            $linked_to_xml
            </linkedTo>

            <mediaSetItems>
            $items
            </mediaSetItems>
        </mediaSet>
    };

}

sub info_url {
    my $self = shift;
    return $self->url . ".xml";
}

# update the "updated" date on this gallery

sub touch
{
    my ($self) = @_;
    my $u = $self->{u};
    $u->do("UPDATE gallery SET timeupdate=UNIX_TIMESTAMP() WHERE userid=? AND gallid=?",
           $u->{'userid'}, $self->{'gallid'});

    $self->{timeupdate} = time();
}

# this returns a hashref of useful information about this gallery,
# suitable for exporting to javascript.
sub gal_info {
    my $gal = shift;

    my @pics = map { $_->id } $gal->get_pictures;

    my $untaggedcount = scalar grep { my @tags = $_->tags; scalar @tags == 0 } $gal->get_pictures;

    my $secgroupname = FB::SecGroup->name($gal->owner, $gal->secid);
    my $secicontag = FB::SecGroup->icontag($gal->owner, $gal->secid);

    my @linksto = $gal->gals_linked_to;
    my @linksfrom = $gal->gals_linked_from;

    my @linkstoids;
    foreach my $g (@linksto) {
        push @linkstoids, ref $g ? $g->id : 0;
    }

    my @linksfromids;
    foreach my $g (@linksfrom) {
        push @linksfromids, ref $g ? $g->id : 0;
    }

    my $prevpic = $gal->preview_pic;
    my ($prevpicurl, $prevpicw, $prevpich) = $prevpic ? $prevpic->scaled_url(100, 100) : undef;
    my ($tinypicurl, $tinypicw, $tinypich) = $prevpic ? $prevpic->scaled_url(50, 50) : undef;

    return {
        'name'          => FB::transform_gal_name($gal->name),
        'date'          => $gal->date,
        'datecreated'   => $gal->date,
        'id'            => $gal->id,
        'desc'          => $gal->des,
        'secid'         => $gal->secid,
        'secgroupname'  => $secgroupname,
        'secicontag'    => $secicontag || '',
        'timeupdate'    => $gal->timeupdate_unix,
        'previewpicurl' => $prevpicurl || '',
        'previewpicw'   => $prevpicw || '',
        'previewpich'   => $prevpich || '',
        'tinypicurl'    => $tinypicurl || '',
        'tinypicw'      => $tinypicw || '',
        'tinypich'      => $tinypich || '',
        'pics'          => \@pics,
        'piccount'      => scalar @pics,
        'untaggedcount' => $untaggedcount,
        'tag'           => $gal->tag,
        'annotateurl'   => $FB::SITEROOT . '/manage/annotate?gal=' . $gal->id . '&filter=untagged',
        'linksto'       => \@linkstoids,
        'linksfrom'     => \@linksfromids,
        'is_unsorted'   => $gal->is_unsorted,
    };
}


package FB;
use strict;


# return array of unique upics to a gallery
# return undef on caller err
sub gal_unique_upics  #DEPRECATED
{
    my ($u, $gallid, $opts) = @_;
    return undef unless ref $u && $gallid;
    return undef unless wantarray;

    # get reference counts of user upics
    my $limit = $opts->{limit} ? "LIMIT " . ($opts->{limit}+0) : '';
    my $q = qq{
        SELECT COUNT(gallid), upicid, gallid FROM gallerypics
        WHERE userid=? GROUP BY upicid $limit;
    };
    my $p_counts = $u->selectall_arrayref($q, $u->{'userid'});
    my @unique_upics;

    # add to unique array if upic is part of requested
    # gallery and it only has 1 reference count
    foreach (@$p_counts) {
        push @unique_upics, $_->[1] if $_->[0] == 1 && $_->[2] == $gallid;
    }

    return @unique_upics;
}

# return array of upics in a gallery
# return undef on caller err
sub gal_upics  #DEPRECATED
{
    my ($u, $gallid, $opts) = @_;
    return undef unless ref $u && $gallid;
    return undef unless wantarray;

    # get reference counts of user upics
    my $limit = $opts->{limit} ? "LIMIT " . ($opts->{limit}+0) : '';
    my $q = qq{
        SELECT upicid FROM gallerypics
        WHERE userid=? AND gallid=?
        GROUP BY upicid $limit;
    };
    my $upicids = $u->selectcol_arrayref($q, $u->{userid}, $gallid)
        or return undef;

    return @$upicids;
}

sub gallery_relation_set  #DEPRECATED
{
    my ($u, $sgal, $dgal, $type, $sortorder) = @_;
    return 0 unless defined $sgal && defined $dgal;
    my $sgid = ref $sgal ? $sgal->{'gallid'} : $sgal;
    my $dgid = ref $dgal ? $dgal->{'gallid'} : $dgal;
    my $udbh = FB::get_user_db_writer($u);
    return 0 unless $udbh;
    if (defined $sortorder) {
        $udbh->do("REPLACE INTO galleryrel (userid, gallid, gallid2, type, sortorder) ".
                  "VALUES (?,?,?,?,?)", undef, $u->{'userid'}, $sgid, $dgid, $type, $sortorder);
        return 0 if $udbh->err;
        $sgal->{'_rel_to'}->{$type}->{$dgid} = $sortorder if ref $sgal;
        $dgal->{'_rel_from'}->{$type}->{$sgid} = 1 if ref $dgal;
    } else {
        $udbh->do("DELETE FROM galleryrel WHERE userid=? AND gallid=? AND gallid2=? AND type=?",
                  undef, $u->{'userid'}, $sgid, $dgid, $type);
        return 0 if $udbh->err;
        delete $sgal->{'_rel_to'}->{$type}->{$dgid} if ref $sgal;
        delete $dgal->{'_rel_from'}->{$type}->{$sgid} if ref $dgal;
    }
    return 1;
}

# populate gallery 'flags' with more meaningful labels
sub label_gallery_flags  #DEPRECATED
{
    my $g = shift;
    return undef unless ref $g;
    my $flags = {};
    foreach (keys %FB::GALLERY_FLAGS) {
        $flags->{ $_ } = $g->{'flags'} & (1 << $FB::GALLERY_FLAGS{$_}) ? 1 : 0;
    }
    $g->{flag} = $flags;
}

# update gallery flag bitmask.
# u, g, flagname, boolean
# returns true on successful update, undef on err
sub set_gallery_flag  #DEPRECATED
{
    my ($u, $g, $flag, $bool) = @_;
    my $bit = $FB::GALLERY_FLAGS{$flag};

    return undef unless ref $u && ref $g
        && defined $bit && defined $bool;

    my $db = FB::get_user_db_writer($u);
    my $sql;

    my $action = $bool ? "flags | 1 << $bit" : "flags & ~(1 << $bit)";

    $sql = qq{
        UPDATE gallery SET flags = $action
        WHERE userid=? AND gallid=?
    };

    return $db->do($sql, undef, $u->{userid}, $g->{gallid});
}

# instead of implicitly enabling/disabling,
# flip the flag from its current state.
sub toggle_gallery_flag  #DEPRECATED
{
    my ($u, $g, $flag) = @_;
    return undef unless ref $u && ref $g;
    return FB::set_gallery_flag($u, $g, $flag, ! $g->{flag}->{$flag});
}

sub create_gallery  #DEPRECATED
{
    my ($u, $name, $secid, $parentid, $opts) = @_;
    my $udbh = FB::get_user_db_writer($u)
        or return undef;

    my $gallid = FB::alloc_uniq($u, "gallery_ctr");
    return error("db") unless $gallid;
    return error("utf8") unless FB::is_utf8(\$name);

    my $dategal = FB::date_from_user($opts->{'dategal'});

    my $ra = FB::rand_auth();
    $udbh->do("INSERT INTO gallery (userid, gallid, name, secid, randauth, ".
              "dategal, flags) VALUES (?,?,?,?,?,?,0)", undef, $u->{'userid'},
              $gallid, $name, $secid, $ra, $dategal);
    return undef if $udbh->err;

    $udbh->do("INSERT INTO galleryrel (userid, gallid, gallid2, type) ".
              "VALUES (?,?,?,'C')", undef, $u->{'userid'}, $parentid, $gallid)
        if defined $parentid;

    return {
        'userid' => $u->{'userid'},
        'gallid' => $gallid,
        'name' => $name,
        'secid' => $secid+0,
        'galsec' => $secid+0,
        'flags' => 0,
        'randauth' => $ra,
        'nextsortorder' => 0,
    };
}

sub empty_gallery  #DEPRECATED
{
    my ($u, $g, $dmode) = @_;
    my $udbh = FB::get_user_db_writer($u);
    my @pics = FB::get_gallery_pictures($u, $g, { no_props => 1 });

    my $unsorted;
    foreach my $p (@pics) {
        $p->{'userid'} = $u->{'userid'};  # needed by gal_add/remove_picture

        if ($dmode eq "unsorted")
        {

            # when we first load unsorted, check to make sure it's not both our source/dest
            unless ($unsorted) {
                $unsorted = FB::load_gallery_incoming($u);
                return error("Couldn't load/create unsorted gallery") unless $unsorted;
                return error("Can't move pictures from to-be-deleted unsorted into unsorted")
                    if $unsorted->{'gallid'} == $g->{'gallid'};
            }

            # remove from here, and make sure it stays somewhere (moving to unsorted if needed)
            return error("Error removing picture")
                unless FB::gal_remove_picture($u, $g, $p, $p->{'picsec'});

            unless (FB::gals_of_upic($u, $p)) {
                FB::gal_add_picture($u, $unsorted, $p);
            }
        }
        elsif ($dmode eq "del")
        {
            # delete from here and everywhere
            FB::upic_delete($u, $p);
        }
        elsif ($dmode eq "softdel")
        {
            # remove from here, and delete if gallery membership is then zero.
            return error("Error removing picture")
                unless FB::gal_remove_picture($u, $g, $p, $p->{'picsec'});
            FB::upic_delete($u, $p) unless FB::gals_of_upic($udbh, $u, $p);
        }
    }
    return 1;
}

sub delete_gallery  #DEPRECATED
{
    my ($u, $g, $dmode) = @_;
    return 0 unless $u->writer;

    if ($dmode) {
        # optionally empty gallery first.
        return 0 unless FB::empty_gallery($u, $g, $dmode);
    } else {
        # otherwise, must be empty already
        my $picid = $u->selectrow_array("SELECT upicid FROM gallerypics WHERE ".
                                        "userid=? AND gallid=? LIMIT 1",
                                        $u->{'userid'}, $g->{'gallid'});
        return 0 if $picid;
    }

    foreach my $t (qw(gallery gallerysize gallerypics)) {
        $u->do("DELETE FROM $t WHERE userid=? AND gallid=?",
               $u->{'userid'}, $g->{'gallid'});
    }

    # both sides of galleryrel
    foreach my $c (qw(gallid gallid2)) {
        $u->do("DELETE FROM galleryrel WHERE userid=? AND $c=?",
               $u->{'userid'}, [$g->{'gallid'}, "int"]);
    }

    # kill identifiers pointing to this
    $u->do("DELETE FROM idents WHERE dtype='G' AND did=? AND userid=?",
           $g->{gallid}, $u->{'userid'});
    $u->do("DELETE FROM aliases WHERE gallid=? AND userid=?",
           $g->{gallid}, $u->{'userid'});

    return 1;
}

sub valid_gallery_name
{
    return $_[0] =~ /\S/ &&
           $_[0] !~ /^\s*\[/
}

sub scaled_url  ## DEPRECATED: use $up->scaled_url
{
    my ($u, $p, $w, $h) = @_;
    my $username = ref $u ? $u->{'user'} : $u;
    $u = ref $u ? $u : undef;

    my $piccode = $p->{'piccode'} || FB::piccode($p);
    my $root = $u ? FB::user_siteroot($u) : "";
    my $url = $FB::ROOT_USER ne $username ? "$root/$username" : $FB::SITEROOT;

    if (FB::fmtid_is_audio( $p->{'fmtid'} )) {
        # cute audio image (todo)
        my $apath;
        ($apath, $w, $h) = FB::audio_thumbnail_info();
        return ("$root/$apath/scale/$w/$h", $h, $h);
    }

    # FIXME:  Temporary until proper video thumbnailing in place.
    if (FB::fmtid_is_video( $p->{'fmtid'} )) {
        $w = $w > 200 ? 200 : $w;
        $h = $h > 200 ? 200 : $h;
        return ("$root/img/dynamic/video_200x200.jpg/scale/$w/$h", $w, $h);
    }

    $url .= "/pic/$piccode";
    my ($nw, $nh) = FB::scale($p, $w, $h);
    if ($nw > $p->{'width'} || $nh > $p->{'height'}) {
        ($nw, $nh) = ($p->{'width'}, $p->{'height'});
        return ($url, $nw, $nh);
    }
    if ($nw != $p->{'width'} || $nh != $p->{'height'}) {
        $url .= "/s${w}x$h";
    }
    return ($url, $nw, $nh);
}

sub url_gallery  #DEPRECATED
{
    my ($u, $gal) = @_;
    return undef unless $u && $gal;
    if (ref $gal) {
        die "No gallid/randauth"
            unless defined $gal->{'gallid'} && defined $gal->{'randauth'};
        $gal = FB::make_code($gal->{'gallid'}, $gal->{'randauth'});
    }
    my $common = "gallery/$gal";
    my $root = FB::user_siteroot($u);
    if ($FB::ROOT_USER eq $u->{'user'}) {
        return "$FB::SITEROOT/$common";
    } else {
        return "$root/$u->{'user'}/$common";
    }
}

sub transform_gal_name  #DEPRECATED
{
    my $name = shift;

    my %mappings = (
            ':FB_in' => "Unsorted",
            ':FB_copies' => "Copies",
        );

    return $mappings{$name} if exists $mappings{$name};
    return "Day: $1-$2-$3" if $name =~ /^day(\d\d\d\d)(\d\d)(\d\d)$/;
    return $name;
}

sub gal_is_unsorted  #DEPRECATED
{
    my $g = shift;
    my $galname = ref $g ? $g->{name} : $g;
    return $galname eq ':FB_in';
}

sub gal_add_picture  #DEPRECATED
{
    my ($u, $g, $p) = @_;

    die "Missing 'u'" unless $u;
    die "Missing 'gallid'" unless $g->{'gallid'};
    die "Missing 'upicid'" unless $p->{'upicid'};
    my $userid = $u->{userid};

    # in most places, a $up object has the 'picsec' key instead of 'secid'
    # to avoid conflicts with 'galsec'/'secid' -- we'll accept both here so
    # that we don't break any callers.
    my $secid = ($p->{picsec} || $p->{secid})+0;

    my $udbh = FB::get_user_db_writer($u)
        or return FB::error("Couldn't connect to user database writer");

    my $rows = $udbh->do("INSERT INTO gallerypics (userid, gallid, upicid, ".
                         "dateins, sortorder) VALUES (?,?,?,UNIX_TIMESTAMP(),?)",
                         undef, $userid, $g->{'gallid'}, $p->{'upicid'},
                         $g->{'nextsortorder'}+0);
    if ($rows) {
        FB::change_gal_size($u, $g, $secid, +1)
            or return undef; # error was set inside function

        $g->{'nextsortorder'}++;
    }

    $udbh->do("UPDATE gallery SET timeupdate=UNIX_TIMESTAMP(), nextsortorder=nextsortorder+1 ".
              "WHERE userid=$u->{'userid'} AND gallid=$g->{'gallid'}");
    return FB::error($udbh) if $udbh->err;

    return 1;
}

sub gal_remove_picture  #DEPRECATED
{
    my ($u, $g, $p, $secid) = @_;

    die "Missing 'u'" unless $u;

    my $upicid = FB::want_upicid($p);
    die "Missing 'upicid'" unless $upicid;

    my $gallid = FB::want_gallid($g);
    die "Missing 'gallid'" unless $gallid;

    # no secid and can't get it from $p, look up in db
    unless (defined $secid) {
        $p = FB::load_upic($u, $upicid)
            unless ref $p;
        $secid = $p->{secid};
    }
    return 0 unless defined $secid;

    my $udbh = FB::get_user_db_writer($u);
    my $rows =
        $udbh->do("DELETE FROM gallerypics WHERE userid=? AND gallid=? ".
                  "AND upicid=?", undef, $u->{'userid'}, $gallid,
                  $upicid);
    if ($rows > 0) {
        FB::change_gal_size($u, $g, $secid, -1);
        return 1;
    }
    return 0;
}

sub gal_remove_picture_multi #DEPRECATED
{
    my ( $u, $g, $upics ) = @_;

    my $gallid = FB::want_gallid($g);

    die "Missing 'u'"           unless $u;
    die "Missing 'gallid'"      unless $gallid;
    die "upics not a reference" unless ref $upics;

    my $udbh = FB::get_user_db_writer($u);
    return 0 unless $udbh;

    my $bind = join ', ', grep { $_+0 } keys %$upics;
    my $sql  = qq{
        DELETE FROM gallerypics
        WHERE
            userid=? AND
            gallid=? AND
            upicid IN ($bind)
    };
    my $rows = $udbh->do( $sql, undef, $u->{'userid'}, $gallid );

    # update counts
    my %counts;
    $counts{ $upics->{$_}->{secid} }++ foreach keys %$upics;
    FB::change_gal_size( $u, $g, $_, -$counts{$_} ) foreach keys %counts;

    return $rows;
}

sub gal_save_nextsort   #DEPRECATED
{
    my ($u, $g) = @_;
    $u->do("UPDATE gallery SET nextsortorder=? WHERE userid=? AND gallid=?",
           [$g->{'nextsortorder'}+0, "int"], $u->{'userid'}, $g->{'gallid'});
}

sub change_gal_size   #DEPRECATED
{
    my ($u, $gal, $secid, $delta) = @_;
    $delta = int($delta);
    return 1 unless $delta;
    die "No 'u'" unless $u;

    # accept a gallery object or a gallid
    my $gallid = FB::want_gallid($gal);
    die "No 'gallid'" unless $gallid;

    my $udbh = FB::get_user_db_writer($u)
        or return FB::error("Couldn't connect to user database writer");

    my $ro = $udbh->do("UPDATE gallerysize SET count=count+? WHERE userid=? AND ".
                       "gallid=? AND secid=?", undef, $delta, $u->{'userid'},
                       $gallid, $secid);
    return FB::error($udbh) if $udbh->err;

    if ($delta > 0 && $ro == 0) {
        $udbh->do("INSERT INTO gallerysize (userid, gallid, secid, count) VALUES ".
                  "(?,?,?,?)", undef, $u->{'userid'}, $gallid, $secid, $delta);
        return FB::error($udbh) if $udbh->err;
    }
    return 1;
}

# change counts in multiple gallery simultanously (same delta)
sub change_gal_size_multi  #DEPRECATED
{
    my ($u, $gals, $secid, $delta) = @_;
    die "No 'u'" unless $u;
    die "Invalid gallery list" unless ref $gals eq 'ARRAY';

    # if the caller only passed 1 gal obj in the array ref,
    # default back to change_gal_size()
    my $gal_num = scalar @$gals;
    return FB::change_gal_size($u, $gals->[0], $secid, $delta)
        if $gal_num == 1;

    $delta = int($delta) || return 0;

    my $udbh = FB::get_user_db_writer($u);

    # accept an array ref of gallery objects,
    # or a simple arrayref of gallery ids.
    my @all_gal_ids = (ref $gals->[0]) ?
                      map { $_->{'gallid'}+0 } @$gals :
                      @$gals;

    my $ids = join ', ', @all_gal_ids;

    my $sql = qq{
        UPDATE gallerysize SET count=count+?
        WHERE userid=? AND secid=? AND gallid IN ($ids)
    };

    my $rv = $udbh->do($sql, undef,
             $delta, $u->{'userid'}, $secid);

    # success on all rows
    return $rv if $rv == $gal_num || $delta <= 0;

    # if we're here, it means some galleries didn't have
    # gallerysize rows to update.  we need to figure out
    # which gallerysize rows weren't around, and add them.
    $sql = qq{
        SELECT gallid FROM gallerysize
        WHERE userid=? AND secid=? AND gallid IN ($ids)
    };

    my (%seen, @needs_new_row);
    my @gal_ids_withrows =
        @{ $u->selectcol_arrayref($sql, $u->{'userid'}, $secid) || [] };
    @seen{@gal_ids_withrows} = ();

    @needs_new_row = map { $_ } grep { not exists $seen{$_} } @all_gal_ids;

    my $bind = join ', ', map { "(?,?,?,?)" } @needs_new_row;
    my @vals = map { $u->{'userid'}, $_, $secid, $delta } @needs_new_row;

    $sql = qq{
        INSERT INTO gallerysize (userid, gallid, secid, count)
        VALUES $bind
    };

    $rv += $udbh->do($sql, undef, @vals);
    return $rv;
}

# forcably wipe and restore a user's gallery counts.
sub reset_gal_size  #DEPRECATED
{
    my $u = shift;
    die "No 'u'" unless $u && ref $u;

    my $udbh = FB::get_user_db_writer($u);

    $udbh->do("DELETE FROM gallerysize WHERE userid=$u->{'userid'}");

    my $q = q{
        INSERT INTO gallerysize
        SELECT u.userid, g.gallid, u.secid, COUNT(u.secid)
        FROM gallerypics g, upic u
        WHERE u.userid=?
            AND u.upicid=g.upicid
            AND g.userid=u.userid
        GROUP BY g.gallid, u.secid
        ORDER BY g.gallid
    };

    my $rv = $udbh->do($q, undef, $u->{'userid'});
    return $rv eq '0E0' ? 0 : $rv;
}

sub get_gal_bytes  #DEPRECATED
{
    my ($u, $g) = @_;
    return undef unless ref $u && ref $g;

    my $sql = qq{
        SELECT SUM(p.bytes)
        FROM upic p, gallerypics g
        WHERE p.userid=? AND g.userid=p.userid AND
        g.gallid=? AND p.upicid=g.upicid
    };

    return $u->selectrow_array($sql,
                               $u->{'userid'}, $g->{'gallid'});
}

sub load_gallery_props #DEPRECATED
{
    my ($u, $gal, @props)= @_;
    return undef unless $u && $gal;

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
        else { return $gal; }
    }
    my $sth = $u->prepare("SELECT propid, value FROM galleryprop ".
                          "WHERE userid=? AND gallid=? " . $where,
                          $u->{'userid'}, $gal->{'gallid'});
    $sth->execute;
    while (my ($id, $value) = $sth->fetchrow_array) {
        my $name = $ps->{$id};
        next unless $name;
        $gal->{$name} = $value;
    }
    return $gal;
}

sub set_gallery_prop  ## DEPRECATED:  use $gal->set_prop
{
    my ($u, $gal, $key, $value) = @_;
    return 0 unless
        $u->{'userid'} && $gal->{'userid'} && $u->{'userid'} == $gal->{'userid'};
    if ($gal->{$key} eq $value) { return 1; }

    my $p = FB::get_props();
    return 0 unless $p->{$key};

    my $udbh = FB::get_user_db_writer($u);
    if ($value) {
        $udbh->do("REPLACE INTO galleryprop (userid, gallid, propid, value) ".
                  "VALUES (?,?,?,?)", undef, $u->{'userid'}, $gal->{'gallid'},
                  $p->{$key}, $value);
        $gal->{$key} = $value;
    } else {
        $udbh->do("DELETE FROM galleryprop WHERE userid=? AND gallid=? AND propid=?",
                  undef, $u->{'userid'}, $gal->{'gallid'}, $p->{$key});
        delete $gal->{$key};
    }
    return 1;
}

# ARGS: $u, ($opts, $secin)
# if no db, must be $u (to get $db)
# if $opts, secin is obtained from $opts->{'secin'}
sub get_gallery_pictures  ## DEPRECATED: use $gal->get_pictures
{
    &nodb;
    my ($u, $g, $opts) = @_;
    return undef unless $u;

    my $userid = want_userid($u);
    my $gallid = ref $g ? $g->{'gallid'} : $g;

    my $secin = ($opts && ! ref $opts) ? $opts : "";
    $opts = {} unless ref $opts eq "HASH";
    $secin ||= $opts->{'secin'};

    return undef unless $u->writer;

    my $sth;

    # optional unsorted cleaning.  remove pics from unsorted
    # that also appear elsewhere.
    if ($opts->{'clean_unsorted'}) {
        my $sql = q{
            SELECT
                ga.upicid, COUNT(*) AS 'ct'
            FROM
                gallerypics ga, gallerypics gb
            WHERE
                ga.userid=? AND
                gb.userid=ga.userid AND
                ga.gallid=? AND
                gb.upicid=ga.upicid
            GROUP BY 1 HAVING ct > 1
        };

        my @dups = @{ $u->selectcol_arrayref( $sql, $userid, $gallid ); };

        if (@dups) {
            my $upics = FB::load_upic_multi($u, \@dups);
            FB::gal_remove_picture_multi($u, $g, $upics);
        }
    }

    my $q = "SELECT u.upicid, u.width, u.height, u.fmtid, u.randauth, u.bytes, " .
        "u.secid AS 'picsec', gp.sortorder, u.gpicid " .
        "FROM upic u, gallerypics gp " .
        "WHERE u.userid=? AND gp.userid=u.userid AND gp.gallid=? " .
        "AND gp.upicid=u.upicid";
    $q .= " AND u.secid IN ($secin)" if $secin;
    $q .= " ORDER BY gp.sortorder, u.upicid LIMIT " . ($opts->{limit}+0) if $opts->{limit};

    my %pics = %{ $u->selectall_hashref($q, 'upicid', $userid, $gallid) || {} };

    if ( $opts->{'no_video'} ) {
        map { delete $pics{$_} if FB::fmtid_is_video( $pics{$_}->{'fmtid'} ) } keys %pics;
    }

    unless ($opts->{'no_props'}) {
        # now, load relevant upicprop stuff
        my $ps = FB::get_props();
        my $propid_in = join(',', map { $ps->{$_} } qw(cropfocus pictitle));
        my $upicid_in = join(',', map { $_+0 } keys %pics);
        $sth = $u->prepare("SELECT p.upicid, p.propid, p.value ".
                           "FROM gallerypics gp, upicprop p ".
                           "WHERE gp.userid=? AND p.userid=gp.userid ".
                           "AND gp.gallid=? AND p.upicid=gp.upicid ".
                           "AND gp.upicid IN ($upicid_in) " .
                           "AND p.propid IN ($propid_in)",
                           $userid, $gallid);
        $sth->execute;
        while (my ($upicid, $propid, $value) = $sth->fetchrow_array) {
            $pics{$upicid}->{$ps->{$propid}} = $value;
        }
    }

    return sort { $a->{'sortorder'} <=> $b->{'sortorder'} || $a->{'upicid'} <=> $b->{'upicid'} } values %pics;
}

1;
