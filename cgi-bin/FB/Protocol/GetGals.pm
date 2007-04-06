#!/usr/bin/perl

package FB::Protocol::GetGals;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars};
    my $u = $resp->{u};

    my $err = sub {
        $resp->add_method_error(GetGals => @_);
        return undef;
    };

    my $gals = FB::gals_of_user($u);
    return $err->(500) unless ref $gals;

    my $ret = { Gal => [] };

    if (%$gals) {

        # load gallery rels and pic rels for use later
        my @gal_rel = FB::user_galleryrel($u);
        my @pic_rel = FB::user_gallerypics($u);

        while (my ($gallid, $gal) = each %$gals) {
            my $gal_ret = { id         => $gallid,
                            Name       => [ FB::transform_gal_name($gal->{name}) ],
                            Sec        => [ $gal->{secid} ],
                            Date       => [ $gal->{dategal} ],
                            TimeUpdate => [ $gal->{timeupdate} ],
                            URL        => [ FB::url_gallery($u, $gal) ],
                        };

            # is this the incoming gallery?
            $gal_ret->{incoming} = 1 if FB::gal_is_unsorted($gal);

            # GalMembers
            $gal_ret->{GalMembers}->{GalMember} = 
                [ map { { id => $_->{upicid} } }
                  grep { $_->{gallid} == $gallid }
                  @pic_rel ];

            # ParentGals
            $gal_ret->{ParentGals}->{ParentGal} = 
                [ map { { id => $_->{gallid}, sortorder => $_->{sortorder} } }
                  grep { $_->{gallid2} == $gallid && $_->{type} eq 'C' }
                  @gal_rel ];

            # ChildGals
            $gal_ret->{ChildGals}->{ChildGal} = 
                [ map { { id => $_->{gallid2}, sortorder => $_->{sortorder} } }
                  grep { $_->{gallid} == $gallid && $_->{type} eq 'C' }
                  @gal_rel ];

            push @{$ret->{Gal}}, $gal_ret;
        }
    }

    # register return value with parent Request
    $resp->add_method_vars(GetGals => $ret);

    return 1;
}

1;
