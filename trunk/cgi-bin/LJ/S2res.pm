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
    my ($class, $u, $picid) = @_;
    my $up;

    # return existing one, if loaded
    if (my $us = $singletons{$u->{userid}}) {
        return $up if $up = $us->{$picid};
    }

    $up = $class->_skeleton($u, $picid);
    $singletons{$u->{userid}}->{$picid} = $up;
    return $up;
}
*new = \&instance;

sub _skeleton {
    my ($class, $u, $picid) = @_;
    # starts out as a skeleton and gets loaded in over time, as needed:
    return bless {
        userid => $u->{userid},
        picid  => int($picid),
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

sub load_user_userpics {
    my ($class, $u) = @_;
    local $LJ::THROW_ERRORS = 1;
    my @ret;

    # select all of their userpics and iterate through them
    my $sth;
    $sth = $u->prepare("SELECT userid, picid, width, height, state, fmt, comment, location " .
                       "FROM s2styleres WHERE userid=?");
    $sth->execute($u->{'userid'});
    while (my $rec = $sth->fetchrow_hashref) {
        # ignore anything expunged
        next if $rec->{state} eq 'X';
        push @ret, LJ::S2res->new_from_row($rec);
    }
    return @ret;
}

# FIXME: XXX: NOT YET FINISHED
sub create {
    my ($class, $u, %opts) = @_;
    local $LJ::THROW_ERRORS = 1;

    my $dataref = delete $opts{'data'};
    my $filename = delete $opts{'filename'};
    my $maxbytesize = delete $opts{'maxbytesize'};
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
    
    # not checking for byte size - code removed
    #

    unless ($filetype eq "GIF" || $filetype eq "JPG" || $filetype eq "PNG") {
        push @errors, LJ::errobj("Userpic::FileType",
                                 type => $filetype);
        $fmterror = 1;
    }

    # not checking for image size - code removed
    #

    LJ::throw(@errors);

    my $base64 = Digest::SHA1::sha1_base64($$dataref);

    my $target;
    if ($u->{dversion} > 6 && $LJ::S2res_MOGILEFS) {
        $target = 'mogile';
    } elsif ($LJ::S2res_BLOBSERVER) {
        $target = 'blob';
    }

    my $dbh = LJ::get_db_writer();

    # see if it's a duplicate, return it if it is
    if (my $dup_up = LJ::S2res->new_from_sha1($u, $base64)) {
        return $dup_up;
    }

    # start making a new onew
    my $resid = LJ::alloc_global_counter('R');

    my $contenttype;
    if (LJ::S2res->userpics_partitioned($u)) {
        $contenttype = {
            'GIF' => 'G',
            'PNG' => 'P',
            'JPG' => 'J',
        }->{$filetype};
    } else {
        $contenttype = {
            'GIF' => 'image/gif',
            'PNG' => 'image/png',
            'JPG' => 'image/jpeg',
        }->{$filetype};
    }

    @errors = (); # TEMP: FIXME: remove... using exceptions

    my $dberr = 0;
    
#     # allocation
#     my $rv = $dbh->do("INSERT IGNORE INTO s2res SET sha1hex=?", undef, $sha1hex)
#     if ($rv) {
#        $resid = $dbh->{mysql_insertid};
#     } else {
#        $resid = $dbh->selectrow_array("SELECT resid FROM s2res WHERE sha1hex=?",
#                                       undef, $sha1hex);
#     }
    
#     CREATE TABLE s2styleres (
#        userid INT UNSIGNED NOT NULL,
#        styleid INT UNSIGNED NOT NULL,
#        filename VARCHAR(50) NOT NULL,
#        resid INT UNSIGNED NOT NULL,
#        PRIMARY KEY (userid, styleid, filename)
#     );
#     
#     # global table
#     CREATE TABLE s2res (
#        resid INT UNSIGNED NOT NULL PRIMARY KEY,
#        sha1hex VARCHAR(32) NOT NULL,
#        KEY (sha1hex)
#     );

    my $styleid = 1; #get style id for user.
    $u->do("INSERT INTO s2styleres (userid, styleid, filename, resid)".
            "VALUES (?, ?, ?, ?)",
           undef, $u->{'userid'}, $styleid, $filename, $resid);
    if ($u->err) {
        push @errors, $err->($u->errstr);
        $dberr = 1;
    }

    my $clean_err = sub {
        $u->do("DELETE FROM s2styleres WHERE userid=? AND styleid=? AND filename=?",
               undef, $u->{'userid'}, $styleid, $filename) if ($styleid && $filename);
        return $err->(@_);
    };

    ### insert the resource
    if (!$dberr) {
        my $fh = LJ::mogclient()->new_file($u->mogfs_userpic_key($resid), 's2res');
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
        my $dmid = LJ::get_blob_domainid('userpic');
        $u->do("INSERT INTO s2res (resid, sha1hex) ".
               "VALUES (?, ?)", undef, $resid, $base64);

    } else {
        push @errors, "Database error?  Dying";
    }

    LJ::throw(@errors);

    # now that we've created a new pic, invalidate the user's memcached userpic info
    LJ::S2res->delete_cache($u);

    my $upic = LJ::S2res->new($u, $resid) or die "Error insantiating S2 resource";
    LJ::Event::NewUserpic->new($upic)->fire unless $LJ::DISABLED{esn};

    return $upic;
}

sub delete_cache {
    my ($class, $u) = @_;
    my $memkey = [$u->{'userid'},"upicinf:$u->{'userid'}"];
    LJ::MemCache::delete($memkey);
    $memkey = [$u->{'userid'},"upiccom:$u->{'userid'}"];
    LJ::MemCache::delete($memkey);
    $memkey = [$u->{'userid'},"upicurl:$u->{'userid'}"];
    LJ::MemCache::delete($memkey);

    # clear process cache
    $LJ::CACHE_USERPIC_INFO{$u->{'userid'}} = undef;
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
    my $picid = $self->id;

    # delete meta-data first so it doesn't get stranded if errors
    # between this and deleting row
    $u->do("DELETE FROM userblob WHERE journalid=? AND blobid=? " .
           "AND domain=?", undef, $u->{'userid'}, $picid,
           LJ::get_blob_domainid('userpic'));
    $fail->() if $@;

    # userpic keywords
    if (LJ::S2res->userpics_partitioned($u)) {
        eval {
            $u->do("DELETE FROM userpicmap2 WHERE userid=? " .
                   "AND picid=?", undef, $u->{userid}, $picid) or die;
            $u->do("DELETE FROM userpic2 WHERE picid=? AND userid=?",
                   undef, $picid, $u->{'userid'}) or die;
            };
    } else {
        eval {
            my $dbh = LJ::get_db_writer();
            $dbh->do("DELETE FROM userpicmap WHERE userid=? " .
                 "AND picid=?", undef, $u->{userid}, $picid) or die;
            $dbh->do("DELETE FROM userpic WHERE picid=?", undef, $picid) or die;
        };
    }
    $fail->() if $@;

    # best-effort on deleteing the blobs
    # TODO: we could fire warnings if they fail, then if $LJ::DIE_ON_WARN is set,
    # the ->warn methods on errobjs are actually dies.
    eval {
        if ($self->location eq 'mogile') {
            LJ::mogclient()->delete($u->mogfs_userpic_key($picid));
        } elsif ($LJ::S2res_BLOBSERVER &&
                 LJ::Blob::delete($u, "userpic", $self->extension, $picid)) {
        } elsif ($u->do("DELETE FROM userpicblob2 WHERE ".
                        "userid=? AND picid=?", undef,
                        $u->{userid}, $picid) > 0) {
        }
    };

    LJ::S2res->delete_cache($u);

    return 1;
}

sub set_fullurl {
    my ($self, $url) = @_;
    my $u = $self->owner;
    return 0 unless LJ::S2res->userpics_partitioned($u);
    $u->do("UPDATE userpic2 SET url=? WHERE userid=? AND picid=?",
           undef, $url, $u->{'userid'}, $self->id);
    $self->{url} = $url;

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
