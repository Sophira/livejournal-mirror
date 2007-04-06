#!/usr/bin/perl

package FB::Protocol::UploadPic;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars}->{UploadPic};

    my $r = $req->{r};
    my $u = $resp->{u};

    my $err = sub {
        $resp->add_method_error(UploadPic => @_);
        return undef;
    };

    # is the user allowed to upload?
    return $err->(303)
        unless FB::get_cap($u, 'can_upload') && $u->{statusvis} eq 'V';

    # specifying two data sources makes no sense, error
    my $img = $vars->{ImageData};
    return $err->(201 => "Cannot specify both ImageData and Receipt")
        if $img && exists $vars->{Receipt};
    return $err->(201 => "Cannot specify both ImageLength and Receipt")
        if exists $vars->{ImageLength} && exists $vars->{Receipt};

    my $gpic;
    my ($fmtid, $length, $md5_hex);

    # are they supplying a receipt for their upload data?
    if (exists $vars->{Receipt}) {
        return $err->(211 => 'Receipt')
            unless $vars->{Receipt} =~ /^[a-zA-Z0-9]{20}$/;

        # expiration times for receipts
        my $rcpt_exp = {
            T => 60*15,   # 15 minutes for UploadTempFile
            P => 86400*3, # 3 days for UploadPrepare
        };

        # load the receipt and validate its age
        my $rcpt = FB::load_receipt($u, $vars->{Receipt});
        return $err->(211 => 'Receipt')
            unless defined $rcpt && ref $rcpt eq 'HASH';
        return $err->(211 => [ 'Receipt' => "Expired" ])
            unless $rcpt->{timecreate} > time() - $rcpt_exp->{$rcpt->{type}};

        # UploadPrepare receipt
        if ($rcpt->{type} eq 'P') {

            eval { $gpic = FB::Gpic->load($rcpt->{val}) };
            return $err->(500 => $@) if $@;

            # still have no gpic from receipt?
            return $err->(211 => 'Receipt')
                unless $gpic;

        # UploadTempFile receipt
        } elsif ($rcpt->{type} eq 'T') {

            my $inf = $rcpt->{val_hash};
            return $err->(211 => 'Receipt')
                unless ref $inf eq 'HASH';

            # construct a new $img hashref and populate with tempfile info
            $img = { map { $_ => $inf->{$_} }
                     qw(fmtid bytes md5sum pclustertype pclusterid) };

            # flag that this image really came from a receipt and not a user upload
            $img->{_from_rcpt} = 1;
            $img->{_rcpt_pathkey} = $inf->{pathkey};

            my $pathkey = $inf->{pathkey}
                or return $err->(211 => [ 'Receipt' => "No pathkey" ]);

            # mogilefs spool file
            if ($inf->{pclustertype} eq 'mogilefs') {

                # check formatting of pathkey
                return $err->(211 => [ 'Receipt' => "Invalid pathkey" ])
                    unless $pathkey =~ /^tmpfile:([a-zA-Z0-9]{20})$/ && $1 eq $rcpt->{rcptkey};

            # spool file
            } elsif ($inf->{pclustertype} eq 'disk') {

                # check formatting of pathkey
                return $err->(211 => [ 'Receipt' => "Invalid pathkey" ])
                    unless $pathkey =~ /^$FB::PIC_ROOT/;

            # unknown
            } else {
                return $err->(211 => [ 'Receipt' => "Unknown pclustertype" => $inf->{pclustertype} ]);
            }
        }
    }

    # so now we know that no receipt was specified, else we'd have a $gpic or error by now
    # error check data submission so we can attempt to create a new gpic later after the
    # rest of the request is error checked

    unless ($gpic) {

        # did they specify an ImageData variable?
        return $err->(212 => "ImageData")
            unless $img && ref $img eq 'HASH';

        # UploadTempFile receipts dont' require users to declare an ImageLength,
        # so we'll just swap in the size they uploaded for the TempFile as the
        # effective $length
        if ($img->{_from_rcpt}) {
            $length = $img->{bytes};

        # check the declared ImageLength
        } else {
            return $err->(212 => "ImageLength")
                unless exists $vars->{ImageLength};

            $length = $vars->{ImageLength};
        }

        return $err->(211 => "ImageLength")
            unless defined $length;

        # valid pclustertype / pclusterid
        return $err->(500 => "Could not determine pclustertype/id")
            unless $img->{pclustertype} && $img->{pclusterid};

        # did we count bytes?
        return $err->(213 => "No data sent")
            unless $img->{bytes};

        # did they match the declared length?
        return $err->(211 => "ImageLength does not match data length")
            unless $img->{bytes} == $length;

        # check that it's a valid fmtid
        $fmtid = $img->{fmtid};
        return $err->(213 => "Unknown format")
            unless $fmtid;

        # valid filehandle -- not applicable to $img from receipt
        return $err->(500 => "No spool filehandle")
            unless $img->{_from_rcpt} || $img->{spool_fh};

        # valid md5 sum?
        return $err->(500 => "Could not calculate MD5 sum")
            unless $img->{md5sum};

        # if an md5 is supplied, check that it matches the image's actual
        # calculated md5
        $md5_hex = FB::bin_to_hex($img->{md5sum});
        if ($vars->{MD5} && $vars->{MD5} ne $md5_hex) {
            return $err->(211 => "Supplied MD5 does not match data MD5");
        }
    }

    # check PicSec if specified
    my $picsec = exists $vars->{PicSec} ? $vars->{PicSec} : 255;
    return $err->(211 => "PicSec")
        unless defined $picsec && FB::valid_security_value($u, $picsec);

    # Meta information
    if (exists $vars->{Meta}) {
        my $meta = $vars->{Meta};
        return $err->(211 => "Meta")
            unless ref $meta eq 'HASH';

        foreach (qw(Filename Title Description)) {
            next unless exists $meta->{$_};
            return $err->(211 => "Meta-$_")
                unless defined $meta->{$_};

            # Description is a BLOB (2^16-1 bytes)
            my $maxlen = $_ eq 'Description' ? 65535 : 255;
            return $err->(211 => [ "Meta-$_" => "Too long, maximum length is $maxlen" ])
                if length($meta->{$_}) > $maxlen;
        }
    }

    # call hook to check if user has disk space for picture before uploading
    my $Kibfree = FB::run_hook("disk_remaining", $u);
    if (defined $Kibfree) {
        return $err->(401) if $Kibfree <= 0;
        return $err->(402) if $Kibfree < $length>>10;
    }

    # to which galleries should this picture be added?
    my @gals;
  GALLERY:
    foreach my $gvar (@{$vars->{Gallery}}) {

        # check for invalid argument interactions
        return $err->(211 => "Can't specify both GalName and GalID when adding to gallery")
            if exists $gvar->{GalName} && exists $gvar->{GalID};

        return $err->(212 => "Must specify either GalName or GalID when adding to gallery")
            unless exists $gvar->{GalName} || exists $gvar->{GalID};

        return $err->(211 => "Can't specify both ParentID and Path when adding to gallery")
            if exists $gvar->{ParentID} && exists $gvar->{Path};

        # check that GalSec was valid, if it was specified
        my $galsec = exists $gvar->{GalSec} ? $gvar->{GalSec} : 255;
        return $err->(211 => "Invalid GalSec value")
            unless defined $galsec && FB::valid_security_value($u, \$galsec);

        # check against existence of undefined values:
        foreach (qw(ParentID GalDate GalName)) {
            return $err->(211 => $_)
                if exists $gvar->{$_} && ! defined $gvar->{$_};
        }

        # check that ParentID was valid, if it was specified
        my $parentid = exists $gvar->{ParentID} ? $gvar->{ParentID} : 0;
        return $err->(211 => "ParentID must be a non-negative integer")
             if ! defined $parentid || $parentid =~ /\D/ || $parentid < 0;

        # check that GalDate was valid, if it was specified
        my $galdate = FB::date_from_user($gvar->{GalDate});
        return $err->(211 => "Malformed date: $galdate")
            if exists $gvar->{GalDate} && ! defined $galdate;

        # check GalName, as well as any names in @path
        my $galname = $gvar->{GalName};
        return $err->(211 => "Malformed gallery name: $galname")
            if defined $galname && ! FB::valid_gallery_name($galname);

        # check gallery names in Path
        my @path = @{$gvar->{Path}||[]};
        foreach (@path) {
            next if defined $_ && FB::valid_gallery_name($_);
            return $err->(211 => [ "Malformed gallery name in Path" => $galname ]);
        }

        # goal from here on is to find what gals this 'Gallery' struct refers to,
        # we'll push those to the @gals array and add the picture to each of them

        # simple if they've specified a gallid
        if (exists $gvar->{GalID}) {
            my $gallid = $gvar->{GalID};
            return $err->(211 => "GalID must be a positive integer")
                unless defined $gallid && $gallid =~ /^\d+$/ && $gallid > 0;

            my $gal = $u->load_gallery_id($gallid)
                or return $err->(211 => "Gallery '$gallid' does not exist");

            push @gals, $gal;
            next GALLERY;
        }

        # more complicated if specified by name, need to check / create
        # gallery based on GalName, Path and ParentID
        if ($galname) {

            my $udbh = FB::get_user_db_writer($u)
                or return $err->(501 => "Cluster $u->{clusterid}");

            # if a GalName was specified in conjunction with a path, it is a
            # special case and means that we should attempt to create galleries
            # down the path, starting at the root, then create a new gallery
            # (if it doesn't exist) of the given GalName at the end of the path
            if (@path) {

                # add GalName to the end of the path since it will be the final
                # destination gallery and follows the same rules for creation as
                # the rest of the path.
                push @path, $galname;

                my $pid = 0;
              PATH:
                while (@path) {
                    my $currname = shift @path;

                    # FIXME: pretty sure this could be further optimized

                    # see if the parent of the path thus far exists
                    my $galrow = $u->selectrow_hashref
                        ("SELECT g.* FROM gallery g, galleryrel gr ".
                         "WHERE g.userid=? AND g.name=? AND gr.userid=g.userid ".
                         "AND gr.gallid2=g.gallid AND gr.gallid=? AND gr.type='C' ".
                         "ORDER BY gr.sortorder LIMIT 1",
                         $u->{userid}, $currname, $pid);
                    return $err->(502) if $u->err;

                    my $gal;
                    # gal didn't exist, create and set that as parent
                    if ($galrow) {
                        $gal = FB::Gallery->from_gallery_row($u, $galrow)
                            or return $err->(512 => FB::last_error());
                    } else {
                        $gal = FB::Gallery->create($u, name => $currname, secid => $galsec)
                            or return $err->(512 => FB::last_error());
                        $gal->link_from($pid);
                        $gal->set_date($galdate) if @path == 0 && $galdate;
                    }

                    # if we've worn the path list completely away, we've found
                    # the target to add the picture to... it's the result of the
                    # traversal of @path from the root, then finding/creating
                    # GalName at the end of that traversal.
                    if (@path == 0) {
                        push @gals, $gal;
                        last PATH;
                    }

                    # parent is either the gallery we just looked up or the
                    # one we just created
                    $pid = $gal->id;
                    next PATH;
                }

                # move on to the next gallery record
                next GALLERY;
            }

            # if a name was specified with a ParentID, then add to galleries
            # named GalName that are also children of $parentid.  find those now.
            if ($parentid) {

                my $sth = $u->prepare
                    ("SELECT g.* FROM gallery g, galleryrel gr ".
                     "WHERE g.userid=? AND g.name=? AND gr.userid=g.userid ".
                     "AND gr.gallid2=g.gallid AND gr.gallid=? AND gr.type='C'",
                     $u->{userid}, $galname, $parentid);
                $sth->execute;
                return $err->(502) if $u->err;
                while (my $grow = $sth->fetchrow_hashref) {
                    my $gal = FB::Gallery->from_gallery_row($u, $grow) or die;
                    push @gals, $gal;
                }

                # gal didn't exist, create and set that as parent
                unless (@gals) {
                    my $gal = FB::Gallery->create($u, name => $galname, secid => $galsec)
                        or return $err->(512 => FB::last_error());
                    $gal->link_from($parentid);
                    push @gals, $gal;
                }

                next GALLERY;
            }

            # otherwise we have a GalName but no constraining parentid, so we just
            # add to any galleries having that name
            my $sth = $u->prepare("SELECT * FROM gallery WHERE userid=? AND name=?",
                                  $u->{userid}, $galname);
            $sth->execute;
            return $err->(502) if $udbh->err;
            while (my $grow = $sth->fetchrow_hashref) {
                my $gal = FB::Gallery->from_gallery_row($u, $grow) or die;
                push @gals, $gal;
            }

            # but if there were no galleries by this name, create a new one
            # under the root
            unless (grep { $_->{name} eq $galname } @gals) {
                my $newgal = FB::Gallery->create($u, name => $galname, secid => $galsec)
                    or return $err->(512 => FB::last_error());
                $newgal->link_from(0);
                $newgal->set_date($galdate) if $galdate;
                push @gals, $newgal;
            }

            next GALLERY;
        }

        # end processing of Gallery array
    }

    # internally, a minimum of one gallery.  use ":FB_in" which means
    # "unsorted" or "incoming" or something equivalent in user's native language.
    unless (@gals) {
        my $g = $u->incoming_gallery
            or return $err->(502 => "Cannot load incoming gallery");
        push @gals, $g;
    }

    # now we're finished with all input error checking, and we know that all the
    # destination galleries exist... time to start processing the data, either from
    # ImageData or from an upload receipt (tempfile or prepare)

    # already have a gpic if an existing one was specified via UploadPrepare receipt
    unless ($gpic) {

        # need to get an existing gpic, or start making one.

        if ( my $gpicid = FB::find_equal_gpicid($md5_hex, $length, $fmtid, 'verify_paths') ) {

            # found an existing gpic for this fingerprint
            $gpic = FB::Gpic->load($gpicid)
                or return $err->(500);

            # note that we could have TempFiles to clean up at this point,
            # in the case that the fingerprint above was that of a receipt
            # tempfile.  in any case, it will be cleaned up later.

        }

        # still no gpic?  time to create anew
        unless ($gpic) {

            # create a new gpic from $img hashref (defined and validated above)
            $gpic = FB::Gpic->new
                ( map { $_ => $img->{$_} } qw(pclustertype pclusterid md5sum fmtid bytes) )
                or return $err->(510 => $@);

            # errors from now until $gpic->save require the gpic to be discarded
            my $err_discard = sub {
                my $errcode = shift;
                my @errmsg = @_;

                # $gpic->discard will croak on err, catch it
                eval { $gpic->discard };
                push @errmsg, $@ if $@;

                return @errmsg ? $err->($errcode => \@errmsg) : $err->($errcode);
            };


            # swap in the spoolfile

            # see if we have image data from a UploadTempFile receipt, if so we need to
            # handle things a bit differently
            if ($img->{_from_rcpt}) {

                if ($img->{pclustertype} eq 'mogilefs') {

                    # rename the old TempFile MogileFS key for this to
                    # be a permanent one of the mogfs_key form
                    $FB::MogileFS->rename($img->{_rcpt_pathkey}, FB::Gpic::mogfs_key($gpic->{gpicid}))
                        or return $err_discard->(510 => "Unable to rename MogileFS temp file");

                } elsif ($img->{pclustertype} eq 'disk') {

                    # swap in (hard link) pathkey to the final gpic disk path via API
                    eval { $gpic->file_from_spool($img->{spool_fh}, $img->{_rcpt_pathkey}) };
                    return $err_discard->(510 => $@) if $@;

                } else {
                    return $err_discard->(510 => [ "Unknown pclustertype" => $img->{pclustertype} ]);
                }

            # otherwise we're working on a spool filehandle for data uploaded in
            # this request and collected in Request.pm
            } else {

                # swap in (hard link) pathkey to the final gpic disk path via API
                eval { $gpic->file_from_spool($img->{spool_fh}, $img->{spool_path}) };
                return $err_discard->(510 => $@) if $@;
            }

            # save gpic in database
            # 1) in case of all disk uploads, this only saves gpic row
            # 2) in case of mogilefs uploads not via receipt, this gives
            #    them a key and makes them permanent
            # 3) in case of mogilefs uploads via receipt, this only saves
            #    gpic row since mogilefs file already has a key (was renamed above)
            eval { $gpic->save };
            return $err_discard->(510 => $@) if $@;
        }

        # now need to clean up any receipt tempfiles that have now been made into
        # permanent gpics
        # -- but don't need to do this if it was a mogilefs TempFile, since
        #    we did a rename and there's nothing to delete. 'twould be redundant
        if ($img->{pclustertype} ne 'mogilefs' &&
            $img->{_from_rcpt} && $img->{_rcpt_pathkey}) {

            FB::clean_receipt_tempfile($img->{pclustertype}, $img->{_rcpt_pathkey})
                or return $err->(500 => FB::last_error());
        }

    }

    # definitely have a $gpic now, either from above or from an existing receipt
    return $err->(510) unless $gpic; # should never happen, but be safe

    # allocate new upic
    my $pre_existing = 0;
    my $up = FB::Upic->create($u, $gpic->{gpicid},
                              secid => $picsec,
                              exist_flag => \$pre_existing)
        or return $err->(511 => $@);

    # only need to re-check disk quota if the upic returned wasn't an
    # already existing and accounted for upic
    unless ($pre_existing) {
        # call hook again to check if user has disk space for picture
        # AFTER uploading (rather than try to hold some sort of lock over
        # some indefinite period of time)
        my $Kibfree = FB::run_hook("disk_remaining", $u);
        if (defined $Kibfree && $Kibfree < 0) {
            # need to delete this picture now because apparently two pics
            # were uploading at once.
            $up->delete;
            return $err->(401);
        }
    }

    # parse EXIF data from image and store it if necessary
    if ($up->fmtid == FB::fmtid_from_ext('jpg')) {
        $up->exif_header($gpic->data)
            or return $err->(511 => "Couldn't extract EXIF Header" => FB::last_error());
    }

    # auto-rotate picture
    {
        my $handle_dup = sub {
            my $exist_upicid = shift;
            # delete the one we'd been working with,
            # and keep working with the original one
            $up->delete;
            $up = FB::Upic->new($u, $exist_upicid);
        };
        $up->add_event_listener("set_gpic_failed_dup", $handle_dup);
        $up->autorotate;
        $up->remove_event_listener("set_gpic_failed_dup", $handle_dup);
    }


    if (! $FB::NO_UPLOAD_PRESCALING && ($gpic->{width} > 640 || $gpic->{height} > 640)) {
        # load the scaled version, creating unless necessary... just to make sure it's there
        eval { $gpic->load_scaled(640, 640, { create => 1 }) };
        return $err->(510 => [ "Unable to scale Gpic" => $@ ]) if $@;
    }

    # add to galleries
    foreach my $gal (@gals) {
        $gal->add_picture($up)
            or return $err->(513 => FB::last_error());
    }

    # Meta information
    # -- existence vs definition checked at top
    if (defined $vars->{Meta}) {
        my $meta = $vars->{Meta};

        # set upc props if they're present
        foreach ([Filename => 'filename'], [Title => 'pictitle']) {
            my $val = $meta->{$_->[0]};
            next unless defined $val;
            $up->set_text_prop($_->[1] => $val)
                or return $err->(511 => "Couldn't set $_->[0] prop");
        }

        # set picture description if it's present
        if (defined $meta->{Description}) {
            $up->set_des($meta->{Description})
                or return $err->(511 => [ "Couldn't set Description" => FB::last_error() ]);
        }
    }

    # register return value with parent Request
    $resp->add_method_vars(
                            UploadPic => {
                                PicID  => [ $up->id ],
                                URL    => [ $up->url_full ],
                                Width  => [ $up->width ],
                                Height => [ $up->height ],
                                Bytes  => [ $up->bytes ],
                            });

    return 1;
}

1;
