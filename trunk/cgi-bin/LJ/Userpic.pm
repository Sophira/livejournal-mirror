package LJ::Userpic;
use strict;
use Carp qw(croak);
use Digest::MD5;

my %MimeTypeMap = (
                   'image/gif'  => 'gif',
                   'G'          => 'gif',
                   'image/jpeg' => 'jpg',
                   'J'          => 'jpg',
                   'image/png'  => 'png',
                   'P'          => 'png',
                   );

my %singletons;  # userid -> picid -> LJ::Userpic

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

# given a md5sum, load a userpic
# takes $u, $md5sum (base64)
# TODO: croak if md5sum is wrong number of bytes
sub new_from_md5 {
    my ($class, $u, $md5sum) = @_;
    die unless $u && length($md5sum) == 22;

    my $sth;
    if (LJ::Userpic->userpics_partitioned($u)) {
        $sth = $u->prepare("SELECT * FROM userpic2 WHERE userid=? " .
                           "AND md5base64=?");
    } else {
        my $dbr = LJ::get_db_reader();
        $sth = $dbr->prepare("SELECT * FROM userpic WHERE userid=? " .
                             "AND md5base64=?");
    }
    $sth->execute($u->{'userid'}, $md5sum);
    my $row = $sth->fetchrow_hashref
        or return undef;
    return LJ::Userpic->new_from_row($row);
}

sub new_from_row {
    my ($class, $row) = @_;
    die unless $row && $row->{userid} && $row->{picid};
    my $self = LJ::Userpic->new(LJ::load_userid($row->{userid}), $row->{picid});
    $self->absorb_row($row);
    return $self;
}

