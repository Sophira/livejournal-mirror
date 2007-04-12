#!/usr/bin/perl
#

package Apache::FotoBilder::WebUpload;

use strict;
use Digest::MD5 ();
use Apache::Request;
use Apache::Constants qw(:common REDIRECT HTTP_METHOD_NOT_ALLOWED M_POST);

sub handler
{
    my $r = shift;
    unless ($r->method_number == M_POST) {
        $r->allowed(1 << M_POST);
        return HTTP_METHOD_NOT_ALLOWED;
    }

    BML::reset_cookies();   # since get_remote will need the new ones
    my $u = FB::User->remote;

    # if there is a failure during upic/gpic work, we need to back out
    # any partial changes/creations so the user wont' get errors or
    # half-working pictures later

    my %open_obj = (); # { 'gpic' => { gpicid => gpic }, 'upic' => { upicid => upic } }

    # discard open gpics
    my $discard_open = sub {
        my %gpics = %{$open_obj{gpic}||{}};
        FB::gpicid_delete(keys %gpics) if %gpics;
        foreach my $up (values %{$open_obj{upic}||{}}) {
            $up->delete;
        }
    };

    # mark a upic/gpic as open
    my $open = sub {
        my ($key, $id, $val) = @_;
        $open_obj{$key}->{$id} = $val;
    };

    # un-mark a upic/gpic as open
    my $close = sub {
        my ($key, $id) = @_;
        delete $open_obj{$key}->{$id};
    };

    my $bad_req = sub {
        $r->send_http_header('text/html');
        $r->print("<h1>Error</h1>");
        $r->print(join(": ", grep { defined $_ } @_));

        # any currently open, unsaved, gpics/upics need to be discarded
        $discard_open->();

        return OK;
    };

    my $server_error = sub {
        my $err = join(": ", grep { defined $_ && length($_) } @_);
        $r->status(SERVER_ERROR);
        $r->log_error("FotoBilder::WebUpload: $err");
        $r->send_http_header();
        $r->print("Server Error: $err");

        # any currently open, unsaved, gpics/upics need to be discarded
        $discard_open->();

        return OK;
    };

    return $bad_req->("Not logged in")
        if ! $u || $u->{statusvis} =~ /[DX]/;

    return $bad_req->("Account status does not allow upload")
        unless FB::get_cap($u, "can_upload") && $u->{statusvis} eq 'V';

    my %POST = ();
    my %uploads = (); # id => { gpicid, spool_fh, spool_path, filename, pclusterid,
                      #         pclustertype, bytes, md5sum, md5ctx }
    my ($curr_name, $totalsize);

    $r->pnotes('tempfiles' => []);

    {
        # $uplo is an 'upload', not a 'upic'
        my $get_up = sub { $_[0] =~ /^file(\d+)$/ ? $uploads{$1} ||= { id => $1 } : undef };

        # called when the beginning of an upload is encountered
        my $hook_newheaders = sub {
            my ($name, $filename) = @_;

            # note that this is the name we'll now be working on
            $curr_name = $name;

            my $uplo = $get_up->($curr_name); # stand up...
            return 1 unless $uplo;

            # for uploaded files, just set POST value to filename
            $POST{$name} = $filename;

            # new file, need to create a filehandle, etc
            $uplo->{filename} = $filename;
            $uplo->{md5ctx} = new Digest::MD5;

            # set pclusterid/pclustertype to be what we got from above
            ($uplo->{pclustertype}, $uplo->{pclusterid}) = FB::lookup_pcluster_dest();
            die "Couldn't determine pclustertype" unless $uplo->{pclustertype};
            die "Couldn't determine pclusterid"   unless $uplo->{pclusterid};

            # get MogileFS filehandle
            if ($uplo->{pclustertype} eq 'mogilefs') {
                $uplo->{spool_fh} = $FB::MogileFS->new_file
                    or die "Failed to open MogileFS tempfile";

            # get handle to temporary file
            } else {

                my $clust_dir = "$FB::PIC_ROOT/$uplo->{pclusterid}";
                my $spool_dir = "$clust_dir/spool";

                unless (-e $spool_dir) {
                    mkdir $clust_dir, 0755;
                    mkdir $spool_dir, 0755;
                    unless (-e $spool_dir) {
                        $r->log_error("Could not create spool directory (wrong permissions?): $spool_dir");
                        die "Failed to find/create spool directory";
                    }
                }

                ($uplo->{spool_fh}, $uplo->{spool_path}) = File::Temp::tempfile( "upload_XXXXX", DIR => $spool_dir);

                # add to pnotes so we can unlink all the temporary files later, regardless of error condition
                push @{$r->pnotes('tempfiles')}, $uplo->{spool_path};

                die "Failed to open local tempfile: $uplo->{spool_path}" unless $uplo->{spool_fh} && $uplo->{spool_path};
            }

            return 1;
        };

        # called as data is received
        my $hook_data = sub {
            my ($len, $data) = @_;

            # check that we've not exceeded the max read limit
            my $max_read = (1<<20) * 30; # 30 MiB
            my $len_read = 0;

            my $uplo = $get_up->($curr_name);
            if ($uplo) {
                $len_read = ($uplo->{bytes} += $len);
                $totalsize += $len;
            } else {
                $len_read = length($POST{$curr_name} .= $data);
            }

            die "Upload max exceeded at $len_read bytes"
                if $len_read > $max_read;

            # done unless we're processing a file
            return 1 unless $uplo;

            $uplo->{md5ctx}->add($data);
            $uplo->{spool_fh}->print($data);

            return 1;
        };

        # called when the end of an upload is encountered
        my $hook_enddata = sub {

            my $uplo = $get_up->($curr_name);
            return 1 unless $uplo;

            # since we've just finished a potentially slow upload, we need to
            # make sure the database handles in DBI::Role's cache haven't expired,
            # so we'll just trigger a revalidation now so that subsequent database
            # calls will be safe.  note that this gets called after every file
            # is read from the request, so that gpic_new et al can be called
            # before the next uploaded file is processed
            $FB::DBIRole->clear_req_cache();

            # don't try to operate on 0-length spoolfiles
            unless ($uplo->{bytes}) {
                delete $uploads{$uplo->{id}};
                return 1;
            }

            # read magic and try to determine formatid of uploaded file. This
            # doesn't use fh->tell and fh->seek because the filehandle is
            # sysopen()ed, so isn't really an IO::Seekable like an IO::File
            # filehandle would be.
            my $magic;
            tell $uplo->{spool_fh}
                or die "read offset is 0, empty file?";
            seek $uplo->{spool_fh}, 0, 0;

            # $! should always be set in this case because a failed read will
            # always be an error, not EOF, which is handled above (tell)
            $uplo->{spool_fh}->read($magic, 20)
                or die "Couldn't read magic: $!";

            $uplo->{fmtid} = FB::fmtid_from_magic($magic)
                or die "Unknown format for upload";

            # finished adding data for md5, create digest (but don't destroy original)
            $uplo->{md5sum} = $uplo->{md5ctx}->digest;

            # then see if we already have a gpic for this file based on md5
            my $gpicid = FB::find_equal_gpicid(FB::bin_to_hex($uplo->{md5sum}), $uplo->{bytes}, $uplo->{fmtid}, 'verify_paths');

            # no gpic, create anew
            unless ($gpicid) {

                my $g = FB::Gpic->new
                    ( map { $_ => $uplo->{$_} } qw(pclustertype pclusterid md5sum fmtid bytes) )
                    or die "Couldn't create gpic";

                # now that we have a gpic object, tell it that its data is already
                # in the form of a spool file created by Apache
                $g->file_from_spool($uplo->{spool_fh}, $uplo->{spool_path});

                $g->save( no_close => 1 ) or die "Couldn't save gpic";

                $gpicid = $g->{gpicid};

                # note that this gpic is open in need of a successful
                # close before it can be trusted
                $open->('gpic' => $gpicid, $g);
            }
            die "No gpic created" unless $gpicid;

            # for later when we create upic and save title/des
            $uplo->{gpicid} = $gpicid;

            return 1;
        };

        # parse multipart-mime submission, one chunk at a time,
        # calling our hooks as we go to put uploads in temporary
        # MogileFS filehandles
        my $err;
        my $res = BML::parse_multipart_interactive($r, \$err, {
            newheaders => $hook_newheaders,
            data       => $hook_data,
            enddata    => $hook_enddata,
        });


        # if BML::Parse_multipart_interactive failed, we need to add
        # all of our gpics to the gpic_delete queue.  if any of them
        # still have refcounts, they won't really be deleted because
        # the async job will realize and leave them alone
        unless ($res) {
            if (index(lc($err), 'unknown format') == 0) {
                $discard_open->();
                $r->header_out(Location => "/help/index.bml?topic=formats&err=1");
                return REDIRECT;
            }
            return $server_error->("couldn't parse upload" => $err);
        }
    }

    # find destination gallery for upics
    my $g;
    if ($POST{gallid} eq 'new' && $POST{newgalname} =~ /\S/) {
        $g = FB::Gallery->create($u, name => $POST{newgalname})
    } elsif (my $gallid = $POST{gallid}+0) {
        $g = $u->load_gallery_id($gallid);
    }
    $g ||= $u->incoming_gallery;

    # call hook to check if user has disk space for picture before uploading
    my $Kibfree = FB::run_hook("disk_remaining", $u);
    if (defined $Kibfree) {
        return $bad_req->("No disk space remaining for your account.")
            if $Kibfree <= 0;
        return $bad_req->("Not enough disk space remaining on your account for these pictures.")
            if $Kibfree < $totalsize>>10;
    }

    # now iterate over received uploads and create upics/add to gallery
    my @upicids;
    foreach my $id (sort { $a <=> $b } keys %uploads) {
        my $uplo = $uploads{$id};

        my $secid = defined $POST{"sec$id"} ? $POST{"sec$id"} : $POST{'all_pic_sec'};

        # allocate new upic
        my $pre_existing = 0;
        my $up = FB::Upic->create($u, $uplo->{gpicid}, secid => $secid)
            or return $server_error->("couldn't generate upicid" => $@ => $!);

        my $upicid = $up->id;

        $open->('upic' => $upicid, $up); # mark this upic as open

        # parse EXIF data from image and store it if necessary
        if ($up->fmtid == FB::fmtid_from_ext('jpg')) {

            # since Mogile only keeps 1024 bytes of data buffered in memory,
            # this would fail if we hadn't just printed the entire image to
            # MogileFS's buffer, making it all still in memory.
            seek $uplo->{spool_fh}, 0, 0;
            $up->exif_header($uplo->{spool_fh})
                or return $server_error->(FB::last_error());
        }
        $uplo->{spool_fh}->close
            or return $server_error->("unable to close spool filehandle" => $@ => $!);

        # gpic is closed, remove it from the open_gpics list
        $close->('gpic' => $uplo->{gpicid});

        my $handle_dup_after_rotate = sub {
            my $exist_upicid = shift;
            # delete the one we'd been working with,
            $up->delete;
            # and keep working with the original one
            $up      = FB::Upic->new($u, $exist_upicid);
            $upicid = $up->id;
        };
        $up->add_event_listener("set_gpic_failed_dup", $handle_dup_after_rotate);

        # auto-rotate it
        $up->autorotate;

        # add new upic to gallery
        $g->add_picture($up)
            or return $server_error->("couldn't add upic to gallery" => $upicid);

        # set 'filename' prop
        $up->set_prop('filename', $uplo->{filename}) if $uplo->{filename};

        # set 'pictitle' prop
        my $title = $POST{"title$id"};
        if ($title && FB::is_utf8($title)) {
            $up->set_prop("pictitle", $title)
                or return $server_error->("couldn't set upic prop pictitle" => $upicid);
        }

        # set des
        my $des = $POST{"des$id"};
        if ($des) {
            $up->set_des($des)
                or return $server_error->("couldn't set upic description" => $upicid);
        }

        # upic and its corresponding gpic are both successfully saved now
        $close->('upic' => $upicid);

        push @upicids, $upicid;
    }

    # FIXME: is this necessary?
    FB::gal_save_nextsort($u, $g);

    my $host = FB::user_siteroot($u);
    my $url;
    if ($POST{'go_to'} eq "annotate") {
        $url = "$host/manage/annotate?gal=$g->{'gallid'}&ids=" . join(",", @upicids);
    } else {
        my $jsarg = $POST{'go_to'} eq "jscallup" ? "&jscallup=1" : "";
        $url = "$host/manage/uploaded?gallid=$g->{'gallid'}&ids=" . join(",", @upicids) . $jsarg;
    }

    if ($POST{redir_to_auth_base}) {
        my $auth = FB::current_domain_plugin();
        if ($POST{redir_to_auth_base} == 1) {
            $url = $auth->remote_url("on_upload");
        } else {
            $url = $auth->remote_url("on_upload_rte");
        }

        my %ret;
        my $n = 0;
        foreach my $upicid (@upicids) {
            my $up = FB::Upic->new($u, $upicid) or next;
            $n++;

            # Dimensions and URL for full image
            $ret{"w_$n"} = $up->width;
            $ret{"h_$n"} = $up->height;
            $ret{"u_$n"} = $up->url_full;

            # Give them URL to picture page as well
            $ret{"pp_$n"} = $up->url_picture_page();

            # "Medium" sized scaled image as well for display in entries
            my ($su, $sw, $sh) = $up->scaled_url(320, 240);
            $ret{"sw_$n"} = $sw;
            $ret{"sh_$n"} = $sh;
            $ret{"su_$n"} = $su;
        }
        $ret{"upload_count"} = $n;

        $url .= "?" . join("&", map { FB::eurl($_) . "=" . FB::eurl($ret{$_}) } keys %ret);
    }

    $r->content_type("text/html");

    $r->header_out(Location => $url);
    return REDIRECT;
}

1;

