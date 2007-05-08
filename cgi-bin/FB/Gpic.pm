#!/usr/bin/perl

package FB::Gpic;

use strict;

BEGIN {
    use fields qw(
                  gpicid pclusterid pclustertype
                  md5sum md5ctx
                  fmtid width height bytes
                  fh paths alt
                  paths_loaded
                  mogile_verified
                  _cache_data
                  );

    use Carp;
    use Digest::MD5 qw(md5);
    use MIME::Base64;
    use LWP::Simple;
}


################################################################################
# Constructors
#

# create skeleton structure
sub new {
    my FB::Gpic $self = shift;

    $self = fields::new($self)
        unless ref $self;

    # fill in some defaults
    $self->{pclusterid}   = 0;
    $self->{pclustertype} = 'disk';
    $self->{md5sum}       = undef;
    $self->{md5ctx}       = new Digest::MD5;
    $self->{fmtid}        = 0;
    $self->{width}        = 0;
    $self->{height}       = 0;
    $self->{bytes}        = 0;
    $self->{fh}           = undef;
    $self->{paths}        = [];
    $self->{paths_loaded} = 0;      # bool, if paths have been loaded
    $self->{mogile_verified} = 0;   # bool, if first mogile has been verified
    $self->{alt}          = undef;

    # cache, don't acces
    $self->{_cache_data}  = undef;

    my %args = @_;
    while (my ($field, $val) = each %args) {
        $self->{$field} = $val;
    }

    # determine pclusterid and pclustertype
    unless ($args{pclustertype} && defined $args{pclusterid}) {
        ($self->{pclustertype}, $self->{pclusterid}) = FB::lookup_pcluster_dest();

        croak "Couldn't get pclustertype" unless $self->{pclustertype};
        croak "Couldn't get pclusterid" unless defined $self->{pclusterid};
    }

    my $dbh = FB::get_db_writer()
        or croak "Couldn't get global db writer";

    # allocate a gpicid if we don't have one (new gpic)
    unless ($self->{gpicid}) {
        $dbh->do("INSERT INTO gpic (pclustertype, pclusterid) VALUES (?,?)",
                 undef, $self->{pclustertype}, $self->{pclusterid});

        $self->{'gpicid'} = $dbh->{'mysql_insertid'}
            or croak "Couldn't allocate gpicid: " . $dbh->errstr;
    }

    return $self;
}

sub id {
    my FB::Gpic $self = shift;
    return $self->{gpicid};
}


sub load {
    my FB::Gpic $self = shift;
    my ($gpicid, $opts) = @_;
    croak "No gpicid" unless $gpicid;

    unless (exists $FB::REQ_CACHE{"gpic:$gpicid"}) {
        my $db = $opts->{force} ? FB::get_db_writer() : FB::get_db_reader();
        my $gpic = $db->selectrow_hashref("SELECT * FROM gpic WHERE gpicid=?",
                                          undef, $gpicid);
        croak $db->errstr if $db->err;

        # the md5sum is a "CHAR(16) BINARY" column, so any "spaces" will be removed,
        # meaning that any md5sum that happens to end in 20h will become 15 bytes
        # in the database instead of 16.  so if we detect a 15 byte md5 here, we
        # can safely assume that last byte is 20h.
        $gpic->{md5sum} .= ' 'x(16-length($gpic->{md5sum})) if $gpic;

        $FB::REQ_CACHE{"gpic:$gpicid"} = $gpic ? $self->new(%$gpic) : undef;
    }

    return $FB::REQ_CACHE{"gpic:$gpicid"};
}

