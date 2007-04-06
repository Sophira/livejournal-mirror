#!/usr/bin/perl

package FB::Protocol::GetPics;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars};
    my $u = $resp->{u};

    my $err = sub {
        $resp->add_method_error(GetPics => @_);
        return undef;
    };

    my $ret = { Pic => [] };
    my $upics = FB::upics_of_user($u, { props => [ qw(filename pictitle) ] });
    return $err->(500 => FB::last_error) unless ref $upics eq 'HASH';

    if (%$upics) {

        # get md5s of all the gpics
        my $gpic_md5      = FB::get_gpic_md5_multi([ map { $_->{gpicid} } values %$upics ]);
        return $err->(500 => FB::last_error()) unless ref $gpic_md5 eq 'HASH';

        my @pics_with_des = FB::get_des_multi($u, 'P', [ values %$upics ]);
        return $err->(500 => FB::last_error()) unless ref $pics_with_des[0] eq 'HASH';

        foreach my $pic (sort { $a->{upicid} <=> $b->{upicid} } @pics_with_des) {

            push @{$ret->{Pic}}, {
                id         => $pic->{upicid},
                Sec        => [ $pic->{secid} ],
                Width      => [ $pic->{width} ],
                Height     => [ $pic->{height} ],
                Bytes      => [ $pic->{bytes} ],
                Format     => [ FB::fmtid_to_mime($pic->{fmtid}) ],
                MD5        => [ FB::bin_to_hex($gpic_md5->{$pic->{gpicid}}) ],
                URL        => [ FB::url_picture($u, $pic) ],
                Meta       => [ map { 
                                     { name    => $_->[0], 
                                       content => $pic->{$_->[1]} }
                                    } (['filename'    => 'filename' ],
                                       ['title'       => 'pictitle' ],
                                       ['description' => 'des'      ])
                              ],
            };
        }
    }

    # register return value with parent Request
    $resp->add_method_vars(GetPics => $ret);

    return 1;
}

1;
