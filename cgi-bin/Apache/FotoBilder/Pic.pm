#!/usr/bin/perl
#

package Apache::FotoBilder::Pic;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED OK);
use PaletteModify;
use IO::Scalar;

# URLs of form http://www.pp.com/brad/pic/000fbt9x
#              http://www.pp.com/brad/pic/000fbt9x--[extra].ext
#         old: http://www.pp.com/brad/pic/000fbt9x[extra]
#
#   / - load page
#   /g<n> - load page for gallery <n>
#   /p...    - palette modify
#   /s...    - scaled
#   /t...    - thumbnailed

sub handler
{
    my $r = shift;
    my $uri = $r->uri;

    my $uri_components = FB::decode_picture_uri($uri);
    my $user = $uri_components->{'user'};
    my $upicid = $uri_components->{'upicid'};
    my $auth = $uri_components->{'auth'};
    my $separator = $uri_components->{'separator'};
    my $extra = $uri_components->{'extra'};
    my $extension = $uri_components->{'extension'};

    $user = $FB::ROOT_USER if $FB::ROOT_USER;
    return 404 unless defined $user;
    my $u = FB::load_user($user, undef, { validate=>1 });
    return 404 if ! $u || $u->{statusvis} =~ /[DX]/;
    return 403 if $u->{statusvis} eq 'S';

    $upicid = FB::b28_decode($upicid);
    $auth   = FB::b28_decode($auth);

    my $up = FB::Upic->new($u, $upicid);
    return 404 unless $up && $up->valid;
    return 404 unless $auth == $up->randauth % (28**3);

    # like /USER/pic/000023x2/
    # like /USER/pic/000023x2/g3
    # not: /USER/pic/000023x2     (the old full image page)
    if (! $extension && $separator eq "/" && $extra =~ m!^(?:g(\d+))?$!) {
        my $gallid = $1;
        return Apache::FotoBilder::PicturePage::handler($r, $u, $up, $gallid);
    }

    my $err = sub {
        my $msg = shift;
        $r->log_error("FotoBilder::Pic: $msg");
        return 500;
    };

    # Two ways to authenticate the remote user:
    #  * via usually HTTP cookie auth for web sessions
    #  * via X-FB-Auth header for protocol clients downloading
    #    private pictures for backup, etc
    my $remote = undef;
    {
        my $hd_user = $r->header_in('X-FB-User');
        my $hd_auth = $r->header_in('X-FB-Auth');
        if ($hd_user && $hd_auth && $hd_auth =~ /^crp:/) {
            # returns undef if auth fails
            $remote = FB::check_auth($hd_user, $hd_auth);
        } else {
            $remote = FB::get_remote();
        }
    }

    return 403 if FB::get_cap($u, "gallery_private") &&
        (! $remote || $remote->{'userid'} != $u->{'userid'});

    # need to see if there's a reference to this picture in some gallery
    # that the remote user has access to view
    return 403 unless $up->visible;

    my $palspec; # palette colors, set if $extra begins with '/p'
    my $g;       # pic to serve  (FB::Gpic object)

    my $enabled = FB::get_cap($u, "gallery_enabled");

    # do they want a scaled version?
    if ($extra =~ m!^s(\d+)?(?:x(\d+))?$! && ($1 || $2)) {
        my ($req_x, $req_y) = ($1, $2);

        # reject requests to images over MAX(320x320)
        # if gallery not enabled
        return 403 if ! $enabled && ($req_x > 320 || $req_y > 320);

        # invalid scaling on the url is a 404
        return 404 unless FB::valid_scaling($req_x, $req_y);

        # load the scaled image, creating a new one if necessary
        my $g_orig = FB::Gpic->load($up->gpicid)
            or return 404;
        $g = $g_orig->load_scaled($req_x, $req_y, { create => 1 })
            or return 404;

    } elsif ($extra =~ m!^p(.+)$!) {
        $palspec = $1;
    } elsif ($extra =~ m!t(\w{4,10})$!) {
        if (!$up->is_audio()) {
            # thumbnail mod
            $g = $up->thumbnail_gpic($1)
                or return 404;
        } else {
            # if it's audio, the thumbnail is the happy audio image
            # get happy audio image size
            my ($thumbnailpath, $aw, $ah, $amime) = FB::audio_thumbnail_info();
            my $diskpath = $ENV{'FBHOME'} . '/htdocs/' . $thumbnailpath;
            return 404 unless -e $diskpath;
            my @fstat = stat($diskpath);

            return send_file($r, [$diskpath], {
                'mime' => $amime,
                'size' => $fstat[7],
            });
        }

    } elsif ($extra) {
        # unknown extra string
        return 404;
    }

    # deny if they want the full version (and it's larger than 320x320),
    # but gallery isn't enabled
    return 403 unless $enabled || $g ||
        ($up->width <= 320 && $up->height <= 320);

    # get the real image
    $g ||= FB::Gpic->load($up->gpicid);
    return 404 unless $g;

    # Fail if wrong extension
    return 404 if $extension && FB::fmtid_from_ext($extension) ne $g->{fmtid};

    my $noverify = (remote_can_reproxy($r) || $palspec) ? 1 : 0;
    my @paths = $g->paths($noverify);
    return 404 unless @paths;

    # compute etag
    my $etag = $g->md5_bin;
    $etag =~ s/(.)/sprintf("%02x",ord($1))/seg;

    # if we didn't get something above, then our file
    # isn't available on disk anymore?
    return send_file($r, \@paths, {
        'mime' => FB::fmtid_to_mime($g->{'fmtid'}),
        'etag' => $etag,
        'size' => $g->{'bytes'},
        'palspec' => $palspec,
        'modtime' => ($up->prop("modtime") || $up->datecreate_unix),
    });
}

