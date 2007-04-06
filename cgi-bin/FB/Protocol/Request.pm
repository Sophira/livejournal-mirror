#!/usr/bin/perl

package FB::Protocol::Request;

use strict;

BEGIN {
    use fields qw(r vars var_spool);
    use vars qw(%VAR_TEMPLATE %CANONICAL_MAP);

    use Apache::BML;

    # prototype for what is valid to be returned
    %VAR_TEMPLATE = (
                     User => undef,
                     Mode => undef,
                     Auth => undef,
                     AuthVerifier => undef,
                     GetChallenge => undef,
                     GetGals      => undef,
                     GetGalsTree  => undef,
                     GetPics      => undef,
                     GetSecGroups => undef,

                     GetChallenges => {
                         Qty => undef,
                     },
                     Login => {
                         ClientVersion => undef,
                     },
                     CreateGals => {
                         Gallery => [
                                     {
                                         GalName  => undef,
                                         Path     => [],
                                         ParentID => undef,
                                         GalSec   => undef,
                                         GalDate  => undef,
                                     },
                                     ],
                     },
                     UploadPrepare => {
                         Pic => [
                                 {
                                     MD5  => undef,
                                     Magic => undef,
                                     Size  => undef,
                                 }
                                ],
                     },
                     UploadTempFile => {
                         ImageData   => undef,
                         ImageLength => undef
                     },
                     UploadPic => {
                         Receipt     => undef,
                         ImageData   => undef,
                         ImageLength => undef,
                         MD5         => undef,
                         PicSec      => undef,
                         Gallery => [
                                     {
                                         GalName  => undef,
                                         Path     => [],
                                         GalID    => undef,
                                         ParentID => undef,
                                         GalSec   => undef,
                                         GalDate  => undef,
                                     }
                                     ],
                         Meta => {
                             Filename    => undef,
                             Title       => undef,
                             Description => undef,
                         },
                     },
                     );

    # build up %CANONICAL_MAP
    {
        my $recurse;
        $recurse = sub {
            my $hash = shift;
            $hash = $hash->[0] if ref $hash eq 'ARRAY';
            return unless ref $hash eq 'HASH';

            foreach (keys %$hash) {
                $CANONICAL_MAP{lc($_)} = $_;
                $recurse->($hash->{$_});
            }
        };
        $recurse->(\%VAR_TEMPLATE);
    }
}

################################################################################
# Constructor
#

sub new {
    my FB::Protocol::Request $self = shift;

    $self = fields::new($self)
        unless ref $self;

    $self->{r} = undef;
    $self->{vars} = {};
    $self->{var_spool} = {};

    my %args = @_;
    while (my ($field, $val) = each %args) {
        $self->{$field} = $val;
    }

    return _err(500 => "Constructor requires 'r' (Apache::Request) argument")
        unless $self->{r};
    return _err(500 => "'r' argument is not a valid Apache request_rec object")
        unless ref $self->{r} eq 'Apache';

    return $self;
}


################################################################################
# Public Methods
#

sub read_vars {
    my FB::Protocol::Request $self = shift;
    my @sources = @_;

    # source types and their readers
    my @map = (
               [ headers     => "_read_header_vars" ],
               [ get         => "_read_get_vars" ],
               [ post_mime   => "_read_post_mime_vars" ],
               [ post_urlenc => "_read_post_urlenc_vars" ],
               [ put         => "_read_put_data" ],
               );

    # read all specified sources, all if unspecified
    foreach my $src (@map) {
        if (! @sources || grep { $_ eq $src->[0] } @sources) {
            no strict 'refs';
            return undef unless $src->[1]->($self);
        }
    }

    # auto-fill [Mode.]ImageLength and [Mode.]ImageData
    {
        my $sp = $self->{var_spool};
    
        # now we have the "Mode" var in our spool, swap _ImageData to be its child
        my $dataname = $sp->{Mode} ? "$sp->{Mode}.ImageData" : "ImageData";
        if ($sp->{_ImageData}) {
            $sp->{$dataname} = $sp->{_ImageData};
            delete $sp->{_ImageData};
        }

        # if there was ImageData, we'll auto-fill [Mode.]ImageLength with the
        # length of the read data, if the user didn't specify it
        my $lenname = $sp->{Mode} ? "$sp->{Mode}.ImageLength" : "ImageLength";
        if (ref $sp->{$dataname} && ! defined $sp->{$lenname}) {
            $sp->{$lenname} = $sp->{$dataname}->{bytes}+0;
        }
    }

    # now we have a var_spool, need to add the values into the actual tree
    foreach (_key_sort($self->{var_spool})) {
        $self->set_var($_, $self->{var_spool}->{$_})
            or return undef; # $@ will propogate from below
    }

    return 1;
}

