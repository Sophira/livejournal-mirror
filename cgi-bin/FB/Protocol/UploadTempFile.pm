#!/usr/bin/perl

package FB::Protocol::UploadTempFile;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars}->{UploadTempFile};

    my $r = $req->{r};
    my $u = $resp->{u};

    my $err = sub {
        $resp->add_method_error(UploadTempFile => @_);
        return undef;
    };

    # is the user allowed to upload?
    return $err->(303)
        unless FB::get_cap($u, 'can_upload') && $u->{statusvis} eq 'V';

    # did they specify an ImageData variable?
    my $img = $vars->{ImageData};
    return $err->(212 => "ImageData")
        unless $img;

    # valid pclustertype / pclusterid
    return $err->(500 => "Could not determine pclustertype/id")
        unless $img->{pclustertype} && $img->{pclusterid};

    # did we count bytes?
    return $err->(213 => "No data sent")
        unless $img->{bytes};

    # check the declared imagelength
    return $err->(212 => "ImageLength")
        unless exists $vars->{ImageLength};

    my $length = $vars->{ImageLength};
    return $err->(211 => "ImageLength")
        unless defined $length;
    return $err->(211 => "ImageLength does not match data length")
        unless $length == $img->{bytes};

    # check that it's a valid fmtid
    my $fmtid = $img->{fmtid};
    return $err->(213 => "Unknown format")
        unless $fmtid;

    # valid filehandle -- can't count on path
    return $err->(500 => "No spool filehandle")
        unless $img->{spool_fh};

    # valid md5 sum?
    return $err->(500 => "Could not calculate MD5 sum")
        unless $img->{md5sum};

    # if an md5 is supplied, check that it matches the image's actual 
    # calculated md5
    my $md5_hex = FB::bin_to_hex($img->{md5sum});
    if ($vars->{MD5} && $vars->{MD5} ne $md5_hex) {
        return $err->(211 => "Supplied MD5 does not match data MD5");
    }

    # call hook to check if user has disk space for picture before uploading
    my $Kibfree = FB::run_hook("disk_remaining", $u);
    if (defined $Kibfree) {
        return $err->(401) if $Kibfree <= 0;
        return $err->(402) if $Kibfree < $length>>10;
    }

    # generate a rcptkey for this receipt
    my $rcptkey = FB::rand_chars(20);

    # need to make sure our tempfiles (either disk or mogile) don't get cleaned up
    # as they're supposed to
    if ($img->{pclustertype} eq 'mogilefs') {

        $img->{pathkey} = "tmpfile:$rcptkey";

        # spool_fh is a mogilefs object
        my $mg = $img->{spool_fh};

        # set key so the file won't be deleted as a 'tempfile'
        $mg->key( $img->{pathkey} )
            or return $err->(500 => "Could not set MogileFS key");

        # close to save key
        $mg->close or return $err->(500 => [ "Could not close MogileFS file" => $@ => $! ]);

    } elsif ($img->{pclustertype} eq 'disk') {

        # save spool_path so we can find the file later
        $img->{pathkey} = $img->{spool_path};

        # rescue from 'tempfiles' pnotes key so it won't be deleted
        my $pnotes = $r->pnotes('tempfiles') || [];
        @$pnotes = grep { $_ ne $img->{pathkey} } @$pnotes;
        $r->pnotes('tempfiles' => $pnotes);

    } else {
        return $err->(500 => [ 'Unknown pclustertype' => $img->{pclustertype} ]);
    }

    return $err->(500 => "Unable to retain spool file")
        unless $img->{pathkey};

    my $rv = FB::save_receipt($u, $rcptkey, 'T',
                              {
                                  map { $_ => $img->{$_} }
                                  qw(bytes md5sum fmtid pathkey pclustertype pclusterid),
                              })
        or return $err->(500 => [ "Unable to create receipt" => FB::last_error() ]);

    # register return value with parent Request
    $resp->add_method_vars(
                           UploadTempFile => {
                               Receipt   => [ $rcptkey ],
                           });

    return 1;
}

1;
