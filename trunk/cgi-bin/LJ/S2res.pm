package LJ::S2res;
use strict;
use Carp qw(croak);
use Digest::SHA1 qw(sha1_hex);

my %MimeTypeMap = (
                   'image/gif'  => 'gif',
                   'G'          => 'gif',
                   'image/jpeg' => 'jpg',
                   'J'          => 'jpg',
                   'image/png'  => 'png',
                   'P'          => 'png',
                   );

my %singletons;  # userid -> picid -> LJ::S2res

sub reset_singletons {
    %singletons = ();
}

sub instance {
    my ($class, $u, $resid) = @_;
    my $up;

    # return existing one, if loaded
    if (my $us = $singletons{$u->{userid}}) {
        return $up if $up = $us->{$resid};
    }

    $up = $class->_skeleton($u, $resid);
    $singletons{$u->{userid}}->{$resid} = $up;
    return $up;
}
*new = \&instance;

sub _skeleton {
    my ($class, $u, $resid) = @_;
    # starts out as a skeleton and gets loaded in over time, as needed:
    return bless {
        userid => $u->{userid},
        picid  => int($resid),
    };
}

# given a sha1sum, load a userpic
# takes $u, $sha1sum (base64)
# TODO: croak if sha1sum is wrong number of bytes
sub new_from_sha1 {
    my ($class, $u, $sha1sum) = @_;
    die unless $u && length($sha1sum) == 27;

    my $sth;
    $sth = $u->prepare("SELECT * FROM s2res WHERE sha1hex=?");
    $sth->execute($u->{'userid'}, $sha1sum);
    my $row = $sth->fetchrow_hashref
        or return undef;
    return LJ::S2res->new_from_row($row);
}

sub valid {
    my $self = shift;
    return defined $self->state;
}

sub new_from_row {
    my ($class, $row) = @_;
    die unless $row && $row->{userid} && $row->{picid};
    my $self = LJ::S2res->new(LJ::load_userid($row->{userid}), $row->{picid});
    $self->absorb_row($row);
    return $self;
}

sub absorb_row {
    my ($self, $row) = @_;
    for my $f (qw(userid picid width height comment location state url)) {
        $self->{$f} = $row->{$f};
    }
    $self->{_ext} = $MimeTypeMap{$row->{fmt} || $row->{contenttype}};
    return $self;
}

# accessors

sub id {
    return $_[0]->{picid};
}

sub extension {
    my $self = shift;
    return $self->{_ext} if $self->{_ext};
    $self->load_row;
    return $self->{_ext};
}

sub location {
    my $self = shift;
    return $self->{location} if $self->{location};
    $self->load_row;
    return $self->{location};
}

sub owner {
    my $self = shift;
    return LJ::load_userid($self->{userid});
}

sub url {
    my $self = shift;
    return "$LJ::S2res_ROOT/$self->{picid}/$self->{userid}";
}

sub fullurl {
    my $self = shift;
    return $self->{url} if $self->{url};
    $self->load_row;
    return $self->{url};
}

# returns an image tag of this image
sub imgtag {
    my $self = shift;
    return '<img src="' . $self->url . '" width=' . $self->width . ' height=' . $self->height .
        ' alt="' . LJ::ehtml(scalar $self->keywords) . '" />';
}

sub imagedata {
    my $self = shift;

    my %upics;
    my $u = $self->owner;
    LJ::load_userpics(\%upics, [ $u, $self->{picid} ]);
    my $pic = $upics{$self->{picid}} or
        return undef;

    return undef if $pic->{'userid'} != $self->{userid} || $pic->{state} eq 'X';

    #mogile only
    my $key = $u->mogfs_userpic_key( $self->{picid} );
    my $data = LJ::mogclient()->get_file_data( $key );
    return $$data;
}

# TODO: add in lazy peer loading here
sub load_row {
    my $self = shift;
    my $u = $self->owner;
    my $row;
    $row = $u->selectrow_hashref("SELECT userid, picid, width, height, state, fmt, comment, location, url " .
                                 "FROM s2styleres WHERE userid=? AND picid=?", undef,
                                 $u->{userid}, $self->{picid});
                                 
    $self->absorb_row($row);
}

