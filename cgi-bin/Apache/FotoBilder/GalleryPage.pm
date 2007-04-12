#!/usr/bin/perl
#

package Apache::FotoBilder::GalleryPage;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED);
use POSIX ();

sub handler
{
    my $r = shift;
    my $uri = $r->uri;

    my $uri_components = FB::decode_gallery_uri($uri);
    my $user = $uri_components->{'user'};
    my $gallid = $uri_components->{'gallid'};
    my $auth = $uri_components->{'auth'};
    my $eurl_tag = $uri_components->{'eurl_tag'};

    $user = $FB::ROOT_USER if $FB::ROOT_USER;
    return 404 unless defined $user;

    my $u = FB::load_user($user, undef, [ "styleid" ]);
    return 404 if ! $u || $u->{statusvis} =~ /[DX]/;
    return 403 if $u->{statusvis} eq 'S';

    if ($eurl_tag) {
        my $gal = $u->gallery_of_existing_tag(FB::durl($eurl_tag));
        if ($gal) {
            $gallid = $gal->id;
        } else { # Check if this might be an alias and redirect to primary tag
            $gal = $u->prigal_of_alias(FB::durl($eurl_tag));
            return Apache::FotoBilder::redir($r, $gal->tag_url())
                if $gal;
        }
    } else {
        $gallid = FB::b28_decode($gallid);
        $auth = FB::b28_decode($auth);
    }

    # old API
    my $gal = FB::load_gallery($u, undef, {
        'gallid' => $gallid,
        'withrels' => 1,
        'props' => [ 'styleid' ],
    });

    # new API
    my $galobj = $gal ? FB::Gallery->new($u, $gallid) : undef;

    return 404 unless $gal && $galobj->valid;
    return 404 unless $eurl_tag || $auth == $gal->{'randauth'} % (28**3);
    return 404 if $gal->{'name'} eq ":FB_in";

    my %GET = $r->args;

    my $remote = FB::get_remote();

    # check for gallery visible
    return 404 unless FB::get_cap($u, "gallery_enabled");
    return 403 if FB::get_cap($u, "gallery_private") &&
        (! $remote || $remote->{'userid'} != $u->{'userid'});

    return 403 unless $galobj->visible;

    my $err = sub {
        my $msg = shift;
        $r->log_error("FotoBilder::GalleryPage: $msg");
        return 500;
    };

    my $styleid = ($gal->{'styleid'} || $u->{'styleid'})+0;
    my $ctx = FB::s2_context($r, $styleid);
    return OK unless $ctx;

    FB::S2::set_context($ctx);

    my @allpics = FB::get_gallery_pictures($u, $gal, $u->secin);
    my @pics = @allpics;

    my $page_max = (S2::get_property_value($ctx, "gallery_page_max_size")+0) || 1;
    my $page_min = (S2::get_property_value($ctx, "gallery_page_min_size")+0) || 1;

    my $page = int($GET{'page'}) || 1;
    my $total_subitems = @pics;
    my $pages = POSIX::ceil($total_subitems / $page_max);

    my $url_here = $eurl_tag ? $galobj->tag_url : FB::url_gallery($u, $gal);

    # redirect back to page 1 if their page is beyond the end
    return Apache::FotoBilder::redir($r, "$url_here?page=$pages")
        if $page > 1 && $page > $pages;
    return 404 if $page < 1;

    my $all_shown = 1;
    my $skip = ($page-1) * $page_max;
    if ($skip) {
        splice(@pics, 0, $skip);
        $all_shown = 0;
    }

    if (@pics > $page_max) {
        @pics = @pics[0..$page_max-1];
        $all_shown = 0;
    }
    my $num_subitems = scalar @pics;

    # minimum pictures
    my $dups = 0;
    if ($num_subitems < $page_min && $total_subitems)
    {
        # we give this to S2:
        $dups = $page_min - $num_subitems;

        # now, time to go get this many:
        my $need = $dups;

        # get as many as possible from the previous page
        if ($skip) {
            my $from = $skip - $dups;
            if ($from < 0) { $from = 0; }
            unshift @pics, @allpics[$from .. $skip-1];
            $need -= $skip - $from;
        }

        # if we still need 'em, take what we have on this
        # page and put it at the beginning
        while ($need) {
            my $copysize = $need;
            if ($copysize > @pics) { $copysize = @pics; }
            unshift @pics, @pics[0..$copysize-1];
            $need -= $copysize;
        }
    }

    my $itemrange = FB::S2::ItemRange({
        '_url_of' => sub { "$url_here?page=$_[0]"; },
        'all_subitems_displayed' => $all_shown,
        'num_subitems_displayed' => $num_subitems,
        'total' => $pages,
        'current' => $page,
        'from_subitem' => 1+$skip,
        'to_subitem' => $num_subitems + $skip,
        'total_subitems' => $total_subitems,
    });

    # convert FB hashes to S2 hashes. (loses 'cropfocus', 'pictitle' keys, etc)
    foreach my $pic (@pics) {
        $pic = FB::S2::Picture({
            'u' => $u,
            'pic' => $pic,
            'gal' => $gal,
        });
    }

    # parent links
    my $pl = [];
    my $udbr = FB::get_user_db_reader($u);
    my $sth = $udbr->prepare("SELECT r.gallid, g.randauth, g.name ".
                             "FROM galleryrel r LEFT JOIN gallery g ".
                             "ON g.gallid=r.gallid AND g.userid=r.userid ".
                             "WHERE r.userid=? and r.gallid2=? ORDER BY g.name");
    $sth->execute($u->{'userid'}, $gal->{'gallid'});
    while (my ($id, $randauth, $name) = $sth->fetchrow_array) {
        push @$pl, FB::S2::Link({ 'caption' => ($id ?
                                                $name :
                                                $u->{'user'}), # FIXME: indexcaption
                                  'url' => ($id ?
                                            FB::url_gallery($u, FB::make_code($id, $randauth)) :
                                            FB::url_user($u)),
                                  'dest_view' => ($id ? "gallery" : "index") });
    }

    # get gallery description
    FB::get_des($u, $gal);
    FB::format_des($gal, $ctx);

    my $infourl = $galobj->info_url();
    my $headcontent = qq {
        <link rel="alternate" type="application/fbinfo+xml" title="Fotobilder Info" href="$infourl" />
        };

    my $pg = FB::S2::GalleryPage({
        'u' => $u,
        'r' => $r,
        'gal' => $gal,
        'pictures' => \@pics,
        'styleid' => $styleid,
        'pages' => $itemrange,
        'parent_links' => $pl,
        'dup_pictures' => $dups,
        'head_content' => $headcontent,
    });

    FB::S2::add_child_galleries($pg, $pg->{'gallery'});

    FB::s2_run($r, $ctx, undef, "GalleryPage::print()", $pg);

    return OK;
}

1;
