#!/usr/bin/perl

package FB::Protocol::GetGalsTree;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars};
    my $u = $resp->{u};

    my $err = sub {
        $resp->add_method_error(GetGalsTree => @_);
        return undef;
    };

    my $gals = FB::gals_of_user($u);
    return $err->(500) unless ref $gals;

    my $ret = {
        RootGals        => [ { Gal => [ ] } ],
        UnreachableGals => [ { Gal => [ ] } ],
    };

    if (%$gals) {

        # load gallery rels and pic rels for use later
        my @gal_rel = FB::user_galleryrel($u);
        my @pic_rel = FB::user_gallerypics($u);

        # build a data structure of parent gallids => array of their children
        my %parents  = ();
        my %children = ();
        foreach (grep { $_->{type} eq 'C' } @gal_rel) {
            my ($pid, $cid) = ($_->{gallid}, $_->{gallid2});
            push @{$children{$pid}}, $gals->{$cid};
            push @{$parents{$cid}}, $gals->{$pid};
            $gals->{$cid}->{sortorder} = $_->{sortorder};
        }

        # resets every visit to top-level (0)
        my %seen = ();
        my %unreachable = map { $_ => 1 } keys %$gals;

        my $recurse;
        $recurse = sub {
            my $gal = shift;
            my $gallid = $gal->{gallid};

            # since we've visited this gallery, it's not unreachable
            delete $unreachable{$gallid};

            my $node = { id         => $gallid,
                         sortorder  => $gal->{sortorder}+0,
                         Name       => [ FB::transform_gal_name($gal->{name}) ],
                         Sec        => [ $gal->{secid} ],
                         Date       => [ $gal->{dategal} ],
                         TimeUpdate => [ $gal->{timeupdate} ],
                         URL        => [ FB::url_gallery($u, $gal) ],
                     };

            # is this the incoming gallery?
            $node->{incoming} = 1 if FB::gal_is_unsorted($gal);

            # GalMembers
            $node->{GalMembers}->{GalMember} = 
                [ map { { id => $_->{upicid} } }
                  grep { $_->{gallid} == $gallid }
                  @pic_rel ];

            # now the hard part: ChildGals
            $node->{ChildGals}->{Gal} = 
                [ map  { $recurse->($_) } 
                  sort { $a->{sortorder} <=> $b->{sortorder} || $a->{gallid} <=> $b->{gallid} }
                  grep { ! $seen{$_->{gallid}}++ } 
                  @{$children{$gallid}} ];

            return $node;
        };

        # start at parent (top-level) node and built tree
        # of all its children
        foreach my $child (@{$children{0}}) {
            %seen = ( $child->{gallid} => 1 );
            push @{$ret->{RootGals}->[0]->{Gal}}, $recurse->($child);
        }

        # represent any galleries that were unreachable, recursing down
        # from each gallery that has no parents
        foreach my $gal (map  { $gals->{$_} }
                         sort { $gals->{$a}->{sortorder} <=> $gals->{$b}->{sortorder} ||
                                $gals->{$a}->{gallid} <=> $gals->{$b}->{gallid} }
                         keys %unreachable) {

            %seen = ( $gal->{gallid} => 1 );
            push @{$ret->{UnreachableGals}->[0]->{Gal}}, $recurse->($gal);
        }
    }

    # register return value with parent Request
    $resp->add_method_vars(GetGalsTree => $ret);

    return 1;
}

1;