sub img_dir
{
    my $r = shift;
    my $uri = $r->uri;
    my ($base, $ext, $extra) = $uri =~ m!^/img/(.+)\.(\w+)(.*)$!;
    return 404 unless $base && $base !~ m!\.\.!;

    my $path = "$FB::HOME/htdocs/img/$base.$ext";
    return 404 unless -e $path;
    my @st = stat(_);
    my $size = $st[7];
    my $modtime = $st[9];
    my $etag = "$modtime-$size";

    my $mime = {
        'gif' => 'image/gif',
        'png' => 'image/png',
    }->{$ext};

    my $palspec;
    if ($extra) {
        if ($extra =~ m!^/?p(.+)$!) {
            $palspec = $1;
        } else {
            return 404;
        }
    }

    return send_file($r, [ $path ], {
        'mime' => $mime,
        'etag' => $etag,
        'palspec' => $palspec,
        'size' => $size,
        'modtime' => $modtime,
    });
}

sub remote_can_reproxy {
    my $r = shift;
    return $r->header_in('X-Proxy-Capabilities') &&
           $r->header_in('X-Proxy-Capabilities') =~ m{\breproxy-file\b}i;
}

sub parse_hex_color
{
    my $color = shift;
    return [ map { hex(substr($color, $_, 2)) } (0,2,4) ];
}