sub add_var {
    my FB::Protocol::Request $self = shift;

    $self->{var_spool}->{$_[0]} = $_[1];
    return 1;
}

sub get_var {
    my FB::Protocol::Request $self = shift;
    my $key = shift;

    my $vars_curr = $self->{vars};
    my @parts = split(/\./, $key);
    foreach my $idx (0..$#parts) {
        my $part_curr = $parts[$idx];

        if ($idx == $#parts) {
            return $vars_curr->{$part_curr} if ref $vars_curr eq 'HASH';
            return $vars_curr->[$part_curr] if ref $vars_curr eq 'ARRAY';
            return undef;
        }

        # don't advance if we'll be stepping to the final node,
        # we need to stay one back for dereferencing of the value
        next if $idx == $#parts - 1;

        $vars_curr = $vars_curr->{$part_curr} if ref $vars_curr eq 'HASH';
        $vars_curr = $vars_curr->[$part_curr] if ref $vars_curr eq 'ARRAY';
    }

    return undef;
}

sub set_var {
    my FB::Protocol::Request $self = shift;
    my ($key, $val) = @_;

    # get the "empty" value for a type of data (hashref, arrayref, scalar)
    my $empty_val = sub {
        return {} if ref $_[0] eq 'HASH';
        return ref $_[0]->[0] eq 'HASH' ? {} : ref $_[0]->[0] eq 'ARRAY' ? [] : undef
            if ref $_[0] eq 'ARRAY';
        return undef
    };

    # set a key on either an arrayref or hashref without caring which it is
    my $set_key = sub {
        return $_[0]->{$_[1]} = $_[2] if ref $_[0] eq 'HASH'  && $_[1] =~ /^\D/;
        return $_[0]->[$_[1]] = $_[2] if ref $_[0] eq 'ARRAY' && $_[1] =~ /^\d+$/;
        return undef;
    };

    my $tmpl_prev = undef;
    my $tmpl_curr = \%VAR_TEMPLATE;
    my $vars_prev = undef;
    my $vars_curr = $self->{vars};

    my @parts = split(/\./, $key);
    foreach my $idx (0..$#parts) {
        my $part_prev = $idx > 0 ? $parts[$idx-1] : undef;
        my $part_curr = $parts[$idx];

        # stop condition: if last element, we're setting a value
        if ($idx == $#parts) {

            # instantiate an array
            if ($part_curr eq '_size') {

                return _err("Can't declare array size on non-array" => $key)
                    unless ref $tmpl_curr eq 'ARRAY';

                return _err("Invalid array size" => $key)
                    unless $val == int($val);

                return _err("Array size out of bounds" => $key)
                    unless $val > 0 && $val < 1000;

                # instantiate 'empty' array of given size
                return $set_key->($vars_prev, $part_prev, [ map { $empty_val->($tmpl_curr) } 1..$val ]);
            }

            # integers are array index
            if ($part_curr =~ /^\d+$/) {
                return _err("Can't set array index on non-array" => $key)
                    unless ref $vars_curr eq 'ARRAY';
                return _err("Array index out of range: $part_curr" => $key)
                    unless exists $vars_curr->[$part_curr];

                return $vars_curr->[$part_curr] = $val;


            }

            # everything else is a hashref
            return _err("Can't set key on non-struct" => $key)
                unless ref $vars_curr eq 'HASH';
            
            return _err(210 => $key) # invalid argument
                unless exists $tmpl_curr->{$part_curr};

            # set the final value
            $vars_curr->{$part_curr} = $val;
            return 1;

        }

        # otherwise: traversing a level deeper

        # array index
        if ($part_curr =~ /^\d+$/) {

            # should this element be an array at all?
            return _err("Can't traverse down non-array by array index" => $key)
                unless ref $tmpl_curr eq 'ARRAY';

            # if so, has it been instantiated by the user?
            return _err("Can't traverse down uninstantiated array" => $key)
                unless ref $vars_curr eq 'ARRAY';

            # are we within the bounds of the array?
            return _err("Array index out of range: $part_curr" => $key)
                unless exists $vars_curr->[$part_curr];

            # traversing down, is the next element supposed to be
            # a destination value of a hashref?
            $vars_curr->[$part_curr] ||= $empty_val->($vars_curr->[$part_curr]);
                
            # update prev/curr template nodes
            $tmpl_prev = $tmpl_curr;
            $tmpl_curr = $tmpl_curr->[0];

            # update prev/curr var nodes
            $vars_prev = $vars_curr;
            $vars_curr = $vars_curr->[$part_curr];

            next;
        }

        # hash key
        return _err("Can't traverse down non-struct by key" => $key)
            unless ref $tmpl_curr eq 'HASH';

        return _err(210 => $key) # invalid argument
            unless exists $tmpl_curr->{$part_curr};

        # traversing down, is the next element supposed to be
        # a destination value of a hashref?
        $vars_curr->{$part_curr} ||= $empty_val->($tmpl_curr->{$part_curr});

        # update prev/curr template nodes
        $tmpl_prev = $tmpl_curr;
        $tmpl_curr = $tmpl_curr->{$part_curr};

        # update prev/curr var nodes
        $vars_prev = $vars_curr;
        $vars_curr = $vars_curr->{$part_curr};

        next;
    }
}


