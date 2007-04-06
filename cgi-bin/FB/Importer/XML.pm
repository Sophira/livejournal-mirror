#!/usr/bin/perl

# XML Importing Library
#
# Mischa Spiegelmock <mischa@sixapart.com>
#

package FB::Importer::XML;
use base FB::Importer;

use strict;

use LWPx::ParanoidAgent;
use HTTP::Request::Common;
use Digest::MD5 qw(md5_hex);
use XML::Simple;

sub do_import {
    my $self = shift;

    return $self->_start_import('fb_import_xml');
}

# called from gearman
# returns string on error, nothing if success
sub _do_import {
    my ($self, $job, @importedurls) = @_;

    my $u = $self->{u};
    my $url = $self->{url};
    my $recurse = $self->{recurse};

    return undef unless $u;

    $self->{job} = $job;

    my $xmlurl;

    # is this already the XML document?
    $xmlurl = $url if ($url =~ /\.xml$/);

    my $ua = LWPx::ParanoidAgent->new();
    $ua->agent("FotoBilder_XMLImport/1.0");

    if (!$xmlurl) {
        # get the HTML doc, parse out the link rel
        my $req = HTTP::Request->new(GET => $url) or return $self->err("Error");

        $ua->timeout(2);
        my $res = eval { $ua->request( $req ) };

        return $self->err("Error fetching URL $url: \n$@ \n" . $res->decoded_content);

        # no luck retreiving doc, give our sob story
        if (!$res->is_success) {
            if ($res->code == 404) {
                return $self->err("The URL you entered does not exist.");
            } else {
                return $self->err($res->decoded_content);
            }
        }

        # request successful, look for link rel
        my $html = $res->decoded_content;
        if (!$html) {
            # document is empty.
            return $self->err("No data at $url");
        }

        # scan page for XML data link
        while ($html =~ m!<(link|meta)\b([^>]+)>!gi) {
            my ($type, $val) = ($1, $2);
            # <link rel="alternate" type="application/fbinfo+xml" href="http://...." />
            if ($type eq "link" &&
                $val =~ m!rel=.alternate.!i &&
                $val =~ m!type=.application/fbinfo\+xml.!i &&
                $val =~ m!href=[\"\']([^\"\']+)[\"\']!i) {
                $xmlurl = $1;
            }
        }

        # did we get an infourl?
        return $self->err("<b>$url</b> did not contain any picture information.\nYou must input a URL of a gallery or picture.")
            if (!$xmlurl);

        # is this relative?
        if (! ($xmlurl =~ m!^http://!i)) {
            # make it absolute
            my $absolute_uri = $res->base;
            # strip off document name
            $absolute_uri =~ s!/[^/]+$!/!;
            $xmlurl = $absolute_uri . $xmlurl;
        }
    }

    $self->_set_status(0, 0);

    my $res = $ua->request( HTTP::Request->new(GET => $xmlurl) );

    push @importedurls, $xmlurl;

    # XML url is bad?
    return $self->err($res->decoded_content) unless $res->is_success();

    # request successful, parse!
    my $xml = $res->decoded_content;
    return $self->err("No information available.") unless $xml;

    my $xml_simple = new XML::Simple(
                                     'KeyAttr' => {
                                         'digest'      => 'type',
                                     },
                                     'SuppressEmpty'   => undef,
                                     );

    my $doc = eval { $xml_simple->XMLin($xml, ('KeepRoot' => 1)) };
    return $self->err("Error parsing XML document: $@") unless $doc;

    # Note: the camelCase variables are used here to distinguish XML elements

    # is it a gallery or a mediaSetItem?
    my $isgallery = $doc->{mediaSet} ? 1 : 0;

    if ($isgallery) {
        my $mediaSet = $doc->{mediaSet};
        my $gal_name = $mediaSet->{title} || 'Imported'; # TODO: ask for name
        my $gal_desc = $doc->{description} || '';

        # clean gal_name
        $gal_name = FB::Gallery->clean_name($gal_name)
            or return err("Invalid gallery name: $gal_name");

        # create new gallery
        my $g = FB::Gallery->create($u, name => $gal_name)
            or return err("Could not create gallery.");

        $g->link_from(0);

        $g->set_des($gal_desc) if $gal_desc;

        # TODO: date

        # import mediaSetItems
        my $mediaSetItems = $mediaSet->{mediaSetItems}->{mediaSetItem} || [];

        # are we recursively importing linked galleries?
        my $linkedUrls = [];
        if ($recurse && $mediaSet->{linkedTo}) {
            my $linkedTo = $mediaSet->{linkedTo};
            $linkedUrls = $linkedTo->{infoUrl};
        }

        my $total = scalar @$mediaSetItems;
        $self->_set_status(0, $total);
        my $count = 0;
        foreach my $mediaSetItem (@$mediaSetItems) {
            $self->import_media($g, $mediaSetItem);
            $count++;
            $self->_set_status($count, $total);
            sleep 1;
        }

        my @taskhandles;

        # import linked galleries
        foreach my $importurl (@$linkedUrls) {
            $self->_set_status(0, 0);
            # recursively import
            my $importer = FB::Importer::XML->new((
                                                   u => $self->{u},
                                                   url => $importurl,
                                                   recurse => $self->{recurse},
                                                   importedurls => \@importedurls,
                                                   ))
                or return $self->err("Could not create XML importer");
            push @taskhandles, $importer->do_import;
        }

        # indefinite
        $self->_set_status(0, 0);

        # wait until all subjobs are done, keep track of overall status
        my $anyrunning;
        do {
            my $totalprogress = 0;
            my $completeprogress = 0;
            $anyrunning = 0;

            foreach my $task (@taskhandles) {
                # get status
                my $status;

                if (@FB::GEARMAN_SERVERS) {
                    my $client = Gearman::Client->new;
                    $client->job_servers(@FB::GEARMAN_SERVERS);
                    $status = $client->get_status($task);
                }

                next unless $status;

                my $prog = $status->progress || [0,0];
                my $running = $status->running;

                $anyrunning ||= $running;

                $completeprogress += $prog->[0];
                $totalprogress += $prog->[1];
            }
            $self->_set_status($completeprogress, $totalprogress);
        } while ($anyrunning);
    } else {
        # create new gallery
        # TODO: allow user to set name of gallery
        my $g = FB::Gallery->create($u, name => 'Imported')
            or return err("Could not create gallery.");

        $self->import_media($g, $doc->{mediaSetItem}) if $doc->{mediaSetItem};
    }
    $self->_set_status(1, 1);

    return 0;
}

# args: gallery, xml root
sub import_media {
    my ($self, $g, $root) = @_;

    return unless ($g && $root);

    my $u = $self->{u};

    # title/desc
    my $title = $root->{title} || '';
    my $desc = $root->{description} || '';

    # TODO: date

    # get file
    my $filedata = $root->{file};
    my $digesttype = $filedata->{digest}->{type};
    my $digest = $filedata->{digest}->{content};
    my $url = $filedata->{url};
    my $mime = $filedata->{mime};
    my $bytes = $filedata->{bytes};
    my $fmtid = FB::mime_to_fmtid($mime);

    # tags
    my $taglist;
    if (ref $filedata->{tag} eq 'ARRAY') {
        my $tags = $filedata->{tag} || [];
        my @tagnames = map { $_->{name} } @$tags;
        $taglist = join(',', @tagnames);
    } elsif ($filedata->{tag}->{name}) {
        $taglist = $filedata->{tag}->{name};
    }

    my $up;
    # do we already have this?
    # TODO: support other digest types
    my $gpicid = FB::find_equal_gpicid($digest, $bytes, $fmtid, 1);

    if ($gpicid) {
        # we already have a gpic, create a upic for this user
        $up = FB::Upic->create($u, $gpicid) or return undef;
    } else {
        # download the file
        my $ua = LWPx::ParanoidAgent->new;
        $ua->agent("FotoBilder_XMLImport/1.0");

        my $res = $ua->request( HTTP::Request->new(GET => $url));
        return undef unless $res->is_success;

        my $mediadata = $res->decoded_content or return undef;

        # create a new Gpic
        my $gp = FB::Gpic->new;

        # we have picture data, store it
        $gp->append($mediadata);
        $gp->save;

        $up = FB::Upic->create($u, $gp->id);
    }

    return undef unless $up;

    $up->set_des($desc) if $desc;
    $up->set_tags($taglist) if $taglist;
    $up->set_title($title) if $title;

    $g->add_picture($up);
}

sub err {
    my ($self, $err) = @_;

    print STDERR "err: $err\n" if $FB::IS_DEV_SERVER;

    return $err;
}

1;