# Set the styleids of things in s2styleres that belong to the user to 0.
# Called before we insert files.
sub backup {
    my ($class, $u, %opts) = @_;
    local $LJ::THROW_ERRORS = 1;
    
    $u->do("UPDATE s2styleres SET styleid=0 WHERE userid=?;", undef, $u->{'userid'});
    die $u->errstr if $u->err;
    
    return 1;
}

# Restore previous styleids from 0.  Plays well only with the assumtion that the
# previous CSS is restored as well... called in the event of an error while
# inserting files
sub restore {
    my ($class, $u, %opts) = @_;
    local $LJ::THROW_ERRORS = 1;
    
    my $styleid = $u->selectrow_array("SELECT styleid FROM s2styles "
            ."WHERE userid='".$u->{'userid'}."' AND name='wizard-voxish'");
    LJ::throw("Error in locating user's wizard-voxish style while recovering from an error!") unless ($styleid);
    
    $u->do("DELETE FROM s2styleres WHERE styleid!=0 AND userid=?", undef, $u->{'userid'});
    $u->do("UPDATE s2styleres SET styleid=? WHERE styleid=0 AND userid=?;",
           undef, $styleid, $u->{'userid'});
    die $u->errstr if $u->err;
    
    return 1;
}

# Delete all rows that belong to 0, and who's styleids have been zeroed.
# Called on successful insertion of all files.
sub cleanup {
    my ($class, $u, %opts) = @_;
    local $LJ::THROW_ERRORS = 1;
    
    $u->do("DELETE FROM s2styleres WHERE styleid=0 AND userid=?;", undef, $u->{'userid'});
    die $u->errstr if $u->err;
    
    return 1;
}

