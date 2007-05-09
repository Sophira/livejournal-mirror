#!/usr/bin/perl
#
# Temporary class for modifying static images on the fly with Image::Magick.
# (Not Upics.)
#
# This was created so we could easily show a nicely resized video
# placeholder (before true video thumbnailing is in place).  After
# correct thumbnailing is done, this should either be completely
# removed, or extended to be useful for other similar needs in the
# future.
#
# FIXME:  We should probably cache the images to disk or db after
# Image::Magick has it's way with them, so we aren't unnecessarily
# burning CPU on resizes/etc.
#
# /img/dynamic/IMAGE/FUNCTION/OPT1/OPT2/ETC

package Apache::FotoBilder::DynamicImg;

use strict;
use Apache::Constants qw/:common/;
#use FB::Magick;

my $path = '/img/dynamic';

sub handler
{
    my $r = shift;
    my $uri = $r->uri;
    $uri =~ s!$path/!!;

    my ($image, $func, @opts) = split /\//, $uri;
    return NOT_FOUND unless $image && $func;

    $image = $r->document_root() . "/$path/$image";
    return NOT_FOUND unless -e $image;

    my ($w, $h) = ($opts[0], $opts[1]);
    $w = $w > 320 ? 320 : $w;
    $h = $h > 320 ? 320 : $h;

    my $blobref = FB::Job->do
        ( job_name => 'fbmagick',
          arg_ref  => [$image, "Resize", width => $w, height => $h],
          task_ref => \&FB::Upic::_magick_do,
          );

    return send_image( $r, $blobref );
}

sub send_image
{
    my ($r, $blobref) = @_;
    $r->send_http_header('image/jpeg');

    $r->print( $$blobref );
    return OK;
}

1;

