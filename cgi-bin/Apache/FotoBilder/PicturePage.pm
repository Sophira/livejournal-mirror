#!/usr/bin/perl
#

package Apache::FotoBilder::PicturePage;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED);

sub handler
{
    my ($r, $u, $up, $gallid) = @_;
    return 404 unless $up && $up->valid && $u;
    return 404 if $u->{statusvis} =~ /[DX]/;

    # auto-rotate the picture (for old pictures that were uploaded
    # before the auto-rotate-on-upload code)
    $up->autorotate;

    FB::load_user_props($u, "styleid");

    my $err = sub {
        my $msg = shift;
        $r->log_error("FotoBilder::PicturePage: $msg");
        return 500;
    };

    my $remote = FB::get_remote();

    # check for gallery visible
    return 403 unless $u->{statusvis} eq 'V';
    return 404 unless FB::get_cap($u, "gallery_enabled");
    return 403 if FB::get_cap($u, "gallery_private") &&
        (! $remote || $remote->{'userid'} != $u->{'userid'});

    my $styleid = $u->{'styleid'}+0;

    # could be attached to a gallery
    my $gal;
    my $itemrange;
    my $current;  # position within gallery
    my $picprev;
    my $picnext;

    if ($gallid) {
        $gal = FB::Gallery->new($u, $gallid);

        # redirect to picture page without gallery arg if gallery is deleted
        return Apache::FotoBilder::redir($r, $up->url_picture_page)
            unless $gal && $gal->visible;

        # find pictures in this gallery to scroll between
        my @pics = $gal->visible_pictures;
        my $i = 0;
        foreach (@pics) {
            $i++;
            next unless $_->id == $up->id;
            $current = $i;
            last;
        }

        # picture not in this gallery
        return Apache::FotoBilder::redir($r, $up->url_picture_page)
            unless $current;

        # setup the item range
        $itemrange = FB::S2::ItemRange({
            '_url_of' => sub { FB::url_picture_page($u, $pics[$_[0]-1], $gal); },
            'total' => scalar @pics,
            'current' => $current,
        });

        # setup previous and next pictures since we already have them... funky math because
        # $current is 1 based whereas @pics is 0 based so we really want to offset somewhat
        $picprev = $pics[$current-2] if $current > 1;
        $picnext = $pics[$current] if $current < scalar(@pics);

        # set custom style for gallery
        $styleid = $gal->prop('styleid') if $gal && $gal->prop('styleid');
    } else {
        return 403 unless $up->visible;
        # note: other path of if statement ensures access control by
        #       redirecting to URL with /g<n> suffix if picture isn't
        #       returned from get_gallery_pictures, then we get here.
    }

    my $ctx = FB::s2_context($r, $styleid);
    return OK unless $ctx;
    FB::S2::set_context($ctx);

    # what gals is this pic in?
    my @gals = (sort { $a->raw_name cmp $b->raw_name } $up->visible_galleries);
    my @taglinks; my @tags;

    foreach my $g (@gals) {
        push @tags, $g if $g->tag;
    }

    if (@tags) {
        foreach my $g (@tags) {
            push @taglinks, FB::S2::Link({ 'caption' => $g->tag,
                                           'url' => $g->tag_url,
                                           'dest_view' => 'gallery' });
        }
    }

    # top-level index link
    my $tl = FB::S2::Link({ 'caption' => $u->{'user'}, # FIXME: indexcaption
                            'url' => $u->url,
                            'dest_view' => 'index' });

    # TODO: make the trails, finding a primary trail by:
    # -- prefer trails ending in $gal, if we have a $gal
    # -- give higher priority to dated galleries, and less to dateless

    # parent link and links
    # -- go through all trails, taking last link
    # -- for primary parent, take last link of primary trail

    my @pl;
    if ($gal) {
        my $url = $gal->url;
        if (defined $current) {
            my $pagesize = (S2::get_property_value($ctx, "gallery_page_max_size")+0) || 1;
            my $pagein = int(($current-1) / $pagesize) + 1;
            $url .= "?page=$pagein";
        }
        push @pl, FB::S2::Link({ 'caption' => $gal->display_name,
                                 'url' => $url,
                                 'dest_view' => 'gallery' });
        foreach my $g (@gals) {
            next if $g->tag;
            next if $g->id == $gal->id;  # already did it above
            push @pl, FB::S2::Link({ 'caption' => $g->display_name,
                                     'url' => $g->url,
                                     'dest_view' => 'gallery' });
        }

    } else {
        foreach my $g (@gals) {
            next if $g->tag;
            push @pl, FB::S2::Link({ 'caption' => $g->display_name,
                                     'url' => $g->url,
                                     'dest_view' => 'gallery' });
        }
    }

    # primary parent link is first one
    my $pl = $pl[0];  # FIXME: make this smarter:  parent link to first non-tag gallery

    my $infourl = $up->info_url();
    my $headcontent = qq {
        <link rel="alternate" type="application/fbinfo+xml" title="Fotobilder Info" href="$infourl" />
        };


    my $page = FB::S2::PicturePage({
        'u' => $u,
        'r' => $r,
        'pic' => $up,
        'styleid' => $styleid,
        'pictures' => $itemrange,
        'picture_prev' => $picprev,
        'picture_next' => $picnext,
        'gal' => $gal,
        'parent_link' => $pl,
        'parent_links' => \@pl,
        'tags' => \@taglinks,
        'head_content' => $headcontent,
    });

    FB::s2_run($r, $ctx, undef, "PicturePage::print()", $page);
    return OK;
}

1;