# Adds one file to the mogileFS and database.  File data and filename in %opts.
sub create {
    my ($class, $u, %opts) = @_;
    local $LJ::THROW_ERRORS = 1;

    my $dataref = delete $opts{'data'};
    my $filename = delete $opts{'filename'};
    croak("dataref not a scalarref") unless ref $dataref eq 'SCALAR';

    croak("Unknown options: " . join(", ", scalar keys %opts)) if %opts;

    my $err = sub {
        my $msg = shift;
    };

    #should just use magic numbers for this?  We don't need width/height.
    eval "use Image::Size;";
    my ($w, $h, $filetype) = Image::Size::imgsize($dataref);

    my $fmterror = 0;
    my @errors;

    unless ($filetype eq "GIF" || $filetype eq "JPG" || $filetype eq "PNG") {
        push @errors, "Unacceptable filetype caught in S2res->create.";
        $fmterror = 1;
    }
    
    my $styleid = $u->selectrow_array("SELECT styleid FROM s2styles "
            ."WHERE userid='".$u->{'userid'}."' AND name='wizard-voxish'");
    push @errors, "Error in locating user's wizard-voxish style!" unless ($styleid);

    LJ::throw(@errors);

    #set up everything we'll need later
    my $sha1hex = Digest::SHA1::sha1_hex($$dataref);
    my $lockkey = "s2res:$sha1hex";
    my $resid;


    @errors = (); # TEMP: FIXME: remove... using exceptions

    my $dberr = 0;
    my $dbh = LJ::get_db_writer();
    my $release_lock = sub { 
        LJ::release_lock($dbh, "global", $lockkey);
        return 1;
    };
    my $clean_err = sub {
        $u->do("DELETE FROM s2styleres WHERE userid=? AND styleid=? AND filename=?",
               undef, $u->{'userid'}, $styleid, $filename) if ($styleid && $filename);
        $release_lock->();
        return $err->(@_);
    };
    
    # get lock so other clients don't try to create a mogilefs
    #  file for this sha1...
    $release_lock->(); ## REMOVE ME!
    my $lock = LJ::get_lock($dbh, "global", $lockkey);
    unless ($lock) {
       # error unable to get lock...
       return undef; # this is probably bad - should return an error or something
    }
    
    # allocation
    my $rv = $dbh->do("INSERT IGNORE INTO s2res SET sha1hex=?", undef, $sha1hex);
    my $debug .= "SQL: INSERT IGNORE INTO s2res SET sha1hex=$sha1hex<BR>";
    
    # another client could have inserted into s2res while we waited 
    # for our lock, see if there is now a sha1 => resid mapping
    if ($rv) {
        $resid = $dbh->{'mysql_insertid'};

        ### insert the resource
        if ($resid) {
            my $fh = LJ::mogclient()->new_file("s2res:$resid", 's2res') or $clean_err->("MogileFS error: $@");
            $debug .= "MOG: new_file(\"s2res:$resid\", 's2res')<BR>";
            if (defined $fh) {
                $fh->print($$dataref);
                my $rv = $fh->close;
                push @errors, $clean_err->("Error saving to storage server: $@") unless $rv;
            } else {
                # fatal error, we couldn't get a filehandle to use
                push @errors, $clean_err->("Unable to contact storage server.  Your picture has not been saved.");
            }
    
            # even in the non-LJ::Blob case we use the userblob table as a means
            # to track the number and size of user blob assets
            my $dmid = LJ::get_blob_domainid('s2res');
            $u->do("INSERT INTO userblob (journalid, domain, blobid, length) ".
                   "VALUES (?, ?, ?, ?)", undef, $u->{userid}, $dmid, $resid, length($$dataref));
            $debug .= "SQL: INSERT INTO userblob (journalid, domain, blobid, length) ".
                   "VALUES (".$u->{userid}.", $dmid, $resid, ".length($$dataref)."<BR>";
    
        } else {
            $debug .= "\$resid not defined by mysql_insertid [$sha1hex]: ".$dbh->{'mysql_error'}."<BR>";
        }
    } else {
        $debug .= "\$rv not defined for INSERT [$sha1hex]: ".$dbh->{'mysql_error'}."<BR>";
    }
    
    # all successful - unlock
    $release_lock->();
    
    unless ($resid){
        $dbh = LJ::get_db_reader(); #possibly unnecessary?
        $resid = $dbh->selectrow_array("SELECT resid FROM s2res WHERE sha1hex='".$sha1hex."';");
        $debug .= "SQL: SELECT resid FROM s2res WHERE sha1hex='".$sha1hex."';<BR>";
        $debug .= LJ::D($dbh).LJ::D($resid);
        die $dbh->errstr if $dbh->err;
    }
    
    #LJ::throw("resid undefined! \n$debug") unless ($resid);
    
    $u->do("INSERT IGNORE INTO s2styleres (userid, styleid, filename, resid)".
           "VALUES (?, ?, ?, ?)",
           undef, $u->{'userid'}, $styleid, $filename, $resid);
    $debug .= "SQL: INSERT IGNORE INTO s2styleres (userid, styleid, filename, resid)".
           "VALUES (".$u->{userid}.", $styleid, $filename, $resid)<BR>";    
    
    if ($u->err) {
        push @errors, $err->($u->errstr);
        $dberr = 1;
    }

    LJ::throw(@errors);
    
    return $debug;

    my $upic = LJ::S2res->new($resid) or LJ::throw("Error insantiating S2 resource");

    return $upic;
}

sub imagedata {
    my ($self, $u, $styleid, $filename) = @_;
    local $LJ::THROW_ERRORS = 1;
    die "LJ::S2res->imagedata call missing user hash" unless ($u);
    die "LJ::S2res->imagedata call missing styleid" unless ($styleid);
    die "LJ::S2res->imagedata call missing filename" unless ($filename);
    
    my $resid = $u->selectrow_array("SELECT resid FROM s2styleres "
            ."WHERE userid=? AND styleid=? AND filename=?;", undef, $u->{userid}, $styleid, $filename);
    
    my $data = LJ::mogclient()->list_keys("s2res", 1);
    
    return "Mog Data dump:".LJ::D($data);
}

