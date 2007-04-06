#!/usr/bin/perl

package FB::Protocol::CreateGals;

use strict;

# FIXME: perhaps add support for adding multiple 
#        parents/children by ParentID and/or Path?

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars}->{CreateGals};
    my $u = $resp->{u};

    my $ret = { Gallery => [] };

    my $err = sub {
        $resp->add_method_error(CreateGals => @_);
        return undef;
    };

    return $err->(212 => 'Gallery')
        unless defined $vars->{Gallery};

    return $err->(211 => 'CreateGals')
        unless ref $vars->{Gallery} eq 'ARRAY' && @{$vars->{Gallery}};

    # to which galleries should this picture be added?
    my @gals;
  GALLERY:
    foreach my $gvar (@{$vars->{Gallery}}) {

        # FIXME: make sure that gallery doesn't already exist,
        #        case is different from uploadpic

        # existence of GalName is required
        return $err->(212 => 'GalName')
            unless exists $gvar->{GalName};

        # exists but not defined?
        my $galname = $gvar->{GalName};
        return $err->(211 => 'GalName')
            unless defined $galname;

        # defined but not valid?
        return $err->(211 => "Malformed gallery name: $galname")
            unless FB::valid_gallery_name($galname);

        # check for invalid argument interactions
        return $err->(211 => "Can't specify both ParentID and Path when adding to gallery")
            if exists $gvar->{ParentID} && exists $gvar->{Path};

        # check that GalSec was valid, if it was specified
        my $galsec = exists $gvar->{GalSec} ? $gvar->{GalSec} : 255;
        return $err->(211 => "Invalid GalSec value")
            unless defined $galsec && FB::valid_security_value($u, \$galsec);

        # check against existence of undefined values:
        foreach (qw(ParentID GalDate)) {
            return $err->(211 => $_) 
                if exists $gvar->{$_} && ! defined $gvar->{$_};
        }

        # check that ParentID was valid, if it was specified
        my $parentid = exists $gvar->{ParentID} ? $gvar->{ParentID} : 0;
        return $err->(211 => "ParentID must be a non-negative integer")
             if ! defined $parentid || $parentid =~ /\D/ || $parentid < 0;

        # check gallery names in Path
        my @path = @{$gvar->{Path}||[]};
        foreach (@path) {
            next if defined $_ && FB::valid_gallery_name($_);
            return $err->(211 => [ "Malformed gallery name in Path" => $_ ]);
        }

        # if no path was specified, and the parentid is 0 only because
        # it defaulted to that, then the gallery we create will be 
        # top-level
        my $top_level = ! @path && $parentid == 0 ? 1 : 0;

        # check that GalDate was valid, if it was specified
        my $galdate = FB::date_from_user($gvar->{GalDate});
        return $err->(211 => "Malformed date: $galdate")
            if exists $gvar->{GalDate} && ! defined $galdate;
        
        # goal from here on is to find what gals this 'Gallery' struct refers to, 
        # we'll create those galleries as needed
        
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

            # for error reporting if necessary later
            my $pathstr = join(" / ", @path);

            my $pid = 0;
          PATH:
            while (@path) {
                my $currname = shift @path;

                # FIXME: pretty sure this could be further optimized

                # see if the parent of the path thus far exists
                my $gal = $udbh->selectrow_hashref
                    ("SELECT g.* FROM gallery g, galleryrel gr ".
                     "WHERE g.userid=? AND g.name=? AND gr.userid=g.userid ".
                     "AND gr.gallid2=g.gallid AND gr.gallid=? AND gr.type='C' ".
                     "ORDER BY gr.sortorder LIMIT 1",
                     undef, $u->{userid}, $currname, $pid);
                return $err->(502) if $udbh->err;

                # if we've reached the end of the path and the gallery being
                # referenced already exists, then error.
                return $err->(211 => "Gallery already exists: $pathstr")
                    if @path == 0 && $gal;

                # gal didn't exist, create and set that as parent
                unless ($gal) {
                    $gal = FB::create_gallery
                        ($u, $currname, $galsec, $pid, 
                         @path == 0 ? { dategal => $galdate } : {})
                        or return $err->(512 => FB::last_error());

                    if (@path == 0) {
                        push @{$ret->{Gallery}}, { GalID   => [ $gal->{gallid} ],
                                                   GalName => [ $galname ],
                                                   GalURL  => [ FB::url_gallery($u, $gal) ] };
                    }
                }

                # parent is either the gallery we just looked up or the
                # one we just created
                $pid = $gal->{gallid};

                next PATH;
            }

            # move on to the next gallery record
            next GALLERY;
        }

        # if a name was specified with a ParentID, then create a gallery
        # named GalName that is also a child of $parentid.  it is possible
        # that the parentid was set to 0 because no parentid was specified, 
        # meaning that the gallery should be created top-level
        if (defined $parentid && $parentid > 0 || $top_level) {

            # does the specified parent gallery even exist?
            my $pgal = undef;
            unless ($top_level) {
                $pgal = FB::load_gallery_id($u, $parentid)
                    or return $err->(211 => "Parent gallery does not exist: $parentid");
            }

            my $rows = $udbh->selectrow_array
                ("SELECT COUNT(*) FROM gallery g, galleryrel gr ".
                 "WHERE g.userid=? AND g.name=? AND gr.userid=g.userid ".
                 "AND gr.gallid2=g.gallid AND gr.gallid=? AND gr.type='C'",
                 undef, $u->{userid}, $galname, $parentid);
            return $err->(502) if $udbh->err;

            # gallery already existed?
            if ($rows) {
                my @galpath = ($galname);
                unshift @galpath, $pgal->{name} if $pgal;
                return $err->(512 => "Gallery aready exists: " . join('/', @galpath));
            }
                
            # create a new gallery
            my $gal = FB::create_gallery
                ($u, $galname, $galsec, $parentid, { dategal => $galdate })
                or return $err->(512 => FB::last_error());

            push @{$ret->{Gallery}}, { GalID   => [ $gal->{gallid} ],
                                       GalName => [ $galname ],
                                       GalURL  => [ FB::url_gallery($u, $gal) ] };


            next GALLERY;
        }

        next GALLERY;
    }

    # register return value with parent Request
    $resp->add_method_vars(CreateGals => $ret);

    return 1;
}

1;