# can be called as $gpic->load_scaled or FB::Gpic->load_scaled($gpic, $w, $h)
# -- will create a new gpic if necessary and verify paths of any existing 
#    gpics before returning them
sub load_scaled {
    my FB::Gpic $self = shift;
    my $gpicid = ref $self ? $self->{gpicid} : shift();
    my ($w, $h, $opts) = @_;
    $opts = {} unless ref $opts eq 'HASH';

    # Before we decide to register a job, we'll see if the image already exists.
    if (my $gpic_exist = FB::Gpic->load_scaled_existing($gpicid, $w, $h)) {
        return $gpic_exist;
    }

    # if we're not told to create a new gpic, and one doesn't exist, that's it
    return undef unless $opts->{create};

    # if our caller allows us to create new gpics, register a job to do so now
    my $gpicid_ref = FB::Job->do
        ( job_name => 'scale_image',
          arg_ref  => [ $gpicid, $w, $h, $opts ],
          task_ref => \&FB::Gpic::_load_scaled_do,
          );
    
    # res_ref should be a scalar ref now
    return ref $gpicid_ref ? FB::Gpic->load($$gpicid_ref) : undef;
}

# loads an existing scaled gpic from the database, verifying its paths
# -- for creating new scaled  gpics, use $gpic->load_scaled
sub load_scaled_existing {
    my FB::Gpic $self = shift;
    my $g_orig = ref $self ? $self : FB::want_gpic(shift());
    my ($w, $h) = @_;

    my $gpicido = $g_orig->{gpicid};

    # check that scaling is appropriate (in set of fixed sizes/scaling ratios)
    # and isn't larger than original.
    croak "Invalid scaling ($w, $h)"
        unless FB::valid_scaling($w, $h);

    # $w and $h are round dimensions like 640x480, but when images are scaled
    # those numbers are modified to preserve aspect ratio.  it is these new
    # numbers which eventually live in the gpic_scaled table
    my ($nw, $nh) = FB::scale($g_orig->{width}, $g_orig->{height}, $w, $h);

    # check database to see if a scaled version should exist
    my $dbh = FB::get_db_writer()
        or croak "Unable to connect to global writer";

    # check for a scaled version in gpic_scaled
    my $gpicids = $dbh->selectrow_array
        ("SELECT gpicids FROM gpic_scaled WHERE ".
         "gpicido=? AND width=? AND height=?",
         undef, $gpicido, $nw, $nh);
    croak $dbh->errstr if $dbh->err;

    # scaled image supposedly exists, let's verify paths.  if the image
    # refers to an invalid gpic or a gpic with no paths, then we'll delete
    # the gpic so it can be created later
    my $g = $gpicids ? FB::Gpic->load($gpicids) : undef;

    unless ($g && $g->verified_paths) {

        # $g had no paths, so let's delete it so a new one can be made
        # - note delete for $gpicids is done on the primary key ($gpicido, $w, $h)
        $dbh->do("DELETE FROM gpic_scaled WHERE gpicido=? AND width=? AND height=?",
                 undef, $gpicido, $nw, $nh);
        FB::gpicid_delete($gpicids);

        return undef;
    }

    # attempt to load the gpic referenced in gpic_scaled
    return $g;
}