# delete this userpic
# TODO: error checking/throw errors on failure
sub delete {
    my $self = shift;
    local $LJ::THROW_ERRORS = 1;

    my $fail = sub {
        LJ::errobj("WithSubError",
                   main   => LJ::errobj("DeleteFailed"),
                   suberr => $@)->throw;
    };

    my $u = $self->owner;
    my $resid = $self->id;

    # delete meta-data first so it doesn't get stranded if errors
    # between this and deleting row
    $u->do("DELETE FROM userblob WHERE journalid=? AND blobid=? " .
           "AND domain=?", undef, $u->{'userid'}, $resid,
           LJ::get_blob_domainid('s2res'));
    $fail->() if $@;

    # userpic keywords
    if (LJ::S2res->userpics_partitioned($u)) {
        eval {
            $u->do("DELETE FROM userpicmap2 WHERE userid=? " .
                   "AND picid=?", undef, $u->{userid}, $resid) or die;
            $u->do("DELETE FROM userpic2 WHERE picid=? AND userid=?",
                   undef, $resid, $u->{'userid'}) or die;
            };
    } else {
        eval {
            my $dbh = LJ::get_db_writer();
            $dbh->do("DELETE FROM userpicmap WHERE userid=? " .
                 "AND picid=?", undef, $u->{userid}, $resid) or die;
            $dbh->do("DELETE FROM userpic WHERE picid=?", undef, $resid) or die;
        };
    }
    $fail->() if $@;

    # best-effort on deleting the blobs
    # TODO: we could fire warnings if they fail, then if $LJ::DIE_ON_WARN is set,
    # the ->warn methods on errobjs are actually dies.
    eval {
        if ($self->location eq 'mogile') {
            LJ::mogclient()->delete($u->mogfs_userpic_key($resid));
        } elsif ($LJ::S2res_BLOBSERVER &&
                 LJ::Blob::delete($u, "userpic", $self->extension, $resid)) {
        } elsif ($u->do("DELETE FROM userpicblob2 WHERE ".
                        "userid=? AND picid=?", undef,
                        $u->{userid}, $resid) > 0) {
        }
    };

    LJ::S2res->delete_cache($u);

    return 1;
}

####
# error classes:

package LJ::Error::S2res::TooManyKeywords;

sub user_caused { 1 }
sub fields      { qw(userpic lost); }

sub number_lost {
    my $self = shift;
    return scalar @{ $self->field("lost") };
}

sub lost_keywords_as_html {
    my $self = shift;
    return join(", ", map { LJ::ehtml($_) } @{ $self->field("lost") });
}

sub as_html {
    my $self = shift;
    my $num_words = $self->number_lost;
    return BML::ml("/editpics.bml.error.toomanykeywords", {
        numwords => $self->number_lost,
        words    => $self->lost_keywords_as_html,
        max      => $LJ::MAX_USERPIC_KEYWORDS,
    });
}

package LJ::Error::S2res::Bytesize;
sub user_caused { 1 }
sub fields      { qw(size max); }
sub as_html {
    my $self = shift;
    return BML::ml('/editpics.bml.error.filetoolarge',
                   { 'maxsize' => $self->{'max'} .
                         BML::ml('/editpics.bml.kilobytes')} );
}

package LJ::Error::S2res::Dimensions;
sub user_caused { 1 }
sub fields      { qw(w h); }
sub as_html {
    my $self = shift;
    return BML::ml('/editpics.bml.error.imagetoolarge', {
        imagesize => $self->{'w'} . 'x' . $self->{'h'}
        });
}

package LJ::Error::S2res::FileType;
sub user_caused { 1 }
sub fields      { qw(type); }
sub as_html {
    my $self = shift;
    return BML::ml("/editpics.bml.error.unsupportedtype",
                          { 'filetype' => $self->{'type'} });
}

package LJ::Error::S2res::DeleteFailed;
sub user_caused { 0 }

1;
