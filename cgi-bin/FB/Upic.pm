package FB::Upic;

use strict;
use vars qw/ $AUTOLOAD /;
use Carp qw/ croak /;

use FB::ThumbFormat;

# hashref innards:
#    u       -- FB::User, always
#    upicid  -- always
#
#    _loaded_des  -- when set:
#       des       -- raw utf8 text of upic description
#
#    _loaded_props  -- when set:
#       props     -- hashref of propname to value
#
#    _loaded_upic  -- row has been loaded.  when set, then also:
#
#       secid
#       width
#       height
#       fmtid
#       bytes
#       gpicid
#       datecreate
#       randauth
#

my %singletons;  # "userid-upicid" -> FB::Upic object

sub reset_singletons {
    my $class = shift;
    die "this is a class method" if ref $class;
    %singletons = ();
}

# creates skeleton/unverified/lazily-loaded object.
# FB::Upic->new( {$u | $userid} , $upicid )
sub new
{
    my $class = shift;
    my $self  = bless {};

    my $uuserid = shift;
    my $upicid  = int(shift)
        or croak "Invalid upicid";

    die "bogus extra args" if @_;

    my $userid = int(ref $uuserid ? $uuserid->{userid} : $uuserid);
    my $single_key = "$userid-$upicid";
    return $singletons{$single_key} if $singletons{$single_key};

    if (ref $uuserid) {
        $self->{u} = $uuserid;
    } else {
        $self->{u} = FB::load_userid($uuserid)
            or die("couldn't load user from userid when creating upic");
    }

    $self->{upicid}       = $upicid;
    $self->{_loaded_upic} = 0;
    return $singletons{$single_key} = $self;
}

# turn the item back to a skeleton
sub reset_to_skeleton {
    my $self = shift;
    $self->{_loaded_upic} = 0;
}

sub create {
    my ($class, $u, $gpicid, %opts) = @_;
    my $err = sub { return FB::error("Upic->create: $_[0]"); };
    return $err->("no/bad u object") unless ref $u eq "FB::User";
    return $err->("no gpicid") unless $gpicid;
    return $err->("Couldn't connect to user db writer") unless $u->writer;

    my $secid     = delete $opts{secid};
    my $existflag = delete $opts{exist_flag};
    die "bogus options: " . join(", ", keys %opts) if %opts;

    $secid = 255 unless defined $secid;
    $secid = int($secid);

    # see if this user already has this gpic
    my $p = $u->selectrow_hashref("SELECT * FROM upic WHERE gpicid=? AND userid=?",
                                  $gpicid, $u->{'userid'});
    return $err->($u->errstr) if $u->err;
    if ($p) {
        my $up = FB::Upic->from_upic_row($u, $p);
        $up->set_secid($secid);
        $$existflag = 1 if $existflag;
        return $up;
    }

    # if not, we need to make one for them.

    # first of all, grab the gpic data, since
    # the upic row will have most the same data.
    my $dbr = FB::get_db_reader()
        or return $err->("Couldn't connect to db reader");

    my $n_gpicid = $gpicid + 0;
    my $g = $dbr->selectrow_hashref("SELECT * FROM gpic WHERE gpicid=$n_gpicid");
    return $err->("No gpic row: $gpicid") unless $g;

    # allocate a new upicid
    my $upicid = FB::alloc_uniq($u, "upic_ctr")
        or return $err->("couldn't allocate uniq id");

    my $randauth = FB::rand_auth();

    # insert the real row
    $u->do("INSERT INTO upic (userid, upicid, secid, width, ".
           "height, fmtid, bytes, gpicid, datecreate, randauth) VALUES ".
           "(?,?,?,?,?,?,?,?,UNIX_TIMESTAMP(),?)", $u->{'userid'},
           $upicid, $secid, $g->{'width'}, $g->{'height'}, $g->{'fmtid'},
           $g->{'bytes'}, $gpicid, $randauth);
    return $err->("Couldn't insert upic row") if $u->err;

    # call the hook to record disk space usage
    if (FB::are_hooks("use_disk")) {
        FB::run_hook("use_disk", $u, $g->{'bytes'})
            or die ("Hook 'use_disk' returned false");
    }

    my $up = FB::Upic->new($u, $upicid)
        or return $err->("load_upic returned false");

    return $up;
}


# class method;
#   my $up = FB::Upic->from_upic_row($u, $row)
# where $row is a hashref from the "upic" table
sub from_upic_row {
    my $class = shift;
    my $u     = shift;
    die "should be a u" unless ref $u && $u->isa("FB::User");
    my $row   = shift;
    die "row has no upicid" unless $row->{upicid};
    die "row's userid doesn't match the provided \$u" unless $row->{userid} == $u->{userid};

    my @all_fields = qw(secid width height fmtid bytes gpicid datecreate randauth);

    my $g = FB::Upic->new($u, $row->{upicid});
    for my $f (@all_fields) {
        $g->{$f} = $row->{$f};
    }
    $g->{_loaded_upic} = 1;
    return $g;
}

sub datecreate_unix {
    my $up = shift;
    return 0 unless $up->valid;
    return $up->{datecreate};
}

sub visible {
    my $up = shift;
    return $up->visible_to(FB::User->remote);
}

sub visible_to {
    my ($up, $remote) = @_;
    # FIXME: make this more efficient
    return FB::can_view_secid($up->{u}, $remote, $up->secid);
}