# The guts of FB::Gpic->load_scaled, abstracted here so it can be used
# as a handler for FB::Job
# - accepts arrayref [ gpicid, w, h, opts ]
# - returns \$gpicid
sub _load_scaled_do {
    my $arg_ref = shift;
    croak "received invalid arg_ref"
        unless ref $arg_ref eq 'ARRAY';
    
    my ($gpicid, $w, $h, $opts) = @$arg_ref;

    # get an original gpic object if they didn't specify one
    my $g_orig = FB::Gpic->load($gpicid)
        or croak "No original gpic";

    # check that scaling is appropriate (in set of fixed sizes/scaling ratios)
    # and isn't larger than original.
    croak "Invalid scaling ($w, $h)"
        unless FB::valid_scaling($w, $h);

    # now get a scaling width/height
    my ($nw, $nh) = FB::scale($g_orig->{width}, $g_orig->{height}, $w, $h);
    croak "Scaling dimensions must be smaller than original"
        if $nw > $g_orig->{width} || $nh > $g_orig->{height};

    # check database to see if a scaled version should exist
    my $dbh = FB::get_db_writer()
        or croak "Unable to connect to global writer";

    # see if there is an existing scaled version of this image for the given
    # dimensions... also verify that it has verified paths
    my $g_scaled = $g_orig->load_scaled_existing($w, $h);
    return \$g_scaled->{gpicid} if $g_scaled;

    # if $g_scaled didn't exist, or existed and had no data, it needs to
    # have its data regenerated ... two operations we can't do without
    # opts->{create}.  return undef here in that situation

    return undef unless $opts->{create};

    # revalidate that we still need one now that we're in the lock
    $g_scaled = $g_orig->load_scaled_existing($w, $h);
    return \$g_scaled->{gpicid} if $g_scaled;

    # get a lock so nobody else tries to make this scaled image
    my $lockname = "gpic_scaled:$g_orig->{gpicid}";
    my $got_lock = $dbh->selectrow_array
        ("SELECT GET_LOCK(?, 30)", undef, $lockname)
        or croak "Unable to obtain lock: $lockname";

    my $unlock = sub {
        $dbh->do("SELECT RELEASE_LOCK(?)", undef, $lockname);
        return 1; # so we can do $unlock->() && croak blah
    };

    my @gpicid_delete; # gpicids to delete on error
    my $flush_gpicid_delete = sub {
        return 1 unless @gpicid_delete;
        FB::gpicid_delete(@gpicid_delete);
        @gpicid_delete = ();
    };

    my $err = sub {
        $flush_gpicid_delete->();
        $unlock->();
        croak $_[0];
    };

    # now we're going to resize a gpic and, need to find a $g_from to scale from
    # ... could be $g_orig but hopefully not

    # the scaled file is not in db, or in db but not on disk.
    # either way, we'll allocate a new gpicid for it

    my $type = FB::fmtid_is_video($g_orig->{fmtid}) ? "video" : "still";

    # 1) try to create one from "gpic for scaling"
    my $g_from = $type eq "still" ?
        FB::Gpic->load_for_scaling($g_orig, $nw, $nh) :
        $g_orig->load_full_still;

    my $contentref = undef;

    if ($g_from) {
        $contentref = $g_from->data if $g_from->paths;
        push @gpicid_delete, $g_from->{gpicid} unless $contentref;
    }

    # 2) use original if the gpic selected for scaling doesn't exist
    unless ($contentref) {

        # using original as source
        $g_from = $g_orig;
        $contentref = $g_from->data if $g_from->paths;

        # original gpic doesn't exist on disk?  no hope now
        push @gpicid_delete, $g_from->{gpicid} unless $contentref;
    }

    # flush any invalid gpics that we found from the delete queue
    $flush_gpicid_delete->();

    # somehow we ended up with no $g_orig to scale from, is the current
    # gpic object invalid or without paths?  nothing we can do from here.
    unless ($g_from && $contentref) {
        $unlock->();
        return undef;
    }

    # allocate a new gpic for the scaled version
    $g_scaled = FB::Gpic->new
        ( alt => 1,
          fmtid => $g_from->{fmtid},
          width => $nw,
          height => $nh,
          )
        or $err->("Unable to create scaled gpic");

    # do image resizing, error on anything unexpected
    my $image = FB::Magick->new($contentref, size => "${nw}x${nh}")
        or $err->(FB::last_error());
    $image->Set('quality' => 85)  # default is 75
        or $err->(FB::last_error());

    # animated gifs are distorted with 'Resize'
    if ($image->Get('format') =~ /graphics interchange/i) {
        unless ($FB::ANIMATED_GIF_THUMBS) { # 1st frame
            $image->deanimate or $err->(FB::last_error());
        }
        $image->Sample('width' => $nw, 'height' => $nh)
            or $err->(FB::last_error());
    } else {
        $image->Resize('width' => $nw, 'height' => $nh)
            or $err->(FB::last_error());
    }

    # verify that the size made by ImageMagick was actually what
    my ($made_w, $made_h) = $image->Get('width', 'height');
    $made_w += 0;
    $made_h += 0;

    $err->("ImageMagick made wrong size (${made_w}x$made_h), wanted (${nw}x$nh)")
        unless $made_w == $nw && $made_h == $nh;

    $g_scaled->append($image);
    undef $image;

    # save this gpic in the database
    eval { $g_scaled->save };
    $err->("Unable to save scaled gpic: $@") if $@;

    # replace into gpic_scaled since we have a scaled version of this gpic now
    $dbh->do("REPLACE INTO gpic_scaled (gpicido, width, height, gpicids) " .
             "VALUES (?,?,?,?)", undef, $g_orig->{gpicid}, $nw, $nh, $g_scaled->{gpicid});
    $err->($dbh->errstr) if $dbh->err;

    # now release lock saying we're finished making the scaled version
    $unlock->();

    return \$g_scaled->{gpicid};
}