sub new_from_keyword
{
    my ($class, $u, $kw) = @_;

    my $picid = LJ::get_picid_from_keyword($u, $kw) or
        return undef;

    return $class->new($u, $picid);
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

sub inactive {
    my $self = shift;
    return $self->state eq 'I';
}

sub state {
    my $self = shift;
    return $self->{state} if defined $self->{state};
    $self->load_row;
    return $self->{state};
}

sub comment {
    my $self = shift;
    return $self->{comment} if exists $self->{comment};
    $self->load_row;
    return $self->{comment};
}

sub width {
    my $self = shift;
    my @dims = $self->dimensions;
    return undef unless @dims;
    return $dims[0];
}

sub height {
    my $self = shift;
    my @dims = $self->dimensions;
    return undef unless @dims;
    return $dims[0];
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

# returns (width, height)
sub dimensions {
    my $self = shift;

    # width and height probably loaded from DB
    return ($self->{width}, $self->{height}) if ($self->{width} && $self->{height});

    my %upics;
    my $u = LJ::load_userid($self->{userid});
    LJ::load_userpics(\%upics, [ $u, $self->{picid} ]);
    my $up = $upics{$self->{picid}} or
        return ();

    return ($up->{width}, $up->{height});
}

sub max_allowed_bytes {
    my ($class, $u) = @_;
    return 40960;
}

sub owner {
    my $self = shift;
    return LJ::load_userid($self->{userid});
}

sub url {
    my $self = shift;
    return "$LJ::USERPIC_ROOT/$self->{picid}/$self->{userid}";
}

sub fullurl {
    my $self = shift;
    return $self->{url} if $self->{url};
    $self->load_row;
    return $self->{url};
}

# in scalar context returns comma-seperated list of keywords or "pic#12345" if no keywords defined
# in list context returns list of keywords ( (pic#12345) if none defined )
# opts: 'raw' = return '' instead of 'pic#12345'
sub keywords {
    my $self = shift;
    my %opts = @_;

    my $raw = delete $opts{raw} || undef;

    croak "Invalid opts passed to LJ::Userpic::keywords" if keys %opts;

    my $picinfo = LJ::get_userpic_info($self->{userid}, {load_comments => 0});

    # $picinfo is a hashref of userpic data
    # keywords are stored in the "kw" field in the format keyword => {hash of some picture info}

    # create a hash of picids => keywords
    my $keywords = {};
    foreach my $keyword (keys %{$picinfo->{kw}}) {
        my $picid = $picinfo->{kw}->{$keyword}->{picid};
        $keywords->{$picid} = [] unless $keywords->{$picid};
        push @{$keywords->{$picid}}, $keyword if ($keyword && $picid);
    }

    # return keywords for this picid
    my @pickeywords = $keywords->{$self->id} ? @{$keywords->{$self->id}} : ();

    if (wantarray) {
        # if list context return the array
        return ($raw ? ('') : ("pic#" . $self->id)) unless @pickeywords;

        return @pickeywords;
    } else {
        # if scalar context return comma-seperated list of keywords, or "pic#12345" if no keywords
        return ($raw ? '' : "pic#" . $self->id) unless @pickeywords;

        return join(', ', sort @pickeywords);
    }
}

sub imagedata {
    my $self = shift;

    my %upics;
    my $u = $self->owner;
    LJ::load_userpics(\%upics, [ $u, $self->{picid} ]);
    my $pic = $upics{$self->{picid}} or
        return undef;

    return undef if $pic->{'userid'} != $self->{userid} || $pic->{state} eq 'X';

    if ($pic->{location} eq "M") {
        my $key = $u->mogfs_userpic_key( $self->{picid} );
        my $data = LJ::mogclient()->get_file_data( $key );
        return $$data;
    }

    my %MimeTypeMap = (
                       'image/gif' => 'gif',
                       'image/jpeg' => 'jpg',
                       'image/png' => 'png',
                       );
    my %MimeTypeMapd6 = (
                         'G' => 'gif',
                         'J' => 'jpg',
                         'P' => 'png',
                         );

    my $data;
    if ($LJ::USERPIC_BLOBSERVER) {
        my $fmt = ($u->{'dversion'} > 6) ? $MimeTypeMapd6{ $pic->{fmt} } : $MimeTypeMap{ $pic->{contenttype} };
        $data = LJ::Blob::get($u, "userpic", $fmt, $self->{picid});
        return $data if $data;
    }

    my $dbb = LJ::get_cluster_reader($u)
        or return undef;

    $data = $dbb->selectrow_array("SELECT imagedata FROM userpicblob2 WHERE ".
                                  "userid=? AND picid=?", undef, $self->{userid},
                                  $self->{picid});
    return undef;
}

# does the user's dataversion support userpic comments?
sub supports_comments {
    my $self = shift;

    my $u = $self->owner;
    return $u->{dversion} > 6;
}

# class method
# does this user's dataversion support usepic comments?
sub userpics_partitioned {
    my ($class, $u) = @_;
    Carp::croak("Not a valid \$u object") unless LJ::isu($u);
    return $u->{dversion} > 6;
}
*user_supports_comments = \&userpics_partitioned;

# TODO: add in lazy peer loading here
sub load_row {
    my $self = shift;
    my $u = $self->owner;
    my $row;
    if (LJ::Userpic->userpics_partitioned($u)) {
        $row = $u->selectrow_hashref("SELECT userid, picid, width, height, state, fmt, comment, location, url " .
                                     "FROM userpic2 WHERE userid=? AND picid=?", undef,
                                     $u->{userid}, $self->{picid});
    } else {
        my $dbr = LJ::get_db_reader();
        $row = $dbr->selectrow_hashref("SELECT userid, picid, width, height, state, contenttype " .
                                       "FROM userpic WHERE userid=? AND picid=?", undef,
                                       $u->{userid}, $self->{picid});
    }
    $self->absorb_row($row);
}

sub load_user_userpics {
    my ($class, $u) = @_;
    local $LJ::THROW_ERRORS = 1;
    my @ret;

    # select all of their userpics and iterate through them
    my $sth;
    if ($u->{'dversion'} > 6) {
        $sth = $u->prepare("SELECT userid, picid, width, height, state, fmt, comment, location " .
                           "FROM userpic2 WHERE userid=?");
    } else {
        my $dbh = LJ::get_db_writer();
        $sth = $dbh->prepare("SELECT userid, picid, width, height, state, contenttype " .
                             "FROM userpic WHERE userid=?");
    }
    $sth->execute($u->{'userid'});
    while (my $rec = $sth->fetchrow_hashref) {
        # ignore anything expunged
        next if $rec->{state} eq 'X';
        push @ret, LJ::Userpic->new_from_row($rec);
    }
    return @ret;
}

# FIXME: XXX: NOT YET FINISHED
sub create {
    my ($class, $u, %opts) = @_;
    local $LJ::THROW_ERRORS = 1;

    my $dataref = delete $opts{'data'};
    croak("dataref not a scalarref") unless ref $dataref eq 'SCALAR';

    croak("Unknown options: " . join(", ", scalar keys %opts)) if %opts;

    my $err = sub {
        my $msg = shift;
    };

    eval "use Image::Size;";
    my ($w, $h, $filetype) = Image::Size::imgsize($dataref);
    my $MAX_UPLOAD = LJ::Userpic->max_allowed_bytes($u);

    my $size = length $$dataref;

    my $fmterror = 0;

    my @errors;
    if ($size > $MAX_UPLOAD) {
        push @errors, LJ::errobj("Userpic::Bytesize",
                                 size => $size,
                                 max  => $MAX_UPLOAD);
    }

    unless ($filetype eq "GIF" || $filetype eq "JPG" || $filetype eq "PNG") {
        push @errors, LJ::errobj("Userpic::FileType",
                                 type => $filetype);
        $fmterror = 1;
    }

    # don't throw a dimensions error if it's the wrong file type because its dimensions will always
    # be 0x0
    unless ($w >= 1 && $w <= 100 && $h >= 1 && $h <= 100) {
        push @errors, LJ::errobj("Userpic::Dimensions",
                                 w => $w, h => $h) unless $fmterror;
    }

    LJ::throw(@errors);

    my $base64 = Digest::MD5::md5_base64($$dataref);

    my $target;
    if ($u->{dversion} > 6 && $LJ::USERPIC_MOGILEFS) {
        $target = 'mogile';
    } elsif ($LJ::USERPIC_BLOBSERVER) {
        $target = 'blob';
    }

    my $dbh = LJ::get_db_writer();

    # see if it's a duplicate, return it if it is
    if (my $dup_up = LJ::Userpic->new_from_md5($u, $base64)) {
        return $dup_up;
    }

    # start making a new onew
    my $picid = LJ::alloc_global_counter('P');

    my $contenttype;
    if (LJ::Userpic->userpics_partitioned($u)) {
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
    if ($u->{'dversion'} > 6) {
        $u->do("INSERT INTO userpic2 (picid, userid, fmt, width, height, " .
               "picdate, md5base64, location) VALUES (?, ?, ?, ?, ?, NOW(), ?, ?)",
               undef, $picid, $u->{'userid'}, $contenttype, $w, $h, $base64, $target);
        if ($u->err) {
            push @errors, $err->($u->errstr);
            $dberr = 1;
        }
    } else {
        $dbh->do("INSERT INTO userpic (picid, userid, contenttype, width, height, " .
                 "picdate, md5base64) VALUES (?, ?, ?, ?, ?, NOW(), ?)",
                 undef, $picid, $u->{'userid'}, $contenttype, $w, $h, $base64);
        if ($dbh->err) {
            push @errors, $err->($dbh->errstr);
            $dberr = 1;
        }
    }

    my $clean_err = sub {
        if ($u->{'dversion'} > 6) {
            $u->do("DELETE FROM userpic2 WHERE userid=? AND picid=?",
                   undef, $u->{'userid'}, $picid) if $picid;
        } else {
            $dbh->do("DELETE FROM userpic WHERE picid=?", undef, $picid) if $picid;
        }
        return $err->(@_);
    };

    ### insert the blob
    if ($target eq 'mogile' && !$dberr) {
        my $fh = LJ::mogclient()->new_file($u->mogfs_userpic_key($picid), 'userpics');
        if (defined $fh) {
            $fh->print($$dataref);
            my $rv = $fh->close;
            push @errors, $clean_err->("Error saving to storage server: $@") unless $rv;
        } else {
            # fatal error, we couldn't get a filehandle to use
            push @errors, $clean_err->("Unable to contact storage server.  Your picture has not been saved.");
        }
    } elsif ($target eq 'blob' && !$dberr) {
        my $et;
        my $fmt = lc($filetype);
        my $rv = LJ::Blob::put($u, "userpic", $fmt, $picid, $$dataref, \$et);
        push @errors, $clean_err->("Error saving to media server: $et") unless $rv;
    } elsif (!$dberr) {
        my $dbcm = LJ::get_cluster_master($u);
        return $err->($BML::ML{'error.nodb'}) unless $dbcm;
        $u->do("INSERT INTO userpicblob2 (userid, picid, imagedata) " .
               "VALUES (?, ?, ?)",
               undef, $u->{'userid'}, $picid, $$dataref);
        push @errors, $clean_err->($u->errstr) if $u->err;
    } else { # We should never get here!
        push @errors, "User picture uploading failed for unknown reason";
    }

    LJ::throw(@errors);

    # now that we've created a new pic, invalidate the user's memcached userpic info
    LJ::Userpic->delete_cache($u);

    return LJ::Userpic->new($u, $picid);
}

# make this picture the default
sub make_default {
    my $self = shift;
    my $u = $self->owner
        or die;

    LJ::update_user($u, { defaultpicid => $self->id });
    $u->{'defaultpicid'} = $self->id;
}

# returns true if this picture if the default userpic
sub is_default {
    my $self = shift;
    my $u = $self->owner;

    return $u->{'defaultpicid'} == $self->id;
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
    if (LJ::Userpic->userpics_partitioned($u)) {
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
        } elsif ($LJ::USERPIC_BLOBSERVER &&
                 LJ::Blob::delete($u, "userpic", $self->extensions, $picid)) {
        } elsif ($u->do("DELETE FROM userpicblob2 WHERE ".
                        "userid=? AND picid=?", undef,
                        $u->{userid}, $picid) > 0) {
        }
    };

    LJ::Userpic->delete_cache($u);

    return 1;
}

sub set_comment {
    my ($self, $comment) = @_;
    local $LJ::THROW_ERRORS = 1;

    my $u = $self->owner;
    return 0 unless LJ::Userpic->user_supports_comments($u);
    $comment = LJ::text_trim($comment, LJ::BMAX_UPIC_COMMENT(), LJ::CMAX_UPIC_COMMENT());
    $u->do("UPDATE userpic2 SET comment=? WHERE userid=? AND picid=?",
                  undef, $comment, $u->{'userid'}, $self->id)
        or die;
    $self->{comment} = $comment;

    my $memkey = [$u->{'userid'},"upiccom:$u->{'userid'}"];
    LJ::MemCache::delete($memkey);
    return 1;
}

# instance method:  takes a string of comma-separate keywords, or an array of keywords
sub set_keywords {
    my $self = shift;

    my @keywords;
    if (@_ > 1) {
        @keywords = @_;
    } else {
        @keywords = split(',', $_[0]);
    }
    @keywords = grep { !/^pic\#\d+$/ } grep { s/^\s+//; s/\s+$//; $_; } @keywords;

    my $u = $self->owner;
    my $sth;
    my $dbh;

    if (LJ::Userpic->userpics_partitioned($u)) {
        $sth = $u->prepare("SELECT kwid FROM userpicmap2 WHERE userid=? AND picid=?");
    } else {
        $dbh = LJ::get_db_writer();
        $sth = $dbh->prepare("SELECT kwid FROM userpicmap WHERE userid=? AND picid=?");
    }
    $sth->execute($u->{'userid'}, $self->id);

    my %exist_kwids;
    while (my ($kwid) = $sth->fetchrow_array) {
        $exist_kwids{$kwid} = 1;
    }

    my (@bind, @data, @kw_errors);
    my $c = 0;
    my $picid = $self->{picid};

    foreach my $kw (@keywords) {
        my $kwid = (LJ::Userpic->userpics_partitioned($u)) ? LJ::get_keyword_id($u, $kw) : LJ::get_keyword_id($kw);
        next unless $kwid; # TODO: fire some warning that keyword was bogus

        if (++$c > $LJ::MAX_USERPIC_KEYWORDS) {
            push @kw_errors, $kw;
            next;
        }

        unless (delete $exist_kwids{$kwid}) {
            push @bind, '(?, ?, ?)';
            push @data, $u->{'userid'}, $kwid, $picid;
        }
    }

    LJ::Userpic->delete_cache($u);

    foreach my $kwid (keys %exist_kwids) {
        $u->do("DELETE FROM userpicmap2 WHERE userid=? AND picid=? AND kwid=?", undef, $u->{userid}, $self->id, $kwid);
    }

    # save data if any
    if (scalar @data) {
        my $bind = join(',', @bind);

        if (LJ::Userpic->userpics_partitioned($u)) {
            return $u->do("REPLACE INTO userpicmap2 (userid, kwid, picid) VALUES $bind",
                          undef, @data);
        } else {
            return $dbh->do("INSERT INTO userpicmap (userid, kwid, picid) VALUES $bind",
                            undef, @data);
        }
    }

    # Let the user know about any we didn't save
    # don't throw until the end or nothing will be saved!
    if (@kw_errors) {
        my $num_words = scalar(@kw_errors);
        LJ::errobj("Userpic::TooManyKeywords",
                   userpic => $self,
                   lost    => \@kw_errors)->throw;
    }

    return 1;
}

sub set_fullurl {
    my ($self, $url) = @_;
    my $u = $self->owner;
    return 0 unless LJ::Userpic->userpics_partitioned($u);
    $u->do("UPDATE userpic2 SET url=? WHERE userid=? AND picid=?",
           undef, $url, $u->{'userid'}, $self->id);
    $self->{url} = $url;

    return 1;
}

####
# error classes:

package LJ::Error::Userpic::TooManyKeywords;

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

package LJ::Error::Userpic::Bytesize;
sub user_caused { 1 }
sub fields      { qw(size max); }
sub as_html {
    my $self = shift;
    return BML::ml('/editpics.bml.error.filetoolarge',
                   { 'maxsize' => $self->{'max'} .
                         BML::ml('/editpics.bml.kilobytes')} );
}

package LJ::Error::Userpic::Dimensions;
sub user_caused { 1 }
sub fields      { qw(w h); }
sub as_html {
    my $self = shift;
    return BML::ml('/editpics.bml.error.imagetoolarge', {
        imagesize => $self->{'w'} . 'x' . $self->{'h'}
        });
}

package LJ::Error::Userpic::FileType;
sub user_caused { 1 }
sub fields      { qw(type); }
sub as_html {
    my $self = shift;
    return BML::ml("/editpics.bml.error.unsupportedtype",
                          { 'filetype' => $self->{'type'} });
}

package LJ::Error::Userpic::DeleteFailed;
sub user_caused { 0 }

1;