sub upics_needing_field {
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


sub prop {
    my ($self, $prop) = @_;
    unless ($self->{_loaded_props}) {
        __PACKAGE__->load_props($self->{u}, [ __PACKAGE__->upics_needing_field($self->{u}, "_loaded_props") ]) or die;
    }
    return $self->{prop}{$prop};
}

sub set_text_prop {
    my ($up, $prop, $value) = @_;
    return 0 unless FB::is_utf8($value);
    return $up->set_prop($prop, $value);
}

sub set_prop {
    my ($up, $prop, $value) = @_;
    my $u = $up->{u};

    # bail out early, if we know the value's already the same
    return 1 if $up->{_loaded_props} && $up->{prop}{$prop} eq $value;

    my $ps  = FB::get_props() or return 0;
    my $pid = $ps->{$prop}    or return 0;

    if ($value) {
        $u->do("REPLACE INTO upicprop (userid, upicid, propid, value) ".
               "VALUES (?,?,?,?)", $u->{'userid'}, $up->id,
               $pid, $value) or return 0;
        $up->{prop}{$prop} = $value if $up->{_loaded_props};
    } else {
        $u->do("DELETE FROM upicprop WHERE userid=? AND upicid=? AND propid=?",
               $u->{'userid'}, $up->id, $pid) or return 0;
        delete $up->{prop}{$prop} if $up->{_loaded_props};
    }
    return 1;
}


# helper function
sub _upicid_where {
    my ($col, $list, $all_thres) = @_;
    # if list is greater than $all_thres threshold, don't return a
    # WHERE query and let's just load everything.
    return "" if defined $all_thres && @$list > $all_thres;
    # impossible where, to prevent queries, if caller didn't check
    # their list being empty.
    return "AND 1=0" unless @$list;
    return "AND $col=" . int($list->[0]{upicid}) if @$list == 1;
    return "AND $col IN (" . join(",", map { int($_->{upicid}) } @$list) . ")";
}


# class method:  load props on given upics
#
#   FB::Upic->load_props($u, [ FB::Upic* ])
sub load_props {
    my $class = shift;
    die "this is a class method" if ref $class;

    my $u       = shift;
    die "not a u" unless ref $u && $u->isa("FB::User");

    my $listref = shift;
    die "too many arguments" if @_;

    my @needload = grep { ! $_->{_loaded_props} } @$listref;
    return 1 unless @needload;

    my $where = _upicid_where("upicid", \@needload);

    # prop names
    my $ps = FB::get_props();

    my $prop = {};  # upicid -> propname -> value
    my $sth = $u->prepare("SELECT upicid, propid, value FROM upicprop " .
                          "WHERE userid=? $where",
                          $u->{'userid'});
    $sth->execute;
    while (my ($upicid, $id, $value) = $sth->fetchrow_array) {
        my $name = $ps->{$id};
        unless ($name) {
            warn("loaded unknown prop: id=$id");
            next;
        }
        $prop->{$upicid} ||= {};
        $prop->{$upicid}{$name} = $value;
    }

    foreach my $up (@needload) {
        $up->{prop}          = $prop->{$up->id} || {};
        $up->{_loaded_props} = 1;
    }

    return 1;
}

# class method:
#   FB::Upic->load_upics($u, [ FB::Upic* ]) # fills in _loaded_upic on given upics
#   FB::Upic->load_upics($u);  # loads all upics for user, returning hashref of 'em all, keyed by upicid
sub load_upics {
    my $class = shift;
    die "this is a class method" if ref $class;
    my $u       = shift;
    my $listref = shift;
    die "too many arguments" if @_;

    my $where = "";
    my @needload;
    if ($listref) {
        @needload = grep { ! $_->{_loaded_upic} } @$listref;
        return 1 unless @needload;
        if (@needload > 1) {
            $where = "AND upicid IN (" . join(",", map { int($_->{upicid}) } @needload) . ")";
        } else {
            $where = "AND upicid=" . int($needload[0]{upicid});
        }
    }

    my $loaded = $u->selectall_hashref("SELECT userid, upicid, secid, width, height, fmtid, bytes, gpicid, datecreate, randauth ".
                                       "FROM upic WHERE userid=? $where",
                                       "upicid",
                                       $u->{'userid'})
        or return FB::error($u);

    # if no listref, we're returning hashref (keyed by upicid) of all a
    # user's upics
    if (!$listref) {
        my $ret = {};
        foreach my $upicid (keys %$loaded) {
            my $rec = $loaded->{$upicid};  # the unblessed hashref form database
            $ret->{$upicid} = FB::Upic->from_upic_row($u, $rec)
                or die "failed to create record from upic rec $upicid\n";
        }
        return $ret;
    }

    # otherwise we're just filling in $g objects for them
    my $missing = 0;
    foreach my $up (@needload) {
        my $rec = $loaded->{$up->{upicid}};
        unless ($rec) {
            $missing = 1;
            next;
        }

        # don't need to modify $up, because $up is a singleton, and from_upic_row
        # will get the same record that we have, and fill it in
        FB::Upic->from_upic_row($u, $rec);
     }

    return $missing ? 0 : 1;
}

sub is_video {
    $_[0]->valid or die;
    return FB::fmtid_is_video($_[0]->{fmtid});
}

sub is_audio {
    $_[0]->valid or die;
    return FB::fmtid_is_audio($_[0]->{fmtid});
}

sub is_still {
    $_[0]->valid or die;
    return FB::fmtid_is_still($_[0]->{fmtid});
}

sub _load {
    return 1 if $_[0]->{_loaded_upic};
    my $self = shift;
    return __PACKAGE__->load_upics($self->{u}, [ $self ]);
}

sub id {
    return $_[0]->{upicid};
}

sub valid {
    return $_[0]->_load;
}

sub piccode {
    my $up = shift;
    $up->valid or die;
    return FB::make_code($up->{'upicid'}, $up->{'randauth'});
}

sub randauth {
    my $up = shift;
    $up->valid or die "not valid";
    return $up->{randauth};
}

sub gpicid {
    my $up = shift;
    $up->valid or die "not valid";
    return $up->{gpicid};
}

sub gpic {
    my $up = shift;
    return FB::Gpic->load($up->gpicid);
}

sub add_event_listener {
    my ($up, $event, $subref) = @_;
    $up->{_event_listener}{$event}{"$subref"} = $subref;
    return 1;
}

sub remove_event_listener {
    my ($up, $event, $subref) = @_;
    return delete $up->{_event_listener}{$event}{"$subref"} ? 1 : 0;
}

sub fire_event {
    my ($up, $event, @args) = @_;
    return 1 unless
        $up->{_event_listener} &&
        $up->{_event_listener}{$event};

    foreach my $handlers (values %{ $up->{_event_listener}{$event} }) {
        $handlers->(@args);
    }
}

sub set_gpic {
    my ($up, $gp) = @_;
    my $u = $up->{u};
    $up->valid or die;
    $u->writer or return 0;

    my $gpicid = $gp->{'gpicid'};
    my $exist_upicid = $u->selectrow_array("SELECT upicid FROM upic WHERE userid=? AND gpicid=?",
                                           $u->{userid}, $gpicid);
    if ($exist_upicid) {
        $up->fire_event("set_gpic_failed_dup", $exist_upicid);
        return 0;
    }

    my $old_gpicid = $up->gpicid;

    $up->delete_thumbnails($u, $up);
    $up->set_prop("modtime", time());

    $u->do("UPDATE upic SET gpicid=?, width=?, height=?, bytes=? ".
           "WHERE userid=? AND upicid=?",
           $gp->{'gpicid'}, $gp->{'width'}, $gp->{'height'},
           $gp->{'bytes'}, $u->{'userid'}, $up->id);
    return 0 if $u->err;

    $u->do("DELETE FROM upic_exif WHERE userid=? AND upicid=?",
           $u->{userid}, $up->id);

    delete $FB::REQ_CACHE{"upic:$u->{'userid'}:$up->{'upicid'}"};

    FB::gpicid_delete($up->{'gpicid'});
    FB::run_hook("free_disk", $u, $up->bytes);
    FB::run_hook("use_disk",  $u, $gp->{'bytes'});

    foreach (qw(width height bytes gpicid)) {
        $up->{$_} = $gp->{$_};
    }

    return 1;
}

sub delete_thumbnails {
    my $up = shift;
    my $u = $up->{u};

    my $sth = $u->prepare(qq{
        SELECT gpicid FROM upic_thumb WHERE userid=? and upicid=?
        }, $u->{'userid'}, $up->id);
    $sth->execute;
    my @ids;
    push @ids, $_ while ($_) = $sth->fetchrow_array;
    return 1 unless @ids;

    $u->do("DELETE FROM upic_thumb WHERE userid=? AND upicid=? ",
           $u->{'userid'}, $up->id);

    FB::gpicid_delete(@ids);
    return 1;
}


sub width {
    my $up = shift;
    $up->valid or die "not valid";
    return $up->{width};
}

sub bytes {
    my $up = shift;
    $up->valid or die "not valid";
    return $up->{bytes};
}

sub secid {
    my $up = shift;
    $up->valid or die "not valid";
    return $up->{secid};
}

sub set_secid {
    my ($up, $secid) = @_;
    return 1 if $secid == $up->secid;
    my $u = $up->{u};
    my $ok = $u->do("UPDATE upic SET secid=? WHERE userid=? AND upicid=?",
                    $secid, $u->{userid}, $up->id);
    $up->{secid} = int($secid) if $ok;
    return $ok;  # or die?
}

sub height {
    my $up = shift;
    $up->valid or die "not valid";
    return $up->{height};
}

sub fmtid {
    my $up = shift;
    $up->valid or die "not valid";
    return $up->{fmtid};
}

# $url                                  = $up->scaled_url($req_width, $req_height)
# ($url, $actual_width, $actual_height) = $up->scaled_url($req_width, $req_height);
sub scaled_url {
    my ($up, $w, $h) = @_;
    $up->valid or die;

    my $u = $up->{u};
    my $piccode = $up->piccode;
    my $url = $u->url_root . "pic/$piccode";

    if (FB::fmtid_is_audio( $up->{'fmtid'} )) {
        # cute audio image (todo)
        my ($apath) = FB::audio_thumbnail_info();
        return (FB::user_siteroot($u) . "/$apath/scale/$w/$h", $w, $h);
    }

    if ($up->is_video && ! $FB::USE_MPLAYER) {
        $w = $w > 200 ? 200 : int($w);
        $h = $h > 200 ? 200 : int($h);
        $url = FB::user_siteroot($u) . "/img/dynamic/video_200x200.jpg/scale/$w/$h";
        return wantarray ? ($url, $w, $h) : $url;
    }

    my ($nw, $nh) = FB::scale($up->{'width'}, $up->{'height'}, $w, $h);

    if ($nw > $up->{'width'} || $nh > $up->{'height'}) {
        ($nw, $nh) = ($up->{'width'}, $up->{'height'});
        return ($url, $nw, $nh);
    }
    if ($nw != $up->{'width'} || $nh != $up->{'height'}) {
        $url .= "/s${w}x$h";
    }
    return wantarray ? ($url, $nw, $nh) : $url;
}

sub manage_url {
    my $up = shift;
    return "$LJ::SITEROOT/manage/media/pic.bml?id=$up->{upicid}";
}

# returns full-sized image URL, without extension.  good form to
# append onto to make any of the other forms.
sub url_base {
    my $up = shift;
    return $up->{u}->media_base_url . "/pic/" . $up->piccode;
}

# URL to full-sized image
sub url_full {
    my $up = shift;
    return $up->url_base;  # FIXME: append .extension
}

sub url_picture_page {
    my ($up, $gal) = @_;
    return $up->url_base . "/" . ($gal ? "g" . $gal->id : "");
}

# FIXME: is this interface dumb?  kinda.
sub thumbnail_fmtstring {
    my ($up, $tsty) = @_;

    my $fmt = $tsty->[2];
    my ($nw, $nh);  # new width/height
    my ($ow, $oh) = ($up->width, $up->height);
    if ($fmt =~ /[hz]/) {
        ($nw, $nh) = ($tsty->[0], $tsty->[1]);
    } elsif ($fmt =~ /c/ && $up->prop("cropfocus")) {
        my @cf = split(/,/, $up->prop("cropfocus"));
        ($ow, $oh) = ($up->width * ($cf[2]-$cf[0]),
                      $up->height * ($cf[3]-$cf[1]));
    }
    unless ($nw || $nh) {
        ($nw, $nh) = FB::scale($ow, $oh, $tsty->[0], $tsty->[1]);
    }

    $fmt = sprintf("%2x%2x%s", $nw, $nh, $fmt);
    return wantarray() ? ($fmt, $nw, $nh) : $fmt;
}


# FIXME: is this interface dumb?  kinda.
sub url_thumbnail {
    my ($up, $tsty) = @_;  # $tsy = [ width, height, format ]
    my ($fmt, $nw, $nh) = $up->thumbnail_fmtstring($tsty);

    if ($up->is_audio) {
        # cute audio image (todo)
        my $apath;
        ($apath, $nw, $nh) = FB::audio_thumbnail_info();
        return (FB::user_siteroot($up->{u}) . "/$apath/scale/$nw/$nh", $nw, $nh);
    }

    if ($up->is_video && ! $FB::USE_MPLAYER) {
        my $url = FB::user_siteroot($up->{u}) . "/img/dynamic/video_160x120.jpg/scale/$nw/$nh";
        return wantarray ? ($url, $nw, $nh) : $url;
    }

    my $url = $up->url_base . "/t$fmt";

    # force a thumbnail to be generated, because it looks like we're gonna be needing one
    $up->generate_thumbnail_gpic_background($fmt) if @FB::GEARMAN_SERVERS;

    return wantarray() ? ($url, $nw, $nh) : $url;
}

# same as below, but generates in background, doesn't block, and doesn't return anything
sub generate_thumbnail_gpic_background {
    my ($up, $fmtstring) = @_;
    return undef unless $up && $up->valid;

    my $u = $up->{u};

    # see if this gpicid already exists
    if (my $exist_gpic = $up->thumbnail_gpic_existing($fmtstring)) {
        return $exist_gpic;
    }

    # generate thumbnail in background
    FB::Job->do
        ( job_name => 'thumbnail_image',
          arg_ref  => [ $u->{userid}, $up->{upicid}, $fmtstring ],
          task_ref => \&FB::Upic::_thumbnail_gpic_do,
          background => 1,
          );
}

# returns an FB::Gpic thumbnail of the $up, given a thumbnail fmtstring spec,
# either a previously generated one, or a new one.  returns undef on any error.
sub thumbnail_gpic {
    my ($up, $fmtstring) = @_;
    return undef unless $up && $up->valid;

    my $u = $up->{u};

    # see if this gpicid already exists
    if (my $exist_gpic = $up->thumbnail_gpic_existing($fmtstring)) {
        return $exist_gpic;
    }

    # register a new job to create this thumbnail
    my $gpicid_ref = FB::Job->do
        ( job_name => 'thumbnail_image',
          arg_ref  => [ $u->{userid}, $up->{upicid}, $fmtstring ],
          task_ref => \&FB::Upic::_thumbnail_gpic_do,
          );

    return ref $gpicid_ref ? FB::Gpic->load($$gpicid_ref) : undef;
}

# loads an existing gpic from the database, verifying its paths
# -- for creating new thumbnail gpics, use $up->thumbnail_gpic
sub thumbnail_gpic_existing {
    my ($up, $fmtstring) = @_;
    return undef unless $up && $up->valid;

    my $fmt = FB::ThumbFormat->new($fmtstring);
    return undef unless $fmt;

    my $u = $up->{u};

    my ($gpicid, $timeused) = $u->selectrow_array(qq{
        SELECT gpicid, UNIX_TIMESTAMP(timeused) FROM upic_thumb
        WHERE userid=? AND upicid=? AND fmtstring=?
    }, $u->{userid}, $up->id, $fmt->string);

    # okay, this thumbnail supposedly exists, so let's see.
    # if it's good, we can avoid checking to see if this fmtstring
    # is valid for some gallery style the picture's in.
    my $g = $gpicid ? FB::Gpic->load($gpicid) : undef;

    unless ($g && $g->verified_paths) {

        # $g had no paths, so let's delete it so a new one can be made
        $u->do("DELETE FROM upic_thumb WHERE userid=? AND upicid=? AND fmtstring=?",
               $u->{userid}, $up->id, $fmt->string);
        FB::gpicid_delete($gpicid);

        # no hope for getting a $g now
        return undef;
    }

    # it exists.  but first, let's touch this thumbnail
    # if it hasn't be touched in over 15 days.
    my $needs_touch = time() - 60*60*24*15;
    if ($timeused < $needs_touch) {
        $u->do(qq{
            UPDATE upic_thumb SET timeused=UNIX_TIMESTAMP()
            WHERE userid=? AND upicid=? AND fmtstring=?
        }, $u->{'userid'}, $up->id, $fmt->string);
    }

    return $g;
}

# The guts of FB::Gpic->thumbnail_gpic, abstracted here so it can be passed
# as a handler to the FB::Job mechanism
#  - accepts arrayref [ userid, upicid, fmtstring ]
#  - returns \$gpicid
sub _thumbnail_gpic_do {
    my $argref = shift;
    croak "invalid argument reference passed"
        unless ref $argref eq 'ARRAY';

    my ($userid, $upicid, $fmtstring) = @$argref;

    my $u = FB::User->load_userid($userid);
    return undef unless $u;

    my $up = FB::Upic->new($u, $upicid);
    return undef unless $up && $up->valid;

    # see if this thumbnail already exists, returning if it does
    if (my $exist_gpic = $up->thumbnail_gpic_existing($fmtstring)) {
        return \$exist_gpic->{gpicid};
    }

    # see if this fmtstring is valid for some gallery the upic is in.
    #
    # NOTE: removed. galthumbfmt wasn't flexible enough, and tied us to
    #       funky thumbnails on gallery pages only.  a better approach
    #       might be to rate limit uncached thumbnail generation requests.
    #       or, just allow them and let the 30 day purger clean them.

    my $fmt = FB::ThumbFormat->new($fmtstring);
    return undef unless $fmt->valid;

    my ($w, $h) = ($fmt->width, $fmt->height);

    my @cf = (0,0,1,1,0.5,0.5); # crop focus
    my $do_crop = 0;
    if ($fmt->cropped || $fmt->stretched || $fmt->zoomed) {
        # cropped, stretched or zoomed?  need cropping data.
        if (my $cropfocus = $up->prop('cropfocus')) {
            @cf = split(/,/, $cropfocus);
            $do_crop = 1;
        }
    }

    # zoomed cropping.  return subset of cropping region, sized exactly $w x $h
    # and retaining aspect ratio, centered as much as possible on focus point
    if ($fmt->zoomed) {
        my $des_ratio = $w / $h;  # requested thumbnail of $w by $h
        my ($crop_w, $crop_h) = (($cf[2]-$cf[0]) * $up->width,
                                 ($cf[3]-$cf[1]) * $up->height);
        my $crop_ratio = $crop_w / $crop_h;

        # adjust crop_ratio to match des_ratio, by making crop region
        # smaller in either width or height
        if ($crop_ratio > $des_ratio) {
            $crop_w *= ($crop_h * $w) / ($h * $crop_w);
        } elsif ($des_ratio > $crop_ratio) {
            $crop_h /= ($crop_h * $w) / ($h * $crop_w);
        }

        # convert crop_w/crop_h from pixels to percentages
        ($crop_w, $crop_h) = ($crop_w / $up->width,
                              $crop_h / $up->height);

        # center region on focus point
        my ($mid_x, $mid_y) = ($cf[4], $cf[5]);
        my ($tlx, $brx) = ($mid_x-$crop_w/2, $mid_x+$crop_w/2);
        my ($tly, $bry) = ($mid_y-$crop_h/2, $mid_y+$crop_h/2);

        # but, if we're out of boundaries, shift it back in
        my ($slidex, $slidey);
        $slidex = $cf[0] - $tlx if $tlx < $cf[0];
        $slidex = $cf[2] - $brx if $brx > $cf[2];
        $slidey = $cf[1] - $tly if $tly < $cf[1];
        $slidey = $cf[3] - $bry if $bry > $cf[3];

        # change our cropping area
        ($cf[0], $cf[2]) = ($tlx+$slidex, $brx+$slidex);
        ($cf[1], $cf[3]) = ($tly+$slidey, $bry+$slidey);

        $do_crop = 1;
    }

    my $pixelpercent = (($cf[2]-$cf[0]) *
                        ($cf[3]-$cf[1]));

    my $go = FB::Gpic->load_for_scaling($up->gpicid, $w, $h, $pixelpercent);
    my $contentref = $go && $go->paths ? $go->data : undef;

    # use original if the gpic selected for scaling doesn't exist
    unless ($contentref) {
        $go = FB::Gpic->load($up->gpicid);
        $contentref = $go->data if $go && $go->paths;
    }
    return undef unless $go && $contentref;

    my $gt = FB::Gpic->new
        ( alt => 1, fmtid => $go->{fmtid} )
        or return undef;

    my $image = FB::Magick->new($contentref)
        or die FB::last_error();
    $image->Set('quality' => 90)
        or die FB::last_error();  # default is 75

    # strip exif data from thumbnails so they aren't overly bloated
    $image->Profile(name => '*', profile => '')
        or die FB::last_error();

    # cropping or stretching: crop the image
    if ($do_crop) {
        my %crop = (
                    x => int($go->{'width'} * $cf[0]),
                    y => int($go->{'height'} * $cf[1]),
                    width => int($go->{'width'} * ($cf[2] - $cf[0])),
                    height => int($go->{'height'} * ($cf[3] - $cf[1])),
                    );
        $image->Crop(%crop) or die FB::last_error();
    }

    my ($nw, $nh);

    if ($fmt->stretched || $fmt->zoomed) {
        ($nw, $nh) = ($w, $h);
    } else {
        ($nw, $nh) = FB::scale($image->Get('width', 'height'), $w, $h);
    }

    if ($image->Get('format') =~ /graphics interchange/i) {
        unless ($FB::ANIMATED_GIF_THUMBS) {
            $image->deanimate # 1st frame
                or die FB::last_error();
        }
        $image->Sample('width' => $nw, 'height' => $nh)
            or die FB::last_error();
    } else {
        $image->Resize('width' => $nw, 'height' => $nh)
            or die FB::last_error();
    }
    if ($fmt->gray) {
        $image->Quantize(colorspace=>'gray')
            or die FB::last_error();
    }

    $gt->append($image);
    undef $image;

    eval { $gt->save };
    return undef if $@;

    # save it so it's cached for next time.
    $u->do("INSERT INTO upic_thumb (userid, upicid, fmtstring, gpicid, ".
           "timeused) VALUES (?,?,?,?,UNIX_TIMESTAMP())", $u->{'userid'},
           $up->id, $fmtstring, $gt->{'gpicid'});
    return undef if $u->err;

    return \$gt->{gpicid};
}

sub set_title {
    my ($self, $title) = @_;
    $self->set_text_prop('pictitle', $title);
}

sub title {
    my $self = shift;
    return $self->prop('pictitle');
}

sub set_des {
    my ($self, $des) = @_;
    my $old = $self->des;
    return 1 if $old eq $des;
    return 0 unless FB::is_utf8($des);

    my $u = $self->{u};

    if ($des) {
        $u->do("REPLACE INTO des (userid, itemtype, itemid, des) VALUES ".
               "(?,?,?,?)", $u->{'userid'}, "P", $self->{upicid}, $des);
        $self->{'des'} = $des;
    } else {
        $u->do("DELETE FROM des WHERE userid=? AND itemtype=? AND itemid=?",
               $u->{'userid'}, "P", $self->{upicid});
        delete $self->{'des'};
    }
    $self->{_loaded_des} = 1;
    return 1;
}

sub des {
    my $self = shift;
    return $self->{des} if $self->{_loaded_des};
    my $u = $self->{u};

    my $des = $u->selectrow_array("SELECT des FROM des WHERE userid=? AND ".
                                  "itemtype=? AND itemid=?",
                                  $u->{userid}, "P", $self->{upicid});

    $self->{_loaded_des} = 1;
    return $self->{des} = $des;
}

sub des_html {
    my $self = shift;
    my $des = $self->des;
    $des = FB::ehtml($des);
    $des =~ s!\n!<br />!g;
    return $des;
}


# in list context, return FB::Galleries this object is in
# FIXME: in scalar context, returns true or false:  if upic is in any galleries?
sub galleries {
    my $up = shift;
    return FB::Gallery->load_upic_galleries($up);
}

sub visible_galleries {
    my $up = shift;
    return grep { $_->visible } $up->galleries;
}

# set tags on a picture, removing picture from tags not declared
sub set_tags {
    my $up = shift;
    my $commalist = shift;
    return $up->add_tags($commalist, "set");
}

# adds new tags to a picture, not touching old ones
sub add_tags {
    my $up = shift;
    my $commalist = shift;
    # defaults to adding.  if $op eq "set", then pic is removed from not specified tags
    my $op = shift;

    my %exist = map { $_, 1 } $up->tags;

    my $ok = 1;
    foreach my $sn (split(/\s*,\s*/, $commalist)) {
        if ($exist{$sn}) {
            delete $exist{$sn};
            next;
        }
        my $g = $up->{u}->gallery_of_tag($sn);
        next unless $g;
        $ok = 0 unless $g->add_picture($up);
    }

    if ($op eq "set"){
        foreach my $sn (keys %exist) {
            my $g = $up->{u}->gallery_of_tag($sn);
            next unless $g;
            $ok = 0 unless $g->remove_picture($up);
        }
    }

    # FIXME: figure out error handling here for the multiple ways this could fail (db, bogus tag name)
    return $ok;
}

sub tags {
    my $up = shift;
    return sort grep { $_ } map { $_->tag } $up->galleries;
}

# returns undef, or scalarref to exif data
sub exif_header {
    my ($up, $src) = @_;  # src is optional
    my $u = $up->{u};

    # only jpegs have exif info
    unless ($up->fmtid == FB::fmtid_from_ext('jpg')) {
        my $hdr = "";
        return \$hdr;
    }

    # first query database to see if the header is already stored there
    return FB::error("Couldn't connect to user db") unless $u->writer;

    my $ary = $u->selectcol_arrayref
        ("SELECT data FROM upic_exif WHERE userid=? AND upicid=?",
         $u->{userid}, $up->id) || [];
    return FB::error($u) if $u->err;

    # if we got rows from the database, we return either the value
    # or "" if null.  either way, we've extracted from this file before
    my $hdr = "";
    if (@$ary) {
        $hdr = $ary->[0] . ""; # stringify if null
        return \$hdr;
    }

    # subref to save header to database once it's found (or there's an unrecoverable error)
    my $save = sub {
        # save header we just read into database for quick access later
        return FB::error("Couldn't connect to user db writer") unless $u->writer;

        $hdr = undef unless $hdr; # "" => undef => NULL
        my $rv = $u->do("REPLACE INTO upic_exif SET userid=?, upicid=?, data=?",
                        $u->{userid}, $up->id, $hdr);
        return FB::error($u) if $u->err;
        return $rv;
    };

    # need to extract header and save to db
    # -- caller can pass in a scalar ref or filehandle as $src,
    #    otherwise we'll get the data from the upic's gpic
    unless ($src) {
        my $gpic = FB::Gpic->load($up->gpicid)
            or return FB::error("Couldn't load gpic: $up->{gpicid}");

        $src = $gpic->data;
    }

    # sub to read chunks of data
    # - this sub sets FB::error before returning undef on failure, so callers
    #   should just return undef when undef is returned so they don't overwrite
    #   the last_error stored by $read
    my $offset = 0;
    my $read = sub {
        my $len = shift;
        my ($rbuf, $n);

        if (ref $src eq 'SCALAR') {
            $rbuf = substr($$src, $offset, $len);
            $n = length($rbuf);
        } elsif ($src) {
            $n = read($src, $rbuf, $len);
        }
        return FB::error("Error reading EXIF header: read failed: $!")
            unless defined $n;
        return FB::error("Error reading EXIF header: short read ($len/$n)")
            unless $n == $len;

        $offset += $len;
        return $rbuf;
    };

    # read jpeg magic to make sure this file is valid
    $hdr = $read->(2) or return undef;
    unless ($hdr eq "\xFF\xD8") {

        # save a NULL in the database because this is an invalid EXIF
        # header and we'll never be able to successfully read it, so
        # no point in trying later
        $save->();

        return FB::error("Error reading EXIF header: SOI missing");
    }

    # read until end of header
    while (1) {
        my $chunk = $read->(4) or return undef;
        my ($ff, $mark, $len) = unpack("CCn", $chunk);
        last if $ff != 0xFF;
        last if $mark == 0xDA || $mark == 0xD9;  # SOS/EOI
        last if $len < 2;

        $hdr .= $chunk . $read->($len - 2) or return undef;

        # the database field for this header is a mediumblob,
        # which can store 2^24-1 bytes.  if we've read past
        # that point, we'll ignore the exif data for this image
        # and just store a null.
        #
        # Note: this is superfluous and was originally written because
        #       the column was a 'blob' (2^16-1 byts), but it doesn't
        #       hurt, so it lives on.
        if (length($hdr)+4 > (1<<24)-1) {
            undef $hdr;
            last;
        }
    }
    if ($hdr) { # only if we didn't last out because of size above
        $hdr .= $read->(4) or return undef;
    }

    # save header in the database
    $save->();

    return \$hdr;
}

# if needed, autorotates JPEG based on exif info.  returns 1 if rotated, 0 if couldn't/didn't
sub autorotate {
    my $up = shift;

    my $ei  = $up->exif_info_raw  or return 0;
    my $orv = $ei->{Orientation}  or return 0;
    my $or  = $orv->[0];
    return 0 if $up->height > $up->width; # already rotated?

    my $need = {
        1 => undef,  # top, left (normal)
        2 => undef,  # top, right
        3 => "R180", # bottom, right
        4 => undef,  # bottom, left
        5 => undef,  # left, top
        6 => "R90",  # right, top
        7 => undef,  # right, bottom
        8 => "L90",  # left, bottom
    }->{$or};

    return 0 unless $need;

    # rotating 180 makes it wide again, and we'd do this forever, so
    # let's deal with this later.  who holds their camera upside down
    # anyway?  let's deal with just 6 and 8, the common cases.
    return 0 if $need =~ /180/;

    # already good direction
    return 0 if $or == 1;
    return 0 if $or == 2; # mirrored horizontally.  ignore this... no cameras do it?

    if ($need =~ /^[LR]90$/) {
        return $up->modify_image(sub {
            my $image = shift;
            $image->Rotate('degrees' => ($need eq "L90" ? -90 : 90))
                or die "failed";
        });
    }

    return 1;
}

sub exif_info_raw {
    my $up = shift;
    return $up->exif_info("tags_literal");
}

# returns undef, or hashref of exif info
sub exif_info {
    my $up = shift;
    my $meth = shift || "tags";

    # only jpegs have exif info
    return undef unless $up->fmtid == FB::fmtid_from_ext('jpg') || $up->fmtid == FB::fmtid_from_ext('tif');

    my $hdr = $up->exif_header;
    return undef unless $hdr && $$hdr;

    # if any of this dies (as Danga::EXIF likes to do, then we just return undef)
    return eval {
        my $exif = Danga::EXIF->new( src => $hdr );
        return $exif->$meth;
    };
}

# $up->modify_image(sub { my FB::Magick $im = shift;  $im->Manipulate(...) or die });
#   returns 1 on success,
#   returns 0 if subref dies, or if can't load gpic/etc
sub modify_image {
    my $up = shift;
    my $subref = shift;

    # load existing gpic for this upic
    my $g = FB::Gpic->load($up->gpicid) or return 0;

    # create a new FB::Magick instance and read in the file data
    my $image = FB::Magick->new($g->data) or return 0;

    my $err = sub {
        my $msg = shift;
        return FB::error("modify_image: $msg");
    };

    eval {
        $subref->($image);
    };

    if ($@) {
        return FB::error("Error rotating image: $@");
    }

    my $md5 = Digest::MD5::md5_hex(${$image->dataref});
    my $len = $image->Get('filesize');

    my $gs;
    # see if there is already a gpic with this now-altered data
    if (my $gpicid = FB::find_equal_gpicid($md5, $len, $g->{'fmtid'})) {
        $gs = FB::Gpic->load($gpicid)
            or return $err->("Unable to load equal gpic");
    }

    # create a new gpic if there was no equal gpicid
    unless ($gs) {
        $gs = FB::Gpic->new
            or return $err->("gpic_new returned undef");

        $gs->{fmtid} = $g->{fmtid};

        # save the modified image
        $gs->append($image);
        undef $image; # throw away now if we can

        $gs->save
            or return $err->("gpic_save returned error: $@");
    }
    undef $image; # definitely done with this

    # now that we have a new gpic altered from the old once, swap the
    # upic reference to point to the new, altered image
    $up->set_gpic($gs)
        or return $err->("Failed to change upic's gpic.");

    $up->reset_to_skeleton;

    return 1;
}

sub delete {
    my $up = shift;
    $up->valid or die;
    my $u      = $up->{u};
    my $userid = $u->{'userid'};
    my $upicid = $up->id;
    die "upic_delete(): No gpicid in \$p\n" unless defined $up->{'gpicid'};

    foreach my $g ($up->galleries) {
        FB::change_gal_size($u, $g, $up->{'secid'}, -1);
    }

    $up->delete_thumbnails;

    foreach my $t (qw(gallerypics upic upicprop upic_thumb upic_exif)) {
        $u->do("DELETE FROM $t WHERE userid=? AND upicid=?",
               $userid, $upicid);
    }
    $u->do("DELETE FROM des WHERE userid=? AND itemtype='P' AND itemid=?",
           $userid, $upicid);

    FB::run_hook("free_disk", $u, $up->{'bytes'});
    $up->{_deleted} = 1;
    return 1;
}

sub set_cropfocus
{
    my ($up, $value) = @_;
    return 1 if $up->prop('cropfocus') eq $value;
    return 0 unless $up->set_prop('cropfocus', $value);

    # delete thumbnails using it:
    my $u = $up->{u};
    my $sth = $u->prepare(qq{
        SELECT gpicid FROM upic_thumb WHERE
        userid=? and upicid=? AND fmtstring REGEXP '[chz]'
    }, $u->{'userid'}, $up->{'upicid'});
    $sth->execute;
    my @ids;
    my $id;
    push @ids, $id while $id = $sth->fetchrow_array;
    return 1 unless @ids;

    $u->do("DELETE FROM upic_thumb WHERE userid=? AND upicid=? ".
           "AND fmtstring REGEXP '[chz]'", $u->{'userid'},
           $up->{'upicid'});

    FB::gpicid_delete(@ids);
    return 1;
}

sub info_url {
    my $up = shift;
    return $up->url_base . ".xml";
}

sub info_xml {
    my $up = shift;
    my $xml = '';

    my $gp = $up->gpic or return "Could not load gpic.";

    my $title = FB::exml($up->title);
    my $desc = FB::exml($up->des);
    my $infoUrl = FB::exml($up->info_url);
    my $digest = FB::exml($gp->md5_hex);
    my $mime = FB::fmtid_to_mime($gp->{'fmtid'});
    my $width = $gp->{width};
    my $height = $gp->{height};
    my $bytes = $gp->{bytes};

    my $u = $up->{u};
    my $piccode = $up->piccode;
    my $imgUrl = FB::exml($u->url_root . "pic/$piccode");

    my $tagxml = '';
    my @tags = $up->tags;
    foreach my $tag (@tags) {
        next unless $tag;
        my $tagg = FB::Gallery->load_gallery_of_tag($u, $tag) or next;
        my $tagurl = $tagg->url;
        my $taginfourl = $tagg->info_url;
        $tagxml .= qq {
            <tag>
                <name>$tag</name>
                <infoUrl>$taginfourl</infoUrl>
                <url>$tagurl</url>
            </tag>
        };
    }

    $xml .= qq {
        <mediaSetItem>
            <title>$title</title>
            <description>$desc</description>
            <infoUrl>$infoUrl</infoUrl>
            <file>
                <digest type="md5">$digest</digest>
                <mime>$mime</mime>
                <width>$width</width>
                <height>$height</height>
                <bytes>$bytes</bytes>
                <url>$imgUrl</url>
                $tagxml
            </file>
        </mediaSetItem>
    };
}


package FB;

sub load_upic_by_gpic {  #DEPRECATED
    my ($u, $gpicid, $opts) = @_;
    return undef unless $u && $gpicid;

    my $up = $FB::REQ_CACHE{"upicgpic:$u->{userid}:$gpicid"};
    return $up if $up;

    # get from database
    if ($up = FB::_get_upic($u, { gpicid => $gpicid }, $opts)) {
        return $FB::REQ_CACHE{"upicgpic:$u->{userid}:$gpicid"} = $up;
    }

    return undef;
}

sub load_upic  #DEPRECATED
{
    &nodb;

    my ($u, $upicid, $opts) = @_;
    return undef unless $u && $upicid;

    my $up = $FB::REQ_CACHE{"upic:$u->{'userid'}:$upicid"};
    return $up if $up;

    # get from database
    if ($up = FB::_get_upic($u, { upicid => $upicid }, $opts)) {
        return $FB::REQ_CACHE{"upic:$u->{'userid'}:$upicid"} = $up;
    }

    return undef;
}

# internal getter from database
# - accepts a $u and either a upicid or gpicid in the $idarg hash
# - $opts hash is same as FB::load_upic
sub _get_upic   #DEPRECATED
{
    my ($u, $idarg, $opts) = @_;
    return undef unless $u && ref $idarg && $idarg->{upicid} || $idarg->{gpicid};

    my $idwhere = $idarg->{upicid} ? "upicid=?" : "gpicid=?";
    my $id = $idarg->{upicid} || $idarg->{gpicid};

    my $up = $u->selectrow_hashref("SELECT * FROM upic WHERE userid=? AND $idwhere LIMIT 1",
                                   $u->{'userid'}, $id);
    return undef unless $up;

    # different members get called in different places.
    # needs cleaning
    $up->{picsec} = $up->{secid};

    if ($opts->{'props'}) {
        FB::load_upic_props($u, $up, @{$opts->{'props'}});
    }

    return $up;
}

sub load_upic_multi  #DEPRECATED
{
    my ($u, $upicids, $opts) = @_;
    return undef unless $u && ref $upicids;

    my %ret = ();
    my @need = ();
    foreach my $upicid (@$upicids) {
        next if $ret{$upicid} = $FB::REQ_CACHE{"upic:$u->{'userid'}:$upicid"};
        push @need, $upicid;
    }

    if (@need) {
        my $in = join(",", map { $_ + 0 } @need);
        my $sth = $u->prepare("SELECT * FROM upic WHERE userid=? AND upicid IN ($in)",
                              $u->{userid});
        $sth->execute;
        while (my $up = $sth->fetchrow_hashref) {
            $up->{picsec} = $up->{secid};
            $ret{$up->{upicid}} = $up;
            $FB::REQ_CACHE{"upic:$u->{userid}:$up->{upicid}"} = $up;
        }
    }

    return undef unless %ret;

    if ($opts->{'props'}) {
        FB::load_upic_props_multi($u, \%ret, @{$opts->{'props'}});
    }

    return \%ret;
}

sub upics_of_user  #DEPRECATED
{
    my ($u, $opts) = @_;
    return undef unless $u;

    my %ret = ();
    return FB::error("Unable to connect to user database cluster") unless $u->writer;

    my $sth = $u->prepare("SELECT * FROM upic WHERE userid=?",
                          $u->{userid});
    $sth->execute;
    return FB::error($u) if $u->err;

    while (my $up = $sth->fetchrow_hashref) {
        $up->{picsec} = $up->{secid};
        $ret{$up->{upicid}} = $up;
        $FB::REQ_CACHE{"upic:$u->{userid}:$up->{upicid}"} = $up;
    }
    return {} unless %ret;

    if ($opts->{'props'}) {
        FB::load_upic_props_multi($u, \%ret, @{$opts->{'props'}});
    }

    return \%ret;
}

sub upic_exif_header #DEPRECATED
{
    my ($u, $p, $src) = @_;
    $u = FB::want_user($u);

    # only jpegs have exif info
    unless ($p->{fmtid} == FB::fmtid_from_ext('jpg')) {
        my $hdr = "";
        return \$hdr;
    }

    # first query database to see if the header is already stored there
    return FB::error("Couldn't connect to user db") unless $u->writer;

    my $ary = $u->selectcol_arrayref
        ("SELECT data FROM upic_exif WHERE userid=? AND upicid=?",
         $u->{userid}, $p->{upicid}) || [];
    return FB::error($u) if $u->err;

    # if we got rows from the database, we return either the value
    # or "" if null.  either way, we've extracted from this file before
    my $hdr = "";
    if (@$ary) {
        $hdr = $ary->[0] . ""; # stringify if null
        return \$hdr;
    }

    # subref to save header to database once it's found (or there's an unrecoverable error)
    my $save = sub {
        # save header we just read into database for quick access later
        return FB::error("Couldn't connect to user db writer") unless $u->writer;

        $hdr = undef unless $hdr; # "" => undef => NULL
        my $rv = $u->do("REPLACE INTO upic_exif SET userid=?, upicid=?, data=?",
                        $u->{userid}, $p->{upicid}, $hdr);
        return FB::error($u) if $u->err;
        return $rv;
    };

    # need to extract header and save to db
    # -- caller can pass in a scalar ref or filehandle as $src,
    #    otherwise we'll get the data from the upic's gpic
    unless ($src) {
        my $gpic = FB::Gpic->load($p->{gpicid})
            or return FB::error("Couldn't load gpic: $p->{gpicid}");

        $src = $gpic->data;
    }

    # sub to read chunks of data
    # - this sub sets FB::error before returning undef on failure, so callers
    #   should just return undef when undef is returned so they don't overwrite
    #   the last_error stored by $read
    my $offset = 0;
    my $read = sub {
        my $len = shift;
        my ($rbuf, $n);

        if (ref $src eq 'SCALAR') {
            $rbuf = substr($$src, $offset, $len);
            $n = length($rbuf);
        } else {
            $n = read($src, $rbuf, $len);
        }
        return FB::error("Error reading EXIF header: read failed: $!")
            unless defined $n;
        return FB::error("Error reading EXIF header: short read ($len/$n)")
            unless $n == $len;

        $offset += $len;
        return $rbuf;
    };

    # read jpeg magic to make sure this file is valid
    $hdr = $read->(2) or return undef;
    unless ($hdr eq "\xFF\xD8") {

        # save a NULL in the database because this is an invalid EXIF
        # header and we'll never be able to successfully read it, so
        # no point in trying later
        $save->();

        return FB::error("Error reading EXIF header: SOI missing");
    }

    # read until end of header
    while (1) {
        my $chunk = $read->(4) or return undef;
        my ($ff, $mark, $len) = unpack("CCn", $chunk);
        last if $ff != 0xFF;
        last if $mark == 0xDA || $mark == 0xD9;  # SOS/EOI
        last if $len < 2;

        $hdr .= $chunk . $read->($len - 2) or return undef;

        # the database field for this header is a mediumblob,
        # which can store 2^24-1 bytes.  if we've read past
        # that point, we'll ignore the exif data for this image
        # and just store a null.
        #
        # Note: this is superfluous and was originally written because
        #       the column was a 'blob' (2^16-1 byts), but it doesn't
        #       hurt, so it lives on.
        if (length($hdr)+4 > (1<<24)-1) {
            undef $hdr;
            last;
        }
    }
    if ($hdr) { # only if we didn't last out because of size above
        $hdr .= $read->(4) or return undef;
    }

    # save header in the database
    $save->();

    return \$hdr;
}

sub upic_exif_info    #DEPRECATED
{
    my ($u, $p) = @_;
    $u = FB::want_user($u);

    # only jpegs have exif info
    return {} unless $p->{fmtid} == FB::fmtid_from_ext('jpg') || $p->{fmtid} == FB::fmtid_from_ext('tif');

    my $hdr = FB::upic_exif_header($u, $p)
        or return FB::error("Couldn't retrieve upic exif header");
    return {} unless $$hdr;

    my $exif = new Danga::EXIF ( src => $hdr );
    return $exif->tags;
}

sub change_upic_secid   #DEPRECATED
{
    my ($u, $p, $secid) = @_;
    my $fail = sub {
        my $msg = shift;
        warn "change_upic_secid: failing due to $msg\n";
        return undef;
    };
    return $fail->("bad args") unless $u && $p && defined $secid;

    $secid += 0;
    my $oldsecid = $p->{picsec};
    return 1 if $secid == $oldsecid;

    $u->writer or return $fail->("no writer");

    # first, which gals does this upic belong to?
    my @gals = FB::gals_of_upic($u, $p);

    # need to decrement gal sizes for this secid
    foreach my $g (@gals) {

        # FIXME: it used to be non-trivial to update
        #        a gallery's size based on security
        #        of its member upics. now, since secid
        #        is part of the upic table, it's easy
        #        so we need a new FB::update_gal_size
        #        which does all of the counting/updating
        #        on its own

        FB::change_gal_size($u, $g, $oldsecid, -1);
        FB::change_gal_size($u, $g, $secid,    +1);
    }

    $u->do("UPDATE upic SET secid=? WHERE userid=? AND upicid=?",
           $secid, $u->{userid}, $p->{upicid})
        or return $fail->("do failed");

    return 1;
}

# change many upic secids simultaneously
sub change_upic_secid_multi   #DEPRECATED
{
    my ($u, $p, $secid) = @_;
    return undef unless $u && $p && defined $secid;
    return undef unless ref $p eq 'ARRAY';
    $secid += 0;

    # if the caller only passed 1 pic obj in the array ref,
    # default back to change_upic_secid()
    return FB::change_upic_secid($u, $p->[0], $secid) if scalar @$p == 1;

    # ignore any upics that don't need
    # their security changed.
    my $pics = [ grep { $secid != $_->{picsec} } @$p ];
    return undef unless scalar @$pics;

    # we assume the oldsecid is the same across all picts.
    # /manage/media/gal already sanity checks this for us before
    # we get to this point, however this might not be
    # 'the best thing to do' if there end up being other callers
    # to this function.
    # FIXME: This is ghetto.  Need to tack on a separate
    # layer to change_gal_size_multi() to include proper old secids
    # per upic.
    my $oldsecid = $pics->[0]->{picsec};

    # get a secid count delta for each gallery
    my %upic_gals = FB::gals_of_upic_multi($u, $pics);
    my %gal_secid_counts;
    foreach my $gals (values %upic_gals) {
        $gal_secid_counts{$_}++ foreach @$gals;
    }

    # switch keys from gallids to deltas
    # 4 => 8, 5, => 8, 6 => 2     to
    # 8 => [4, 5], 2 => [6]
    my %gal_deltas;
    push @{ $gal_deltas{ $gal_secid_counts{$_} } }, $_
        foreach keys %gal_secid_counts;

    # update gallery counts - one update per delta
    foreach (keys %gal_deltas) {
        FB::change_gal_size_multi($u, $gal_deltas{$_}, $oldsecid, -$_);
        FB::change_gal_size_multi($u, $gal_deltas{$_}, $secid, $_);
    }

    my $ids = join ', ', map { $_->{'upicid'}+0 } @$pics;

    my $udbh = FB::get_user_db_writer($u)
        or return undef;

    $udbh->do("UPDATE upic SET secid=? WHERE userid=? AND upicid IN ($ids)",
              undef, $secid, $u->{'userid'})
        or return undef;

    return 1;
}

sub gals_of_upic   #DEPRECATED
{
    &nodb;

    my ($u, $up, $opts) = @_;

    my $limit = wantarray ? "" : "LIMIT 1";

    my $sth = $u->prepare(qq{
        SELECT g.userid, g.gallid, g.name, g.randauth,
               g.secid AS 'galsec', g.dategal
        FROM gallery g, gallerypics gp
        WHERE g.userid=? AND gp.userid=g.userid
        AND g.gallid=gp.gallid AND gp.upicid=? $limit
    }, $u->{'userid'}, $up->{'upicid'});
    $sth->execute;
    my @gals;
    my $unsorted = undef;
    while (my $g = $sth->fetchrow_hashref) {
        $unsorted = $g if FB::gal_is_unsorted($g);
        push @gals, $g;
    }

    # picture is in multiple galleries, one of which is unsorted,
    # so remove the unsorted membership
    if (@gals > 1 && $unsorted) {
        @gals = grep { ! FB::gal_is_unsorted($_) } @gals;
        FB::gal_remove_picture($u, $unsorted, $up);
    }

    return wantarray ? (sort { $a->{'name'} cmp $b->{'name'} } @gals) : scalar @gals;
}

# expects an arrayref of upicids
# returns a hash
# upicid => [ galleries upic is a member of ]
sub gals_of_upic_multi #DEPRECATED
{
    my ($u, $p) = @_;
    return undef unless $u && $p && ref $p eq 'ARRAY';

    my @all_pic_ids = map { $_->{'upicid'}+0 } @$p;
    my $ids = join ', ', @all_pic_ids;

    my $q = qq{
        SELECT upicid,gallid FROM gallerypics
        WHERE userid=? AND upicid IN ($ids);
    };

    my $data =
        $u->selectall_arrayref($q, $u->{'userid'});

    return undef unless $data;

    my %upic_gals;
    foreach (@$data) {
        my ($picid, $galid) = ($_->[0], $_->[1]);
        $upic_gals{$picid} = [] unless exists $upic_gals{$picid};
        push @{ $upic_gals{$picid} }, $galid;
    }

    return %upic_gals;
}

sub thumbnail_fmtstring  ## DEPRECATED: use $up->thumbnail_fmtstring
{
    my ($up, $tsty) = @_;

    my $fmt = $tsty->[2];
    my ($nw, $nh);
    my ($ow, $oh) = ($up->{'width'}, $up->{'height'});
    if ($fmt =~ /[hz]/) {
        ($nw, $nh) = ($tsty->[0], $tsty->[1]);
    } elsif ($fmt =~ /c/ && $up->{'cropfocus'}) {
        my @cf = split(/,/, $up->{'cropfocus'});
        ($ow, $oh) = ($up->{'width'} * ($cf[2]-$cf[0]),
                      $up->{'height'} * ($cf[3]-$cf[1]));
    }
    unless ($nw || $nh) {
        ($nw, $nh) = FB::scale($ow, $oh, $tsty->[0], $tsty->[1]);
    }

    $fmt = sprintf("%2x%2x%s", $nw, $nh, $fmt);
    return wantarray() ? ($fmt, $nw, $nh) : $fmt;
}

sub url_thumbnail  #DEPRECATED
{
    my ($u, $pic, $tsty) = @_;  # $tsy = [ width, height, format ]
    my $user = want_username($u);

    my ($fmt, $nw, $nh) = FB::thumbnail_fmtstring($pic, $tsty);
    my $url;

    if (FB::fmtid_is_video( $pic->{'fmtid'} ) && ! $FB::USE_MPLAYER) {
        $url = FB::user_siteroot($u) . "/img/dynamic/video_160x120.jpg/scale/$nw/$nh";
        return wantarray ? ($url, $nw, $nh) : $url;
    }

    $url = FB::url_picture($u, $pic, "/t$fmt");
    return wantarray() ? ($url, $nw, $nh) : $url;
}

sub url_picture  #DEPRECATED
{
    # user can be scalar or $u hashref
    # piccode can be scalar piccode, hashref with 'piccode', or picture hashref
    my ($u, $piccode, $extra) = @_;

    $u = want_user($u);
    if (ref $piccode) {
        if ($piccode->{'piccode'}) { $piccode = $piccode->{'piccode'}; }
        else { $piccode = FB::piccode($piccode); }
    }

    die "FB::url_picture(): No username?\n" unless $u;

    return $u->media_base_url . "/pic/$piccode$extra";
}

sub url_picture_page  #DEPRECATED
{
    my ($user, $piccode, $gal) = @_;  # gal is optional
    my $extra = $gal ? "g$gal->{'gallid'}" : "";
    return url_picture($user, $piccode, "/$extra");
}

sub piccode  ## DEPRECATED: use $up->piccode
{
    my $p = shift;
    return make_code($p->{'upicid'}, $p->{'randauth'});
}

sub upic_used  #DEPRECATED
{
    &nodb;
    my ($u, $p) = @_;
    return scalar FB::gals_of_upic($u, $p);
}

sub change_upic_gpic  ## DEPRECATED:  use $up->set_gpic
{
    my ($u, $up, $gp) = @_;

    my $udbh = FB::get_user_db_writer($u);
    return 0 unless $udbh;

    my $old_gpicid = $up->{'gpicid'};

    FB::delete_upic_thumbnails($u, $up);
    FB::set_upic_prop($u, $up, 'modtime', time());

    $udbh->do("UPDATE upic SET gpicid=?, width=?, height=?, bytes=? ".
              "WHERE userid=? AND upicid=?",
              undef, $gp->{'gpicid'}, $gp->{'width'}, $gp->{'height'},
              $gp->{'bytes'}, $u->{'userid'}, $up->{'upicid'});
    return 0 if $udbh->err;

    $udbh->do("DELETE FROM upic_exif WHERE userid=? AND upicid=?",
              undef, $u->{userid}, $up->{upicid});

    delete $FB::REQ{"upic:$u->{'userid'}:$up->{'upicid'}"};

    FB::gpicid_delete($up->{'gpicid'});
    FB::run_hook("free_disk", $u, $up->{'bytes'});
    FB::run_hook("use_disk", $u, $gp->{'bytes'});

    foreach (qw(width height bytes gpicid)) {
        $up->{$_} = $gp->{$_};
    }

    return 1;
}

sub upic_delete  ## DEPRECATED:  use $up->delete
{
    my ($u, $p) = @_;

    my $userid = $p->{'userid'} || $u->{'userid'};
    die "upic_delete(): No gpicid in \$p\n" unless defined $p->{'gpicid'};

    foreach my $g (FB::gals_of_upic($u, $p)) {
        FB::change_gal_size($u, $g, $p->{'picsec'}, -1);
    }

    my $thumb_gpicids = $u->selectcol_arrayref("SELECT gpicid FROM upic_thumb " .
                                               "WHERE userid=? AND upicid=?",
                                               $userid, $p->{'upicid'});

    FB::gpicid_delete($p->{'gpicid'}, @$thumb_gpicids);

    foreach my $t (qw(gallerypics upic upicprop upic_thumb upic_exif)) {
        $u->do("DELETE FROM $t WHERE userid=? AND upicid=?",
               $userid, $p->{'upicid'});
    }
    $u->do("DELETE FROM des WHERE userid=? AND itemtype='P' AND itemid=?",
           $userid, $p->{'upicid'});

    FB::run_hook("free_disk", $u, $p->{'bytes'});

    return 1;
}

sub load_thumb_gpic #DEPRECATED
{
    my ($u, $up, $tsty) = @_;
    return undef unless $u && $up && ref $tsty;

    $u->writer or return undef;

    my $fmt = FB::thumbnail_fmtstring($up, $tsty);
    my $gpicid = $u->selectrow_array
        ("SELECT gpicid FROM upic_thumb " .
         "WHERE userid=? AND upicid=? AND fmtstring=?",
         $u->{userid}, $up->{upicid}, $fmt)
        or return undef;

    return FB::Gpic->load($gpicid);
}

sub delete_upic_thumbnails  ## DEPRECATED: use $up->delete_thumbnails
{
    my ($u, $up) = @_;
    return 0 unless $u->{'userid'} == $up->{'userid'};

    my $sth = $u->prepare(qq{
        SELECT gpicid FROM upic_thumb WHERE userid=? and upicid=?
    }, $u->{'userid'}, $up->{'upicid'});
    $sth->execute;
    my @ids;
    my $id;
    push @ids, $id while $id = $sth->fetchrow_array;
    return 1 unless @ids;

    $u->do("DELETE FROM upic_thumb WHERE userid=? AND upicid=? ",
           $u->{'userid'}, $up->{'upicid'});

    FB::gpicid_delete(@ids);
    return 1;
}

sub load_upic_props  #DEPRECATED
{
    &nodb;
    my ($u, $up, @props)= @_;
    return undef unless $up && $u;

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
        else { return $up; }
    }

    my $sth = $u->prepare("SELECT propid, value FROM upicprop ".
                          "WHERE userid=? AND upicid=? " . $where,
                          $u->{'userid'}, $up->{'upicid'});
    $sth->execute;
    while (my ($id, $value) = $sth->fetchrow_array) {
        my $name = $ps->{$id};
        next unless $name;
        $up->{$name} = $value;
    }
    return $up;
}

sub load_upic_props_multi  #DEPRECATED
{
    &nodb;
    my ($u, $ups, @props)= @_;
    return undef unless $u && ref $ups;

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
        else { return 1; }
    }

    my @upicids = map { $_->{upicid}+0 } values %$ups;
    my $upicid_in = join(",", map { $_ + 0 } @upicids);

    my $sth = $u->prepare("SELECT upicid, propid, value FROM upicprop ".
                          "WHERE userid=? AND upicid IN ($upicid_in) " . $where,
                          $u->{'userid'});
    $sth->execute;
    while (my ($upicid, $propid, $value) = $sth->fetchrow_array) {
        my $name = $ps->{$propid};
        next unless $name;
        $ups->{$upicid}->{$name} = $value;
    }

    return 1;
}

sub can_view_picture  #DEPRECATED
{
    my ($u, $pic, $remote) = @_;
    return undef unless $u && $pic;

    return FB::can_view_secid($u, $remote, $pic->{secid});
}



1;