sub load_full_still {
    my FB::Gpic $self = shift;
    die "Can't call load_full_still on non-video gpic" unless
        FB::fmtid_is_video($self->{fmtid});

    # the still gpic is represnted in the database as the
    # width=0/height=0 scaled version in gpic_scaled

    my $dbh = FB::get_db_writer()
        or croak "Unable to connect to global writer";

    # check for a scaled version in gpic_scaled
    my $get_scaled = sub {
        my $n_gpicid = int($self->{gpicid});
        my $gpicids = $dbh->selectrow_array
            ("SELECT gpicids FROM gpic_scaled WHERE ".
             "gpicido=$n_gpicid AND width=0 AND height=0");
        croak $dbh->errstr if $dbh->err;
        # attempt to load the gpic referenced in gpic_scaled
        return $gpicids ? FB::Gpic->load($gpicids) : undef;
    };

    my $still_gpic = $get_scaled->();
    return $still_gpic if $still_gpic;

    return undef unless $FB::USE_MPLAYER;

    my $first_meg = $self->data({ first => 1024*1024 });

    use File::Temp ();
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    my $vid_path = "$dir/videofile";
    open(VID, ">>$vid_path") or return FB::error("couldn't write to video file");
    print VID $$first_meg;
    close(VID);
    my $err = system("/usr/bin/mplayer", $vid_path, "-vo", "jpeg:outdir=$dir", "-frames", "1");
    return FB::error("Error invoking video thumbnailer: $err") if $err;
    my $still_path = "$dir/00000001.jpg";
    return FB::error("Couldn't make still from video ($still_path)") unless -s $still_path;

    open (STILL, $still_path) or return FB::error("couldn't open still");
    my $slurp = do { local $/; <STILL>; };
    close STILL;

    my ($w, $h) = Image::Size::imgsize(\$slurp);

    $still_gpic = FB::Gpic->new
        ( alt => 1,
          fmtid => FB::fmtid_from_ext("jpg"),
          width => $w,
          height => $h,
          )
        or $err->("Unable to create scaled gpic");

    $still_gpic->append($slurp);

    # save this gpic in the database
    eval { $still_gpic->save };
    return FB::error("Unable to save scaled gpic: $@") if $@;

    # replace into gpic_scaled since we have a scaled version of this gpic now
    $dbh->do("REPLACE INTO gpic_scaled (gpicido, width, height, gpicids) " .
             "VALUES (?,?,?,?)", undef, $self->{gpicid}, 0, 0, $still_gpic->{gpicid});
    $err->($dbh->errstr) if $dbh->err;

    return $still_gpic;
}

sub load_for_scaling {
    my FB::Gpic $self = shift;

    my ($gpic, $nw, $nh, $pixelpercent) = @_;
    my $gpicid = ref $gpic ? $gpic->{gpicid} : $gpic;

    my $minpixels = $nw * $nh;
    if ($pixelpercent) {
        # probably cropping/zooming/stretching crop region,
        # get at least 1x1
        $minpixels /= ($pixelpercent || 1);
    } else {
         # 2x2 pixel rounding at least
        $minpixels *= 4;
    }

    my $dbr = FB::get_db_reader();
    my $smallest = $dbr->selectrow_array(qq{
        SELECT gpicids FROM gpic_scaled
        WHERE gpicido=? AND width*height >= $minpixels
        ORDER BY width*height LIMIT 1
    }, undef, $gpicid);
    croak $dbr->errstr if $dbr->err;

    # if we were given a full gpic and we're using that anyway,
    # just return the object we were given rather than hitting the db
    if (ref $gpic && (! $smallest || $gpic->{gpicid} == $smallest)) {
        return $gpic;
    }

    return FB::Gpic->load($smallest || $gpicid);
}

