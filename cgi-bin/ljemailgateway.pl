#!/usr/bin/perl

package LJ::Emailpost;
use strict;

BEGIN {
    require "$ENV{LJHOME}/cgi-bin/ljconfig.pl";
    if ($LJ::USE_PGP) {
        eval 'use GnuPG::Interface';
        die "Could not load GnuPG::Interface." if $@;
    }
}

require "$ENV{LJHOME}/cgi-bin/ljlib.pl";
require "$ENV{LJHOME}/cgi-bin/ljprotocol.pl";
require "$ENV{LJHOME}/cgi-bin/fbupload.pl";
use HTML::Entities;
use IO::Handle;
use Image::Size;
use LWP::UserAgent;
use MIME::Words ();
use XML::Simple;

# $rv - scalar ref from mailgated.
# set to 1 to dequeue, 0 to leave for further processing.
sub process {
    my ($entity, $to, $rv) = @_;
    my $head = $entity->head;
    $head->unfold;

    $$rv = 1;  # default dequeue

    # Parse email for lj specific info
    my ($user, $journal, $pin);
    ($user, $pin) = split(/\+/, $to);
    ($user, $journal) = split(/\./, $user) if $user =~ /\./;
    my $u = LJ::load_user($user);
    return unless $u;
    LJ::load_user_props($u, 'emailpost_pin') unless (lc($pin) eq 'pgp' && $LJ::USE_PGP);

    # Pick what address to send potential errors to.
    my @froms = Mail::Address->parse($head->get('From:'));
    return unless @froms;
    my $from = $froms[0]->address;
    my $addrlist = LJ::get_allowed_senders($u);
    my $err_addr;
    foreach (keys %$addrlist) {
        if (lc($from) eq lc &&
                $addrlist->{$_}->{'get_errors'}) {
            $err_addr = $from;
            last;
        }
    }
    $err_addr ||= $u->{email};

    my ($body, $subject);

    my $err = sub {
        my ($msg, $opt) = @_;

        # FIXME: Need to log last 10 errors to DB / memcache
        # and create a page to watch this stuff.

        my $errbody;
        $errbody .= "There was an error during your email posting:\n\n";
        $errbody .= $msg;
        if ($body) {
            $errbody .= "\n\n\nOriginal posting follows:\n\n";
            $errbody .= $body;
        }

        # Rate limit email to 1/5min/address
        if ($opt->{'sendmail'} && $err_addr &&
            LJ::MemCache::add("rate_eperr:$err_addr", 5, 300)) {
            LJ::send_mail({
                    'to' => $err_addr,
                    'from' => $LJ::BOGUS_EMAIL,
                    'fromname' => "$LJ::SITENAME Error",
                    'subject' => "$LJ::SITENAME posting error: $subject",
                    'body' => $errbody
                    });
        }
        $$rv = 0 if $opt->{'retry'};
        return $msg;
    };

    # Get various email parts.
    my $content_type = $head->get('Content-type:');
    $subject = $head->get('Subject:');
    my $return_path = ${(Mail::Address->parse( $head->get('Return-Path') ))[0] || []}[1];
    my $tent;

    # Is this message from a sprint PCS phone?  Sprint doesn't support
    # MMS (yet) - when it does, we should just be able to rip this block
    # of code completely out.
    #
    # Sprint has two methods of non-mms mail sending.
    #   -  Normal text messaging just sends a text/plain piece.
    #   -  Sprint "PictureMail".
    # PictureMail sends a text/html piece, that contains XML with
    # the location of the image on their servers - and a blank text/plain.  (?)
    # We assume the existence of a text/html means this is a PictureMail message,
    # as there is no other method (headers or otherwise) to tell the difference,
    # and Sprint tells me that their text messaging never contains text/html.
    # Currently, PictureMail can only contain one image per message
    # and the image is always a jpeg. (2/2/05)
    if ($return_path && $return_path =~ /messaging\.sprintpcs/) {
        $tent = LJ::Emailpost::get_entity( $entity, { type => 'html' } );
        $subject = 'Sprint PictureMail Post'; 

        return $err->(
            "Unable to find Sprint HTML content in PictureMail message.",
            { sendmail => 1 }
          ) unless $tent;

        # ok, parse the XML.
        my $html = $tent->bodyhandle->as_string();
        my $xml_string = $1 if $html =~ /<!-- lsPictureMail-Share-\w+-comment\n(.+)\n-->/is;
        return $err->(
            "Unable to find XML content in PictureMail message.",
            { sendmail => 1 }
          ) unless $tent;

        HTML::Entities::decode_entities( $xml_string );
        my $xml = eval { XML::Simple::XMLin( $xml_string ); };
        return $err->(
            "Unable to parse XML content in PictureMail message.",
            { sendmail => 1 }
          ) if ( ! $xml || $@ );

        return $err->(
            "Sorry, we currently only support image media.",
            { sendmail => 1 }
          ) unless $xml->{messageContents}->{type} eq 'PICTURE';

        $body = $xml->{messageContents}->{messageText} . "\n";
        my $url =
          HTML::Entities::decode_entities(
            $xml->{messageContents}->{mediaItems}->{mediaItem}->{url} );

        return $err->(
            "Invalid remote SprintPCS URL.", { sendmail => 1 }
          ) unless $url =~ m#^http://pictures.sprintpcs.com/#;

        # we've got the url to the full sized image.
        # fetch!
        my ($tmpdir, $tempfile);
        $tmpdir = File::Temp::tempdir( "ljmailgate_" . 'X' x 20, DIR=> $main::workdir );
        ( undef, $tempfile ) = File::Temp::tempfile(
            'sprintpcs_XXXXX',
            SUFFIX => '.jpg',
            OPEN   => 0,
            DIR    => $tmpdir
        );
        my $ua = LWP::UserAgent->new(
            timeout => 20,
            agent   => 'LiveJournal_EmailGateway/0.1'
        );
        my $ua_rv = $ua->get( $url, ':content_file' => $tempfile );

        if ($ua_rv->is_success) {
            # attach the image to the main entity, so upload_images()
            # can work without modifications.
            $entity->attach(
                Path => $tempfile,
                Type => 'image/jpeg'
            );
        }
        else {
            # Retry if we are unable to connect to the remote server.
            # Otherwise, the image has probably expired.  Dequeue.
            my $reason = $ua_rv->status_line;
            return $err->(
                "Unable to fetch SprintPCS image. ($reason)",
                { 
                    sendmail => 1,
                    retry => $reason =~ /Connection refused/
                }
            );
        }
    } 

    # All other email (including MMS)
    # Use text/plain piece first - if it doesn't exist, then fallback to text/html
    else {
        $tent = get_entity( $entity );
        $tent = LJ::Emailpost::get_entity( $entity, { type => 'html' } ) unless $tent;
        return $err->("Unable to find any text content in your mail", { sendmail => 1 }) unless $tent;

        $body = $tent->bodyhandle->as_string;
        $body =~ s/^\s+//;
        $body =~ s/\s+$//;
    }

    # Snag charset and do utf-8 conversion
    my ($charset, $format);
    $charset = $1 if $content_type =~ /\bcharset=['"]?(\S+?)['"]?[\s\;]/i;
    $format = $1 if $content_type =~ /\bformat=['"]?(\S+?)['"]?[\s\;]/i;
    if (defined($charset) && $charset !~ /^UTF-?8$/i) { # no charset? assume us-ascii
        return $err->("Unknown charset encoding type.", { sendmail => 1 })
            unless Unicode::MapUTF8::utf8_supported_charset($charset);
        $body = Unicode::MapUTF8::to_utf8({-string=>$body, -charset=>$charset});
    }

    # check subject for rfc-1521 junk
    if ($subject =~ /^=\?/) {
        my @subj_data = MIME::Words::decode_mimewords( $subject );
        if (@subj_data) {
            if ($subject =~ /utf-8/i) {
                $subject = $subj_data[0][0];
            } else {
                $subject = Unicode::MapUTF8::to_utf8(
                        {
                        -string  => $subj_data[0][0],
                        -charset => $subj_data[0][1]
                        }
                        );
            }
        }
    }
    
    # Strip (and maybe use) pin data from viewable areas
    if ($subject =~ s/^\s*\+([a-z0-9]+)\s+//i) {
        $pin = $1 unless defined $pin;
    }
    if ($body =~ s/^\s*\+([a-z0-9]+)\s+//i) {
        $pin = $1 unless defined $pin;
    }

    # Validity checks.  We only care about these if they aren't using PGP.
    unless (lc($pin) eq 'pgp' && $LJ::USE_PGP) {
        return $err->("No allowed senders have been saved for your account.") unless ref $addrlist;
        my $ok = 0;
        foreach (keys %$addrlist) {
            if (lc($from) eq lc) {
                $ok = 1;
                last;
            }
        }
        return $err->("Unauthorized sender address: $from") unless $ok; # don't mail user due to bounce spam
        return $err->("Unable to locate your PIN.", { sendmail => 1 }) unless $pin;
        return $err->("Invalid PIN.", { sendmail => 1 }) unless lc($pin) eq lc($u->{emailpost_pin});
    }
    return $err->("Email gateway access denied for your account type.", { sendmail => 1 })
        unless LJ::get_cap($u, "emailpost");

    # PGP signed mail?  We'll see about that.
    if (lc($pin) eq 'pgp' && $LJ::USE_PGP) {
        my %gpg_errcodes = ( # temp mapping until translation
                'bad'         => "PGP signature found to be invalid.",
                'no_key'      => "You don't have a PGP key uploaded.",
                'bad_tmpdir'  => "Problem generating tempdir: Please try again.",
                'invalid_key' => "Your PGP key is invalid.  Please upload a proper key.",
                'not_signed'  => "You specified PGP verification, but your message isn't PGP signed!");
        my $gpgerr;
        my $gpgcode = LJ::Emailpost::check_sig($u, $entity, \$gpgerr);
        unless ($gpgcode eq 'good') {
            my $errstr = $gpg_errcodes{$gpgcode};
            $errstr .= "\nGnuPG error output:\n$gpgerr\n" if $gpgerr;
            return $err->($errstr, { sendmail => 1 });
        }
    }

    $body =~ s/^(?:\- )?[\-_]{2,}\s*\r?\n.*//ms; # trim sigs
    $body =~ s/ \n/ /g if lc($format) eq 'flowed'; # respect flowed text

    # Strip pgp clearsigning
    $body =~ s/^\s*-----BEGIN PGP SIGNED MESSAGE-----.+?\n\n//s;
    $body =~ s/-----BEGIN PGP SIGNATURE-----.+//s;

    # trim off excess whitespace (html cleaner converts to breaks)
    $body =~ s/\n+$/\n/;

    # Find and set entry props.
    my $props = {};
    my (%lj_headers,$amask);
    if ($body =~ s/^(lj-.+?)\n\n//is) {
        my @headers = split(/\n/, $1);
        foreach (@headers) {
            $lj_headers{lc($1)} = $2 if /^lj-(\w+):\s*(.+?)\s*$/i;
        }
    }

    LJ::load_user_props(
        $u,
        qw/
          emailpost_userpic emailpost_security
          emailpost_comments emailpost_gallery
          emailpost_imgsecurity emailpost_imgsize
          emailpost_imglayout emailpost_imgcut /
    );

    # Get post options, using lj-headers first, and falling back
    # to user props.  If neither exist, the regular journal defaults
    # are used.
    $props->{picture_keyword} = $lj_headers{'userpic'} ||
                                $u->{'emailpost_userpic'};
    $props->{current_mood}   = $lj_headers{'mood'};
    $props->{current_music}  = $lj_headers{'music'};
    $props->{opt_nocomments} = 1
      if $lj_headers{comments}      =~ /off/i
      || $u->{'emailpost_comments'} =~ /off/i;
    $props->{opt_noemail} = 1
      if $lj_headers{comments}      =~ /noemail/i
      || $u->{'emailpost_comments'} =~ /noemail/i;

    $lj_headers{security} = lc($lj_headers{security}) ||
                            $u->{'emailpost_security'};
    if ($lj_headers{security} =~ /^(public|private|friends)$/) {
        if ($1 eq 'friends') {
            $lj_headers{security} = 'usemask';
            $amask = 1;
        }
    } elsif ($lj_headers{security}) { # Assume a friendgroup if unknown security mode.
        # Get the mask for the requested friends group, or default to private.
        my $group = LJ::get_friend_group($u, { 'name'=>$lj_headers{security} });
        if ($group) {
            $amask = (1 << $group->{groupnum});
            $lj_headers{security} = 'usemask';
        } else {
            $err->("Friendgroup \"$lj_headers{security}\" not found.  Your journal entry was posted privately.",
                   { sendmail => 1 });
            $lj_headers{security} = 'private';
        }
    }

    # if they specified a imgsecurity header but it isn't valid, default
    # to private.  Otherwise, set to what they specified.
    $lj_headers{'imgsecurity'} ||= $u->{'emailpost_imgsecurity'};
    if ($lj_headers{'imgsecurity'} &&
        $lj_headers{'imgsecurity'} !~ /^(private|regusers|friends|public)$/) {
        $lj_headers{'imgsecurity'} = 0;
    }
    if ($lj_headers{'imgsecurity'} =~ /^(private|regusers|friends|public)$/) {
        my %groupmap = ( private => 0, regusers => 253,
                         friends => 254, public => 255 );

        $lj_headers{'imgsecurity'} = $groupmap{$1};
    }

    $lj_headers{'imgcut'}    ||= ($u->{'emailpost_imgcut'}    || 'totals');
    $lj_headers{'imglayout'} ||= ($u->{'emailpost_imglayout'} || 'vertical');

    # upload picture attachments to fotobilder.
    my ($fb_upload, $fb_upload_errstr);
    # undef return value? retry posting for later.
    $fb_upload = upload_images(
        $entity, $u,
        \$fb_upload_errstr,
        {
            imgsec  => $lj_headers{'imgsecurity'},
            galname => $lj_headers{'gallery'} || $u->{'emailpost_gallery'}
        }
      ) || return $err->( $fb_upload_errstr, { retry => 1 } );

    # if we found and successfully uploaded some images...
    if (ref $fb_upload eq 'HASH') {
        my $icount = scalar keys %$fb_upload;
        $body .= "\n";

        # set journal image display size
        my @valid_sizes = qw(100x100 320x240 640x480);
        my $size = lc($lj_headers{'imgsize'}) || $u->{'emailpost_imgsize'};
        $size = '320x240' unless grep { $size eq $_; } @valid_sizes;
        my ($width, $height) = split 'x', $size;
        $size = "/s$size";

        # force lj-cut on images larger than 320x240
        $lj_headers{'imgcut'} = 'totals' if $width > 320 || $height > 240;

        # insert image links into post body
        $body .= "<lj-cut text='$icount " .
                  (($icount == 1) ? 'image' : 'images') . "'>"
                  if lc($lj_headers{'imgcut'}) eq 'totals';
        $body .= "<span style='white-space: nowrap;'>" if $lj_headers{'imglayout'} =~ /^horiz/i;
        foreach my $img (keys %$fb_upload) {
            my $i = $fb_upload->{$img};

            # don't set a size on images smaller than the requested width/height
            # (we never scale larger, just smaller)
            undef $size if $i->{width}  <= $width || 
                           $i->{height} <= $height;

            $img =~ s/"//g;
            $body .= "<lj-cut text=\"$img\">" if lc($lj_headers{'imgcut'}) eq 'titles';
            $body .= "<a href=\"$i->{'url'}/\">";
            $body .= "<img src=\"$i->{'url'}$size\" alt=\"$img\" border=\"0\"></a>";
            $body .= ($lj_headers{'imglayout'} =~ /^horiz/i) ? '&nbsp;' : '<br />';
            $body .= "</lj-cut> " if lc($lj_headers{'imgcut'}) eq 'titles';
        }
        $body .= "</lj-cut>\n" if lc($lj_headers{'imgcut'}) eq 'totals';
        $body .= "</span>" if $lj_headers{'imglayout'} =~ /^horiz/i;
    }

    # at this point, there are either no images in the message ($fb_upload == 1)
    # or we had some error during upload that we may or may not want to retry
    # from.  $fb_upload contains the http error code.
    if ($fb_upload == 400) { 
        # bad request - don't retry, but go ahead and post the body to
        # the journal, postfixed with the remote error.
        $body .= "\n";
        $body .= "($fb_upload_errstr)";
    }

    # build lj entry
    my $req = {
        'usejournal' => $journal,
        'ver' => 1,
        'username' => $user,
        'event' => $body,
        'subject' => $subject,
        'security' => $lj_headers{security},
        'allowmask' => $amask,
        'props' => $props,
        'tz'    => 'guess',
    };

    # post!
    my $post_error;
    LJ::Protocol::do_request("postevent", $req, \$post_error, { noauth=>1 });
    return $err->(LJ::Protocol::error_message($post_error), { sendmail => 1}) if $post_error;

    return "Email post success";
}

# By default, returns first plain text entity from email message.
# Specifying a type will return an array of MIME::Entity handles
# of that type. (image, application, etc)
# Specifying a type of 'all' will return all MIME::Entities,
# regardless of type.
sub get_entity
{
    my ($entity, $opts) = @_;
    return if $opts && ref $opts ne 'HASH';
    my $type = $opts->{'type'} || 'text';

    my $head = $entity->head;
    my $mime_type = $head->mime_type;

    return $entity if $type eq 'text' && $mime_type eq "text/plain";
    return $entity if $type eq 'html' && $mime_type eq "text/html";
    my @entities;

    # Only bother looking in messages that advertise attachments
    my $mimeattach_re = qr{ m|^multipart/(?:alternative|signed|mixed|related)$| };
    if ($mime_type =~ $mimeattach_re) {
        my $partcount = $entity->parts;
        for (my $i=0; $i<$partcount; $i++) {
            my $alte = $entity->parts($i);

            return $alte if $type eq 'text' && $alte->mime_type eq "text/plain";
            return $alte if $type eq 'html' && $alte->mime_type eq "text/html";
            push @entities, $alte if $type eq 'all';

            if ($type eq 'image' &&
                $alte->mime_type =~ m#^application/octet-stream#) {
                my $alte_head = $alte->head;
                my $filename = $alte_head->recommended_filename;
                push @entities, $alte if $filename =~ /\.(?:gif|png|tiff?|jpe?g)$/;
            }
            push @entities, $alte if $alte->mime_type =~ /^$type/ &&
                                     $type ne 'all';

            # Recursively search through nested MIME for various pieces
            if ($alte->mime_type =~ $mimeattach_re) {
                if ($type =~ /^(?:text|html)$/) {
                    my $text_entity = get_entity($entity->parts($i));
                    return $text_entity if $text_entity;
                } else {
                    push @entities, get_entity($entity->parts($i), $opts);
                }
            }
        }
    }

    return @entities if $type ne 'text' && scalar @entities;
    return;
}


# Verifies an email pgp signature as being valid.
# Returns codes so we can use the pre-existing err subref,
# without passing everything all over the place.
#
# note that gpg interaction requires gpg version 1.2.4 or better.
sub check_sig {
    my ($u, $entity, $gpg_err) = @_;

    LJ::load_user_props($u, 'public_key');
    my $key = $u->{public_key};
    return 'no_key' unless $key;

    # Create work directory.
    my $tmpdir = File::Temp::tempdir("ljmailgate_" . 'X' x 20, DIR=>$main::workdir);
    return 'bad_tmpdir' unless -e $tmpdir;

    my ($in, $out, $err, $status,
        $gpg_handles, $gpg, $gpg_pid, $ret);

    my $check = sub {
        my %rets =
            (
             'NODATA 1'     => 1,   # no key or no signed data
             'NODATA 2'     => 2,   # no signed content
             'NODATA 3'     => 3,   # error checking sig (crc)
             'IMPORT_RES 0' => 4,   # error importing key (crc)
             'BADSIG'       => 5,   # good crc, bad sig
             'GOODSIG'      => 6,   # all is well
            );
        while (my $gline = <$status>) {
            foreach (keys %rets) {
                next unless $gline =~ /($_)/;
                return $rets{$1};
            }
        }
        return 0;
    };

    my $gpg_cleanup = sub {
        close $in;
        close $out;
        waitpid $gpg_pid, 0;
        undef foreach $gpg, $gpg_handles;
    };

    my $gpg_pipe = sub {
        $_ = IO::Handle->new() foreach $in, $out, $err, $status;
        $gpg_handles = GnuPG::Handles->new( stdin  => $in,  stdout=> $out,
                                            stderr => $err, status=> $status );
        $gpg = GnuPG::Interface->new();
        $gpg->options->hash_init( armor=>1, homedir=>$tmpdir );
        $gpg->options->meta_interactive( 0 );
    };

    # Pull in user's key, add to keyring.
    $gpg_pipe->();
    $gpg_pid = $gpg->import_keys( handles=>$gpg_handles );
    print $in $key;
    $gpg_cleanup->();
    $ret = $check->();
    if ($ret && $ret == 1 || $ret == 4) {
        $$gpg_err .= "    $_" while (<$err>);
        return 'invalid_key';
    }

    my ($txt, $txt_f, $txt_e, $sig_e);
    $txt_e = (get_entity($entity))[0];
    return 'bad' unless $txt_e;

    if ($entity->effective_type() eq 'multipart/signed') {
        # attached signature
        $sig_e = (get_entity($entity, { type => 'application/pgp-signature' }))[0];
        $txt = $txt_e->as_string();
        my $txt_fh;
        ($txt_fh, $txt_f) =
            File::Temp::tempfile('plaintext_XXXXXXXX', DIR => $tmpdir);
        print $txt_fh $txt;
        close $txt_fh;
    } # otherwise, it's clearsigned

    # Validate message.
    # txt_e->bodyhandle->path() is clearsigned message in its entirety.
    # txt_f is the ascii text that was signed (in the event of sig-as-attachment),
    #     with MIME headers attached.
    $gpg_pipe->();
    $gpg_pid =
        $gpg->wrap_call( handles => $gpg_handles,
                         commands => [qw( --trust-model always --verify )],
                         command_args => $sig_e ? 
                             [$sig_e->bodyhandle->path(), $txt_f] :
                             $txt_e->bodyhandle->path()
                    );
    $gpg_cleanup->();
    $ret = $check->();
    if ($ret && $ret != 6) {
        $$gpg_err .= "    $_" while (<$err>);
        return 'bad' if $ret =~ /[35]/;
        return 'not_signed' if $ret =~ /[12]/;
    }

    return 'good' if $ret == 6;
    return undef;
}

# Upload images to a Fotobilder installation.
# Return codes:
# 1 - no images found in mime entity
# undef - failure during upload
# http_code - failure during upload w/ code
# hashref - { title => url } for each image uploaded
sub upload_images
{
    my ($entity, $u, $rv, $opts) = @_;
    return 1 unless LJ::get_cap($u, 'fb_can_upload') && $LJ::FB_SITEROOT;

    my @imgs = get_entity($entity, { type => 'image' });
    return 1 unless scalar @imgs;

    my %images;
    foreach my $img_entity (@imgs) {
        my $img     = $img_entity->bodyhandle;
        my $path    = $img->path;
        
        my ($width, $height) = Image::Size::imgsize($path);

        my ($title, $url) =
        LJ::FBUpload::do_upload($u, $rv,
                                { path    => $path,
                                  rawdata => \$img->as_string,
                                  imgsec  => $opts->{'imgsec'},
                                  galname => $opts->{'galname'},
                                });

        # error posting, we have a http_code (stored in $title)
        return $title if $title && ! $url;
        # error posting, no http_code
        return if $$rv;

        $images{$title} = {
                    'url'    => $url,
                    'width'  => $width,
                    'height' => $height
        };
    }

    return \%images if scalar keys %images;
    return;
}

1;