sub send_file
{
    my ($r, $paths, $opts) = @_;
    return 404 unless ref $paths eq 'ARRAY' && @$paths;

    my $etag = $opts->{'etag'};

    # palette altering
    my %pal_colors;
    if (my $pals = $opts->{'palspec'}) {
        my $hx = "[0-9a-f]";
        if ($pals =~ /^g($hx{2,2})($hx{6,6})($hx{2,2})($hx{6,6})$/) {
            # gradient from index $1, color $2, to index $3, color $4
            my $from = hex($1);
            my $to = hex($3);
            return 404 if $from == $to;
            my $fcolor = parse_hex_color($2);
            my $tcolor = parse_hex_color($4);
            if ($to < $from) {
                ($from, $to, $fcolor, $tcolor) =
                    ($to, $from, $tcolor, $fcolor);
            }
            $etag .= ":pg$pals";
            for (my $i=$from; $i<=$to; $i++) {
                $pal_colors{$i} = [ map {
                    int($fcolor->[$_] +
                        ($tcolor->[$_] - $fcolor->[$_]) *
                        ($i-$from) / ($to-$from))
                    } (0..2)  ];
            }
        } elsif ($pals =~ /^t($hx{6,6})($hx{6,6})?$/) {
            # tint everything towards color
            my ($t, $td) = ($1, $2);
            $pal_colors{'tint'} = parse_hex_color($t);
            $pal_colors{'tint_dark'} = $td ? parse_hex_color($td) : [0,0,0];
        } elsif (length($pals) > 42 || $pals =~ /[^0-9a-f]/) {
            return 404;
        } else {
            my $len = length($pals);
            return 404 if $len % 7;  # must be multiple of 7 chars
            for (my $i = 0; $i < $len/7; $i++) {
                my $palindex = hex(substr($pals, $i*7, 1));
                $pal_colors{$palindex} = [
                                          hex(substr($pals, $i*7+1, 2)),
                                          hex(substr($pals, $i*7+3, 2)),
                                          hex(substr($pals, $i*7+5, 2)),
                                          substr($pals, $i*7+1, 6),
                                          ];
            }
            $etag .= ":p$_($pal_colors{$_}->[3])" for (sort keys %pal_colors);
        }
    }

    $etag = '"' . $etag . '"';
    $r->header_out("ETag", $etag);

    # send the file
    $r->content_type($opts->{'mime'});
    $r->header_out("Content-length", $opts->{'size'});

    if ($opts->{'modtime'}) {
        $r->update_mtime($opts->{'modtime'});
        $r->set_last_modified();
    }

    if ((my $rc = $r->meets_conditions) != OK) {
        return $rc;
    }

    # Delegate the actual sending of the file to the lightweight proxy if the
    # capabilities header indicates that capability and there's no palette
    # alteration
    if (remote_can_reproxy($r) &&
          (! $opts->{palspec} || $opts->{size} > 40_960) )
    {
        $r->header_out( 'X-REPROXY-EXPECTED-SIZE', $opts->{'size'} );
        if ($paths->[0] =~ m!^http://!) {
            $r->header_out( 'X-REPROXY-URL', join(' ', @$paths) );
        } else {
            $r->header_out( 'X-REPROXY-FILE', $paths->[0] );
        }
        $r->send_http_header();
        return OK;
    }

    $r->send_http_header();

    # HEAD request?
    return OK if $r->method eq "HEAD";

    # this path is used when our path is a URL
    if ($paths->[0] =~ m!^http://!) {
        my $ua = LWP::UserAgent->new;
        $ua->timeout(1);
        while (my $fn = shift @$paths) {
            my $response = $ua->get($fn);
            next unless $response->is_success;

            my $content = $response->content;
            my $palette;
            if (%pal_colors) {
                my $fh = IO::Scalar->new(\$content);

                if ($opts->{mime} eq 'image/gif') {
                    $palette = PaletteModify::new_gif_palette($fh, \%pal_colors);
                } elsif ($opts->{mime} eq 'image/png') {
                    $palette = PaletteModify::new_png_palette($fh, \%pal_colors);
                }
                return 404 unless $palette;
            }

            # now print what we got
            $r->print($palette) if $palette;
            $r->print(substr($content, length($palette)));
            return OK;
        }
        return 404;
    }

    # fallback to file path
    my $fh = Apache::File->new($paths->[0]);
    return 404 unless $fh;
    binmode($fh);

    my $palette;
    if (%pal_colors) {
        if ($opts->{'mime'} eq "image/gif") {
            $palette = PaletteModify::new_gif_palette($fh, \%pal_colors);
        } elsif ($opts->{'mime'} == "image/png") {
            $palette = PaletteModify::new_png_palette($fh, \%pal_colors);
        }
        return 404 unless $palette; # image isn't palette changeable?
    }

    $r->print($palette) if $palette; # when palette modified.
    $r->send_fd($fh);           # sends remaining data (or all of it) quickly
    $fh->close();

    return OK;
}

1;