# swap in spool filehandle and/or hard link to existing file if on disk
sub file_from_spool {
    my FB::Gpic $self = shift;
    my ($spool_fh, $spool_path) = @_;

    # in the future our Gpic::store object should do this logic for us because
    # given our pclusterid/type, it should know how to create a backend storage
    # location

    # disk storage method
    if ($self->{pclustertype} eq 'disk') {

        # spool_path is required for pclustertype 'disk'
        croak 'no spool_path' unless $spool_path;

        # allocate path for new gpic using our paths method
        my $path = $self->paths;
        FB::make_dirs($path)
            or croak "Failed to make directories: $!";

        # now copy spool filehandle into the new gpic
        link($spool_path, $path)
            or croak "Error linking: $spool_path => $path";

        # now that we've linked the permanent spool_path to our final diskfile storage location,
        # set the gpic's filehandle to be the spool_fh
        if ($self->{fh} = $spool_fh) {
            # go-go gadget noop
            binmode($self->{fh});
        }
    }

    # MogileFS storage method
    if ($self->{pclustertype} eq 'mogilefs') {

        # spool_fh is really a MogileFS object
        my $mg = $spool_fh or croak "no MogileFS filehandle";

        # set the key and class attributes so that when
        # gpic_save is called later and the filehandle is closed,
        # the permanent MogileFS file (based on this temp) will be
        # given the correct key/class pair
        $mg->key( FB::Gpic::mogfs_key($self->{gpicid}) )
            or croak "Couldn't set MogileFS key";

        if ($self->{alt}) {
            $mg->class('alt')
                or croak "Couldn't set MogileFS class";
        }

        # set our filehandle to be the updates MogileFS object
        $self->{fh} = $mg;
    }

    return 1;
}

################################################################################
# File Operations
#

sub new_file {
    my FB::Gpic $self = shift;

    # disk storage method
    if ($self->{pclustertype} eq 'disk') {

        # allocate new file on disk
        # allocate path for new gpic using our paths method
        my $path = $self->paths;
        FB::make_dirs($path)
            or croak "Failed to make directories: $!";

        # create filehandle to new file
        unless (defined ($self->{fh} = new IO::File $path, "w+")) {
            croak "Error creating temporary file: $! ($path)";
        }
        binmode($self->{fh});
    }

    # MogileFS storage method
    if ($self->{pclustertype} eq 'mogilefs') {

        # find key and class for new MogileFS file
        my $key = FB::Gpic::mogfs_key($self->{gpicid});
        my $class = $self->{alt} ? 'alt' : undef;
        my $bytes = $self->{bytes}+0;

        # _fh will be based off of IO::File
        unless ($self->{fh} = $FB::MogileFS->new_file($key, $class, $bytes)) {
            croak "Error creating file from MogileFS: " . $FB::MogileFS->errstr;
        }
    }

    return 1;
}

# FIXME: let this take a scalarref
sub append {
    my FB::Gpic $self = shift;
    my $buff = shift;
    my $opts = ref $_[0] eq 'HASH' ? shift : {};

    # allow Image::Magick and FB::Magick buffers to be passed directly
    if (ref $buff eq 'Image::Magick') {
        return $self->append($buff->ImageToBlob);
    }
    if (ref $buff eq 'FB::Magick') {
        return $self->append(${$buff->dataref});
    }

    # if we're being called but the 'fh' member isn't populated,
    # then this is the first append call for the object, so we'll
    # allocate a file to write to
    $self->new_file unless $self->{fh};

    # append data to filehandle and md5 context
    $self->{fh}->print($buff);
    $self->{md5ctx}->add($buff);

    # append to cached version so we'll have it later if we with
    ${$self->{_cache_data}} .= $buff unless $opts->{no_cache};

    $self->{bytes} += length($buff);
    return 1;
}

sub delete
{
    my FB::Gpic $self = shift;

    if ($self->{pclustertype} eq 'mogilefs') {
        my $key = FB::Gpic::mogfs_key($self->{gpicid});
        return $FB::MogileFS->delete($key);
    }

    if ($self->{pclustertype} eq 'disk') {
        return unlink $self->paths;
    }

    return undef;
}