################################################################################
# Private Methods
#

sub _err {
    my @err = ref $_[0] eq 'ARRAY' ? @{$_[0]} : @_;
    @err = grep { s/\s*$// } @err; # kill newlines from die "$@\n";
    unshift @err, 201 unless $err[0] =~ /^\d{3}$/;
    $@ = \@err; 
    return undef;
}

# sorting to make sure _size, etc gets interpretted first
sub _key_sort { 
    return sort { 
        $a =~ tr/\./\./ <=> $b =~ tr/\./\./ ||
        $b =~ /\.\_/ <=> $a =~ /\.\_/
    } keys %{$_[0]};

}


################################################################################
# Methods for reading vars from data sources
#

sub _hook_err {
    # in normal error cases, we call _err which populates $@ with an arrayref
    # the problem comes when we have to die and overwrite the $@ in a hook
    # 
    # so inside hooks we'll always die _hook_err($@) which will serialize
    # the arrayref for later expansion
    return (ref $_[0] eq 'ARRAY' ? join(': ', @{$_[0]}) : $_[0]) . "\n";
}

sub _canonical_var {
    my $key = shift;

    # Perl's LWP library converts header portions like "_size" into "-Size"
    # The behavior can be turned off my adding a ":" prefix to the header name,
    # but that is only available in the latest versions of LWP.
    # -- As a hack, we'll just convert (\.-[A-Z]) into (\._[a-z])
    $key =~ s/\.-([a-zA-Z])/'._' . lc($1)/eg;

    return join('.', map { $CANONICAL_MAP{$_} ? $CANONICAL_MAP{$_} : $_ } split(/\./, lc($key)));
}

sub _read_header_vars {
    my FB::Protocol::Request $self = shift;    

    my $r = $self->{r};
    my %headers = $r->headers_in;

    my $ct = 0;
    while (my ($key, $val) = each %headers) {
        next unless $key =~ /^X-FB-(.+)$/i;
        my $var = _canonical_var($1);

        return _err("Too many variables in HTTP headers" => "limit 25")
            if $ct >= 25;

        return _err("Cannot send ImageData via HTTP Header")
            if (split(/\./, $key))[-1] eq 'ImageData';

        $self->add_var($var => $val) or return _err(@{$@});

        $ct++;
    }

    return 1;
}

sub _read_get_vars {
    my FB::Protocol::Request $self = shift;

    my $r = $self->{r};
    my %args = $r->args;
    while (my ($key, $val) = each %args) {
        return _err("Cannot send ImageData via GET")
            if (split(/\./, $key))[-1] eq 'ImageData';

        $self->add_var($key => $val) or return _err(@{$@});
    }

    return 1;
}

sub _read_post_urlenc_vars {
    my FB::Protocol::Request $self = shift;

    my $r = $self->{r};
    my %args = $r->content;
    while (my ($key, $val) = each %args) {
        return _err("Cannot send ImageData via URL-Encoded POST")
            if (split(/\./, $key))[-1] eq 'ImageData';

        $self->add_var($key => $val) or return _err(@{$@});
    }

    return 1;
}

sub _read_post_mime_vars {
    my FB::Protocol::Request $self = shift;

    my $r = $self->{r};
    return 1 unless $r->method eq 'POST';
    return 1 unless $r->header_in('Content-Type') =~ m!^multipart/form-data!;

    # curr is a global for these 3 closures, it contains an arrayref: [varname => value]
    #
    # the value can be a hashref containing the following keys if the variable represents 
    # binary data: { spool_fh, spool_path, pclustertype, pclusterid, md5sum, fmtid, bytes }
    my $curr = [];

    # called when the beginning of an upload is encountered
    my $hook_newheaders = sub {
        my ($name) = @_;

        $curr = [$name => undef];
        
        # ImageData is a special variable.  it's the only one that can contain
        # a blob of image data
        return 1 unless (split(/\./, $name))[-1] eq 'ImageData';

        $curr->[1] = {};
        my $rec = $curr->[1];

        $self->_read_data_new($rec) or die _hook_err($@);

        return 1;
    };
    
    # called as data is received
    my $hook_data = sub {
        my ($len, $data) = @_;

        # check that we've not exceeded the max read limit
        my $max_read = (1<<20) * 30; # 30 MiB
        my $len_read = 0;

        # find total length of file so far
        if (ref $curr->[1]) {
            $len_read = ($curr->[1]->{bytes} += $len);
        } else {
            # in non-file case, append while we're at it
            $len_read = length($curr->[1] .= $data);
        }

        die _hook_err("Upload max exceeded at $len_read bytes")
            if $len_read > $max_read;

        return 1 unless ref $curr->[1];

        $self->_read_data_block($curr->[1], \$data) or die _hook_err($@);

        return 1;
    };
    
    # called when the end of an upload is encountered
    my $hook_enddata = sub {

        my $rec = $curr->[1];
        unless (ref $rec) {
            $self->add_var(@$curr) or die _hook_err($@);
            return 1;
        }

        # since we've just finished a potentially slow upload, we need to
        # make sure the database handles in DBI::Role's cache haven't expired,
        # so we'll just trigger a revalidation now so that subsequent database
        # calls will be safe.  note that this gets called after every file
        # is read from the request, so that gpic_new et al can be called
        # before the next uploaded file is processed
        $FB::DBIRole->clear_req_cache();

        # don't try to operate on 0-length spoolfiles
        unless ($rec->{bytes}) {
            $curr->[1] = undef;
            return 1;
        }

        $self->_read_data_end($rec) or die _hook_err($@);

        $self->add_var(@$curr) or die _hook_err($@);

        return 1;
    };
    
    # parse multipart-mime submission, one chunk at a time,
    # calling our hooks as we go to put uploads in temporary 
    # MogileFS filehandles
    my $errstr;
    my $res = BML::parse_multipart_interactive($r, \$errstr, {
        newheaders => $hook_newheaders,
        data       => $hook_data,
        enddata    => $hook_enddata,
    });

    # errors in hooks set $@ to a ':'-sep list via _hook_err rather
    # than a standard arrayref because they have to die on error
    # which will overwrite $@ unless it's ommitted, in which case
    # a warning is thrown.  hacky.
    unless ($res) {
        my @err = split(/\s*:\s*/, $errstr);
        my $errcode = shift(@err) if $err[0] =~ /^(\d+)$/;
        return _err("Couldn't parse upload" => @err)
            if ! $errcode || $errcode == 201;
        return _err($errcode => @err);
    }

    return 1;
}

sub _read_put_data {
    my FB::Protocol::Request $self = shift;

    my $r = $self->{r};
    return 1 unless $r->method eq 'PUT';
    return 1 unless my $length = $r->header_in("Content-Length");

    # Verify that the supplied ImageLength variable matches the Content-Length
    # header for this request.
    #
    # NOTE: We rely on the fact that _read_put_data is called after headers
    #       are read in from the request, meaning all supplied variables are
    #       already present in $self->{var_spool} (esp. Mode and Mode?.ImageLength)
    {
        my $sp = $self->{var_spool};
        my $varname = $sp->{Mode} ? "$sp->{Mode}.ImageLength" : "ImageLength";

        # Implicitly fill in _ImageLength with Content-Length.
        $sp->{$varname} = $length+0 unless defined $sp->{$varname};

        return _err("Content-Length does not match supplied ImageLength")
            unless $length == $sp->{$varname};
    }

    # NOTE: For the next few lines of code we'll be doing a potentially very slow
    #       read from the end user, appending data to the filehandle contained in
    #       the $gpic object.  At this point we can consider our database handles
    #       to be no longer valid since they will likely have timed out.  Luckily,
    #       the gpic_append function doesn't need a database work, so we can just
    #       assume all of the db handles to be dead at this point and revalidate
    #       them after the slow read is done.

    my $rec = {};
    $self->_read_data_new($rec) or return _err(@{$@});

    # check that we've not exceeded the max read limit
    my $max_read = (1<<20) * 30; # 30 MiB
    return _err(403 => "$length bytes")
        if $length > $max_read;
    
    my $buff;
    my $got = 0;
    my $nextread = 4096;
    $r->soft_timeout("FB::Protocol::Request");
    while ($got <= $length && (my $lastsize = $r->read_client_block($buff, $nextread))) {
        $r->reset_timeout;
        $got += $lastsize;

        return _err(403 => "$got bytes")
            if $got > $max_read;

        $self->_read_data_block($rec, \$buff);
        if ($length - $got < 4096) { $nextread = $length - $got; }
    }
    $r->kill_timeout;

    # note how much data we actually read
    $rec->{bytes} = $got;

    # END SLOW-NESS

    # revalidate database handles
    $FB::DBIRole->clear_req_cache();

    $self->_read_data_end($rec) or return _err(@{$@});

    # add as _ImageData, then we'll replace the "_" with 
    # Mode once we know we have it read in
    $self->add_var("_ImageData" => $rec)
        or return _err(@{$@});

    return 1;
}

################################################################################
# Helper functions for reading binary data to disk/MogileFS
#

sub _read_data_new {
    my FB::Protocol::Request $self = shift;
    my $rec = shift;

    # new file, need to create a filehandle, etc
    $rec->{md5ctx} = new Digest::MD5;
        
    # set pclusterid/pclustertype to be what we got from above
    ($rec->{pclustertype}, $rec->{pclusterid}) = FB::lookup_pcluster_dest();
    return _err(500 => "Couldn't determine pclustertype") unless $rec->{pclustertype};
    return _err(500 => "Couldn't determine pclusterid")   unless $rec->{pclusterid};

    # get MogileFS filehandle
    if ($rec->{pclustertype} eq 'mogilefs') {
        $rec->{spool_fh} = $FB::MogileFS->new_file
            or return _err(500 => "Failed to open MogileFS tempfile");

    # get handle to temporary file
    } else {

        my $r = $self->{r};
            
        my $clust_dir = "$FB::PIC_ROOT/$rec->{pclusterid}";
        my $spool_dir = "$clust_dir/spool";

        unless (-e $spool_dir) {
            mkdir $clust_dir, 0755;
            mkdir $spool_dir, 0755;
            unless (-e $spool_dir) {
                $r->log_error("Could not create spool directory (wrong permissions?)" => $spool_dir);
                return _err(500 => "Failed to find/create spool directory");
            }
        }

        ($rec->{spool_fh}, $rec->{spool_path}) = File::Temp::tempfile( "upload_XXXXX", DIR => $spool_dir);

        # add to pnotes so we can unlink all the temporary files later, regardless of error condition
        my $pnotes = $r->pnotes('tempfiles') || [];
        push @$pnotes, $rec->{spool_path};
        $r->pnotes('tempfiles' => $pnotes);
            
        return _err(500 => "Failed to open local tempfile" => $rec->{spool_path})
            unless $rec->{spool_fh} && $rec->{spool_path};
    }

    return 1;
}

sub _read_data_block {
    my FB::Protocol::Request $self = shift;
    my ($rec, $data) = @_;

    # append file data to tempfile
    $rec->{md5ctx}->add($$data);
    $rec->{spool_fh}->print($$data);

    return 1;
}

sub _read_data_end {
    my FB::Protocol::Request $self = shift;
    my $rec = shift;

    # read magic and try to determine formatid of uploaded file. This
    # doesn't use fh->tell and fh->seek because the filehandle is
    # sysopen()ed, so isn't really an IO::Seekable like an IO::File
    # filehandle would be.
    tell $rec->{spool_fh}
        or return _err(500 => "read offset is 0, empty file?");
    seek $rec->{spool_fh}, 0, 0;

    # $! should always be set in this case because a failed read will
    # always be an error, not EOF, which is handled above (tell)
    my $magic;
    $rec->{spool_fh}->read($magic, 20)
        or return _err(500 => "Couldn't read magic" => $!);

    $rec->{fmtid} = FB::fmtid_from_magic($magic);

    # finished adding data for md5, create digest (but don't destroy original)
    $rec->{md5sum} = $rec->{md5ctx}->digest;
    delete $rec->{md5ctx};

    return 1;
}

1;
