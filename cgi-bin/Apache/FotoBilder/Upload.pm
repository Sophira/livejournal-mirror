#!/usr/bin/perl
#

package Apache::FotoBilder::Upload;

use strict;
use Apache::Constants qw(:common REDIRECT FORBIDDEN HTTP_NOT_MODIFIED
                         HTTP_MOVED_PERMANENTLY HTTP_METHOD_NOT_ALLOWED
                         M_PUT HTTP_BAD_REQUEST
                         );

sub handler
{
    my $r = shift;
    unless ($r->method_number == M_PUT) {
        $r->allowed(1 << M_PUT);
        return HTTP_METHOD_NOT_ALLOWED;
    }

    my $bad_req = sub {
        $r->status(HTTP_BAD_REQUEST);
        $r->header_out("Content-length", length $_[0]);
        $r->send_http_header();
        $r->print($_[0]);
        return OK;
    };

    my $server_error = sub {
        my $err = shift;
        $r->status(SERVER_ERROR);
        $r->log_error("FotoBilder::Upload: $err");
        my $text = "Server Error: $err";
        $r->header_out("Content-length", length $text);
        $r->send_http_header();
        $r->print($text);
        return OK;
    };

    my $forbidden = sub {
        $r->status(FORBIDDEN);
        $r->header_out("Content-length", length $_[0]);
        $r->send_http_header();
        $r->print($_[0]);
        return OK;
    };

    my $user = $r->header_in("X-FB-Username");
    return $bad_req->("No username") unless defined $user;

    $user = FB::canonical_username($user);
    return $bad_req->("Bogus username") unless defined $user;

    my $dmid = FB::current_domain_id();
    my $u = FB::load_user($user, $dmid, { create => 1, validate => 1 });
    return $bad_req->("Unknown user") if ! $u || $u->{statusvis} =~ /[DX]/;

    return $forbidden->("Account status does not allow upload")
        unless FB::get_cap($u, "can_upload") && $u->{statusvis} eq 'V';

    my $meta_filename = FB::durl($r->header_in("X-FB-Meta-Filename"));

    my $make_chal = $r->header_in("X-FB-MakeChallenge");
    my $get_gals = $r->header_in("X-FB-GetGalleries");
    my $get_groups = $r->header_in("X-FB-GetSecGroups");

    my $give_new_chal = sub {
        if ($make_chal) {
            my $chal = $u->generate_challenge;
            $r->header_out("X-FB-NewChallenge", $chal);
        }
    };

    my $length = $r->header_in("Content-Length");

    # if they're just starting an upload session, they only want a challenge,
    # and aren't actually uploading.
    if ($make_chal && ! $length) {
        $give_new_chal->();
        $r->content_type("text/html; charset=utf-8");
        $r->send_http_header();
        $r->print("challenge sent.");
        return OK;
    }

    return $bad_req->("Invalid credentials")
        unless FB::check_auth($u, $r->header_in("X-FB-Auth"));

    # returning the gallery list
    if ($get_gals) {
        my $hdrs = $r->headers_out;
        my %gal;

        my $gals = $u->galleries;  # hashref (gallid -> Gal)

        foreach my $g (values %$gals) {
            next if $g->is_unsorted;
            $gal{$g->id} = $g;

            my $rec = {
                "id", $g->id,
                "name", $g->raw_name,
                "sec", $g->secid,
                "code" => FB::make_code($g->id, $g->randauth),
                "dategal" => $g->date,
                "timeupdate" => FB::date_unix_to_mysql($g->timeupdate_unix),
            };

            my $header = join("&",
                              map { FB::eurl($_) . "=" . FB::eurl($rec->{$_}) }
                              keys %$rec);
            $hdrs->add("X-FB-Gallery", $header);
        }

        # gallery relations
        my $sth = $u->prepare("SELECT gallid AS 'from', gallid2 AS 'to', type, sortorder ".
                              "FROM galleryrel WHERE userid=? AND type='C'",
                              $u->{userid});
        $sth->execute;

        # load into memory, so we can send back sanitized sort orders
        my %rel;
        while (my $g = $sth->fetchrow_hashref) {
            $rel{$g->{'from'}}->{$g->{'to'}} = $g;
        }

        foreach my $fid (keys %rel) {
            my $sortorder = 0;
            next unless $fid == 0 || $gal{$fid};
            foreach my $tid (sort { $rel{$fid}->{$a}->{'sortorder'} <=> $rel{$fid}->{$b}->{'sortorder'}  ||
                                    $gal{$a}->raw_name cmp $gal{$b}->raw_name  }
                             grep { $gal{$_} } keys %{$rel{$fid}})
            {
                my $rel = $rel{$fid}->{$tid};
                $rel->{'sortorder'} = ++$sortorder;
                my $header = join("&",
                                  map { FB::eurl($_) . "=" . FB::eurl($rel->{$_}) }
                                  keys %$rel);
                $hdrs->add("X-FB-GalleryRel", $header);
            }
        }
    }

    # return security groups
    if ($get_groups) {
        my $hdrs = $r->headers_out;
        my $sth = $u->prepare("SELECT secid, grpname FROM secgroups WHERE ".
                              "userid=? ORDER BY grpname", $u->{userid});
        $sth->execute;
        while (my ($id, $name) = $sth->fetchrow_array) {
            $hdrs->add("X-FB-SecGroup", "secid=${id}&name=" . FB::eurl($name));
        }
    }

    if (($get_gals || $get_groups) && ! $length) {
        $r->content_type("text/html; charset=utf-8");
        $r->send_http_header();
        $r->print("data sent.");
        return OK;
    }

    my $md5 = lc($r->header_in("X-FB-MD5"));
    my $magic = lc($r->header_in("X-FB-Magic"));
    my $picsec = $r->header_in("X-FB-Security");
    $picsec = defined $picsec ? $picsec+0 : 255;

    return $bad_req->("Missing or invalid Content-Length header")
        unless ($length =~ /^\d+$/ && $length);

    return $bad_req->("Missing or invalid X-FB-MD5 header")
        unless ($md5 =~ /^[a-f0-9]{32,32}$/);

    return $bad_req->("Missing or invalid X-FB-Magic header")
        unless (length($magic) % 2 == 0 && length($magic) >= 20 &&
                $magic !~ /[^a-f0-9]/);

    $magic =~ s/(\w\w)/chr hex $1/eg;
    my $fmtid = FB::fmtid_from_magic($magic);

    return $bad_req->("Unknown format") unless $fmtid;

    # which galleries to add picture to?
    my @galleries;
    foreach ($r->headers_in->get("X-FB-Gallery")) {
        foreach (split(/\s*\,\s*/, $_)) {
            my %gt;
            FB::decode_url_args($_, \%gt);

            return $bad_req->("Can't specify both 'name' and 'gallid' in X-FB-Gallery header.")
                if defined $gt{'name'} && $gt{'gallid'};

            return $bad_req->("Must specify either 'name' or 'gallid' in X-FB-Gallery header.")
                unless defined $gt{'name'} || $gt{'gallid'};

            # check security levels. (function turns undefs into '0')
            return $bad_req->("Invalid gallery security value")
                if defined $gt{'galsec'} && ! FB::valid_security_value($u, \$gt{'galsec'});

            # specify gallery by ID: maximum of one.
            if ($gt{'gallid'}) {
                my $gal = $u->load_gallery_id($gt{'gallid'})
                    or return $bad_req->("Specified galleryid ($gt{'gallid'}) doesn't exist");
                push @galleries, $gal;
                next;
            }

            my $sth;

            # given a path from the top
            if ($gt{'name'} =~ /\0/) {
                my $pid = 0;  # top level
                my @path = split(/\0/, $gt{'name'});
                my $gal;
                while (@path) {
                    my $name = shift @path;
                    $sth = $u->prepare("SELECT g.* FROM gallery g, galleryrel gr ".
                                       "WHERE g.userid=? AND g.name=? AND gr.userid=g.userid ".
                                       "AND gr.gallid2=g.gallid AND gr.gallid=? AND gr.type='C' ".
                                       "ORDER BY gr.sortorder LIMIT 1",
                                       $u->{'userid'}, $name, $pid);
                    $sth->execute;
                    my $galrow = $sth->fetchrow_hashref;
                    if ($galrow) {
                        $gal = FB::Gallery->from_gallery_row($u, $galrow);
                    } else {
                        $gal = FB::Gallery->create($u, name => $name, secid => $gt{'galsec'}+0);
                        if ($gal) {
                            $gal->link_from($pid);
                            if (@path == 0) { # final directory?
                                $gal->set_date($gt{'galdate'});
                            }
                        }
                    }
                    unless ($gal) {
                        my $err = FB::last_error();
                        return $server_error->("Couldn't create gallery: $err");
                    }
                    $pid = $gal->id;
                }
                push @galleries, $gal;
                next;
            }

            # specify gallery by name: could be many.  optionally filter on parentid.
            my @gals;
            if ($gt{'parentid'}) {
                $sth = $u->prepare("SELECT g.* FROM gallery g, galleryrel gr ".
                                   "WHERE g.userid=? AND g.name=? AND gr.userid=g.userid ".
                                   "AND gr.gallid2=g.gallid AND gr.gallid=? AND gr.type='C'",
                                   $u->{'userid'}, $gt{'name'}, $gt{'parentid'});
                $sth->execute;
            } else {
                $sth = $u->prepare("SELECT * FROM gallery WHERE userid=? AND name=?",
                                   $u->{'userid'}, $gt{'name'});
                $sth->execute;
            }
            while (my $galrow = $sth->fetchrow_hashref) {
                my $g = FB::Gallery->from_gallery_row($u, $galrow)
                    or die;
                push @gals, $g;
            }

            # make a gallery if we haven't found one
            unless (@gals) {
                my $gal = FB::Gallery->create($u,
                                              name => $gt{'name'},
                                              secid => $gt{'galsec'}+0
                                              );
                unless ($gal) {
                    my $err = FB::last_error();
                    return $server_error->("Couldn't create gallery: $err");
                }

                $gal->link_from($gt{'parentid'}+0);
                $gal->set_date($gt{'galdate'}) if $gt{'galdate'};
                push @gals, $gal;
            }

            push @galleries, @gals;
        }
    }

    # internally, a minimum of one gallery.  use ":FB_in" which means
    # "unsorted" or "incoming" or something equivalent in user's native language.
    # and everything is private by default.
    push @galleries, $u->incoming_gallery unless @galleries;

    # call hook to check if user has disk space for picture before uploading
    my $Kibfree = FB::run_hook("disk_remaining", $u);
    if (defined $Kibfree) {
        return $bad_req->("No disk space remaining for your account.")
            if $Kibfree <= 0;
        return $bad_req->("Not enough disk space remaining on your account for this picture.")
            if $Kibfree < $length>>10;
    }

    # need to get an existing gpic, or start making one.
    my $gpic = undef;
    if (my $gpicid = FB::find_equal_gpicid($md5, $length, $fmtid, 'verify_paths')) {
        eval { $gpic = FB::Gpic->load($gpicid) };
        return $server_error("Unable to load existing gpic: $@") if $@;
    }

    # now we map that gpic to a upic, and add it to specified gallery:
    my $make_upic = sub {
        my $gpic = shift;
        my $opts = shift || {};
        my $gpicid = $gpic->{gpicid};

        my $pre_existing = 0;
        my $up = FB::Upic->create($u, $gpicid,
                                  secid => $picsec,
                                  exist_flag => \$pre_existing);
        return $server_error->("Couldn't generate upic: $@")
            unless $up;

        # extract exif information if necessary
        if ($up->fmtid == FB::fmtid_from_ext('jpg')) {
            # data will be cached from our appends
            $up->exif_header($gpic->data);
        }

        my $handle_dup_after_rotate = sub {
            my $exist_upicid = shift;
            # delete the one we'd been working with,
            # and keep working with the original one
            $up->delete;
            $up  = FB::Upic->new($u, $exist_upicid);
        };
        $up->add_event_listener("set_gpic_failed_dup", $handle_dup_after_rotate);

        # auto-rotate it (which might fire a dup event)
        my $ai = $up->autorotate;

        my $upicid = $up->id;

        # set meta-data
        $up->set_text_prop('filename', $meta_filename) if $meta_filename;

        # add to galleries
        foreach my $g (@galleries) {
            $g->add_picture($up);
        }

        unless ($pre_existing) {
            # call hook again to check if user has disk space for picture
            # AFTER uploading (rather than try to hold some sort of lock over
            # some indefinite period of time)
            my $Kibfree = FB::run_hook("disk_remaining", $u);
            if (defined $Kibfree && $Kibfree < 0) {
                # need to delete this picture now because apparently two pics
                # were uploading at once.
                $up->delete;
                return $bad_req->("Not enough disk space remaining on your account for this picture.");
            }
        }

        # make a smaller version to make thumbnail generation quicker later.
        if ($opts->{makesmaller}) {
            # load the scaled version, creating unless necessary... just to make sure it's there
            eval { $gpic->load_scaled(640, 640, { create => 1 }) };
            return $bad_req->("Unable to scale Gpic: $@") if $@;
        }

        my $urlpic = $up->url_full;

        my $text = "OK\nupicid: $upicid\nURL: $urlpic\n";
        my $size = length $text;

        $give_new_chal->();
        $r->content_type("text/html; charset=utf-8");
        $r->header_out("X-FB-PicID", $upicid);
        $r->header_out("Content-length", $size);
        $r->send_http_header();
        $r->print($text);
        return OK;
    };

    my $ffid = $gpic ? $gpic->{gpicid} : "nonoone";

    # we found an existing matching picture
    return $make_upic->($gpic) if $gpic;

    # guess it's globally new.  allocate a gpic and start reading it.
    eval { $gpic = FB::Gpic->new( fmtid => $fmtid ) };
    return $server_error->("Couldn't allocate a gpicid: $@") unless $gpic;

    # NOTE: For the next few lines of code we'll be doing a potentially very slow
    #       read from the end user, appending data to the filehandle contained in
    #       the $gpic object.  At this point we can consider our database handles
    #       to be no longer valid since they will likely have timed out.  Luckily,
    #       the gpic_append function doesn't need a database work, so we can just
    #       assume all of the db handles to be dead at this point and revalidate
    #       them after the slow read is done.

    my $buff;
    my $got = 0;
    my $nextread = 4096;
    $r->soft_timeout("FotoBilder::Upload");
    while ($got <= $length && (my $lastsize = $r->read_client_block($buff, $nextread))) {
        $r->reset_timeout;
        $got += $lastsize;
        $gpic->append($buff);
        if ($length - $got < 4096) { $nextread = $length - $got; }
    }
    $r->kill_timeout;

    # END SLOW-NESS

    # revalidate database handles
    $FB::DBIRole->clear_req_cache();

    # verify its size
    if ($got != $length) {
        $gpic->discard;
        return $bad_req->("Size of data received does not match declared size.");
    }

    # verify its signature
    my $actual_md5 = $gpic->md5_hex;
    if ($md5 ne $actual_md5) {
        $gpic->discard;
        return $bad_req->("Data sent does not match MD5: got=$got you=$md5 saw=$actual_md5");
    }

    eval { $gpic->save };
    return $server_error->($@) if $@;

    my $opts = {};

    # make a smaller version to make thumbnail generation quicker later.
    $opts->{'makesmaller'} = 1 if
        ! $FB::NO_UPLOAD_PRESCALING && ($gpic->{width} > 640 || $gpic->{height} > 640);

    return $make_upic->($gpic, $opts);
}

1;