sub close
{
    my FB::Gpic $self = shift;

    if ($self->{fh}) {
        return $self->{fh}->close
            or croak "Couldn't close filehandle: $!";
    }
}

################################################################################
# Gpic Database Operations
#

sub save {
    my FB::Gpic $self = shift;
    my %opts = @_;

    # Image::Size can handle width/height/format
    unless ($self->{fmtid} && $self->{width} && $self->{height}) {

        if ( FB::fmtid_is_video( $self->{fmtid} ) ) {

            # FIXME:  Need to have a unified method of detecting w/h/fmt
            # for videos, and pulling preview frames.  This 'unified
            # method' will most likely be a hook for gearman/mplayer
            # sitting on some other machines.  For now, just hardcode
            # width/height on video, temporarily turning fotobilder into
            # what is essentially a dumb fileserver for video content.
            #
            # We need -some- sort of dimension in the meantime,
            # for thumbnailed placeholders.
            $self->{width}  = 320;
            $self->{height} = 240;
        } elsif ( FB::fmtid_is_audio( $self->{fmtid} ) ) {

            # FIXME: what on earth should be width/height for audio?
            $self->{width}  = 320;
            $self->{height} = 240;
        } else {
            my $src = $self->{fh} || $self->data;
            croak "No source for Image::Size::imgsize, cannot save" unless $src;

            my ($w, $h, $ext) = Image::Size::imgsize($src);
            $self->{fmtid} = FB::fmtid_from_ext($ext)
                or croak "Unknown format";
            $self->{width} = $w;
            $self->{height} = $h;
        }
    }

    # calculate binary md5 sum
    $self->{md5sum} ||= $self->{md5ctx}->digest;

    # close our handle and make sure we close okay
    # Gpic->close will croak if it has an error...
    $self->close unless $opts{no_close};

    my $dbh = FB::get_db_writer()
        or croak "Couldn't get global db writer";

    $dbh->do("UPDATE gpic SET md5sum=?, fmtid=?, bytes=?, width=?, height=? " .
             "WHERE gpicid=?", undef,
             map { $self->{$_} } qw(md5sum fmtid bytes width height gpicid));
    croak $dbh->errstr if $dbh->err;

    return 1;
}

sub discard {
    my FB::Gpic $self = shift;

    FB::gpicid_delete($self->{gpicid});

    eval { $self->close };
    croak $@ if $@;

    return 1;
}


################################################################################
# Data / Member Accessors
#

sub paths {
    my FB::Gpic $self = shift;
    my $noverify = shift; # only for mogilefs case

    # if they ask for it verified, ignore our previous cached value if
    # that previous cached value was for the mogilefs tracker without verify
    if ($self->{pclustertype} eq 'mogilefs' && ! $self->{mogile_verified} && ! $noverify) {
        $self->{paths_loaded} = 0;
    }

    unless ($self->{paths_loaded}) {
        $self->{paths_loaded} = 1;

        # otherwise make some, save in self, then return
        if ($self->{pclustertype} eq 'disk') {
            $self->{paths} = [
                               join("/", $FB::PIC_ROOT, $self->{'pclusterid'},
                                    map { lc sprintf("%02x", $self->{'gpicid'} >> $_ & 255) }
                                    24, 16, 8, 0)
                              ];
        }

        if ($self->{pclustertype} eq 'mogilefs') {

            my $key = FB::Gpic::mogfs_key($self->{gpicid});
            $self->{paths} = [ $FB::MogileFS->get_paths($key, $noverify) ];
            $self->{mogile_verified} = 1 unless $noverify;
        }
    }

    # return array if that's what we want.  otherwise just first element
    return wantarray ? @{$self->{paths}} : $self->{paths}->[0];
}

sub verified_paths {
    my FB::Gpic $self = shift;
    my @paths = $self->paths;

    if ($self->{pclustertype} eq 'disk') {
        @paths = () unless $paths[0] && -s $paths[0];
    }

    return wantarray ? @paths : $paths[0];
}

sub data {
    my FB::Gpic $self = shift;
    my $opts = ref $_[0] eq 'HASH' ? shift : {};
    my @paths = @_; # let caller force data from a given set of paths

    # FIXME: support 'first' to only get some of the file

    if ($self->{_cache_data} && ! $opts->{no_cache}) {
        return $self->{_cache_data}
    }

    # fall back to the paths we know about
    @paths = $self->paths unless @paths;

    # iterate over each
    foreach my $path (@paths) {

        # try via HTTP
        my $contents;
        if ($path =~ m!^http://!) {

            $contents = LWP::Simple::get($path);

        # open the file from disk and just grab it all
        } else {

            open FILE, "<$path" or next;
            { local $/ = undef; $contents = <FILE>; }
            CORE::close FILE;
        }

        if ($contents) {
            $self->{_cache_data} = \$contents unless $opts->{no_cache};
            return \$contents;
        }
    }

    return undef;
}

# NOTE: md5 accessors should never be called while data is still being ->append-ed
#       to a gpic, since calling ->digest on an md5ctx will destroy the context
#       and cause subsequent ->adds to add to a freshly reset context.

sub md5_hex {
    my FB::Gpic $self = shift;

    $self->{md5sum} ||= $self->{md5ctx}->digest;

    return FB::bin_to_hex($self->{md5sum});
}

sub md5_bin {
    my FB::Gpic $self = shift;

    return $self->{md5sum} ||= $self->{md5ctx}->digest;
}

sub md5_base64 {
    my FB::Gpic $self = shift;

    $self->{md5sum} ||= $self->{md5ctx}->digest;
    my $base64 = MIME::Base64::encode($self->{md5sum});
    $base64 =~ s/=+$//;

    return $base64;
}


################################################################################
# Misc Package Functions
#

sub mogfs_key
{
    # FIXME: do we want this packed?
    return "gpic:$_[0]";
}

package FB;
use TheSchwartz;

# mark a list of gpicids to be checked for deletion
# this inserts a schwartz job
sub gpicid_delete
{
    my @gpicids = @_;
    return undef unless @gpicids;

    my $sclient = LJ::theschwartz();
    return 0 unless $sclient;

    my $job = TheSchwartz::Job->new_from_array("LJ::Worker::PurgeGpics", [ @gpicids ]);

    my $h = $sclient->insert($job);
    return $h;
}


sub find_equal_gpicid
{
    my ($md5, $length, $fmtid, $verify_paths) = @_;

    # mysql removes spaces from the right of  binary values,
    # so we'll do the same to match db values ending in one
    # or more 0x20s
    my $md5pack = FB::hex_to_bin($md5);
    $md5pack =~ s/\x20+$//;

    my $gdbr = FB::get_db_reader();

    my $gpicid = $gdbr->selectrow_array(qq{
        SELECT gpicid FROM gpic WHERE
            md5sum=? AND
            bytes=? AND
            fmtid=?
        }, undef, $md5pack, $length, $fmtid);

    # accept a flag to let callers ask us to verify that the gpic
    # has data verified to be existing on disk.  useful for when
    # this function is called to see if an upload should use an
    # existing gpic
    if ($gpicid && $verify_paths) {
        my $gpic = FB::Gpic->load($gpicid);
        return undef unless $gpic && $gpic->paths;
    }

    return $gpicid;
}

sub get_gpic_md5_multi
{
    my ($gpicids, $opts) = @_;
    return undef unless ref $gpicids eq 'ARRAY';
    return () unless @$gpicids;
    $opts = {} unless ref $opts eq 'HASH';

    my %ret = ();
    my $in = join(",", map { $_ + 0 } @$gpicids);

    my $db = $opts->{force} ? FB::get_db_writer() : FB::get_db_reader();
    return FB::error("Unable to connect to global database") unless $db;

    my $sth = $db->prepare("SELECT gpicid, md5sum FROM gpic WHERE gpicid IN ($in)");
    $sth->execute;
    return FB::error($db) if $db->err;

    while (my ($gpicid, $md5sum) = $sth->fetchrow_array) {
        $ret{$gpicid} = $md5sum;
    }

    return \%ret;
}


1;
