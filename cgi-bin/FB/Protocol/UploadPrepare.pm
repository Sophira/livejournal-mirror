#!/usr/bin/perl

package FB::Protocol::UploadPrepare;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars}->{UploadPrepare};
    my $u = $resp->{u};

    my $err = sub {
        $resp->add_method_error(UploadPrepare => @_);
        return undef;
    };

    return $err->(212 => "Pic") unless exists $vars->{Pic};

    my $picarr = $vars->{Pic};
    return $err->(211 => "Pic") unless ref $picarr eq 'ARRAY';

    my $ret = {};

    # look up quota and usage information to return with this request
    if (FB::are_hooks('disk_usage_info')) {

        my $qinf = FB::run_hook('disk_usage_info', $u);
        if (ref $qinf eq 'HASH') {
            $ret->{Quota} = {
                Total     => [ $qinf->{quota} * (1 << 10) ], # kb -> bytes
                Used      => [ $qinf->{used}  * (1 << 10) ],
                Remaining => [ $qinf->{free}  * (1 << 10) ],
            };
        }
    }


  PIC:
    foreach my $pic (@$picarr) {

        # default values to return, override later
        my $picret = {
            MD5   => [ $pic->{MD5} ],
            known => 0,
        };

        # err subref, notes error in $picret and goes to next PIC in array
        my $picerr = sub {

            $picret->{Error} = {
                code    => $_[0],
                content => $resp->error_msg(@_),
            };

            # add to final return structure
            push @{$ret->{Pic}}, $picret;

            next PIC;
        };

        # check existence of required vars
        foreach (qw(Size MD5 Magic)) {
            $picerr->(212 => $_) unless exists $pic->{$_};
        }

        # validate Size argument
        my $size = $pic->{Size};
        $picerr->(211 => "Size")
            unless $size =~ /^\d+$/ && $size > 0;

        # valid MD5 argument
        my $md5 = $pic->{MD5};
        $picerr->(211 => "MD5")
            unless $md5 =~ /^[a-f0-9]{32}$/;

        # validate Magic argument
        my $magic = $pic->{Magic};
        $picerr->(211 => "Magic")
            unless $magic =~ /^[a-f0-9]{20}$/;

        my $fmtid = FB::fmtid_from_magic(FB::hex_to_bin($magic))
            or $picerr->(211 => [ "Magic" => "Invalid Image Format" ]);

        ### everything's validated now, make a response

        if ( my $gpicid = FB::find_equal_gpicid($md5, $size, $fmtid, 'verify_paths') ) {

            # if we got a gpic, then it still could not belong to us.  we'll try to load
            # any upics pointing to that gpic which we own, then see if a receipt should
            # be given
            if (my $upic = FB::load_upic_by_gpic($u, $gpicid, { force => 1 })) {

                # found a pic, fill in known=1, id, receipt

                # FIXME: later should possibly check gpicids of friends
                #        and mark them as 'known' with no 'id' ?
                $picret->{known} = 1;
                $picret->{id}    = $upic->{upicid};

                # make a receipt to give to the user
                my $rcptkey = FB::rand_chars(20);
                FB::save_receipt($u, $rcptkey, 'P', $gpicid)
                    or $picerr->(500 => [ "Unable to create receipt" => FB::last_error() ]);

                $picret->{Receipt} = [ $rcptkey ];
            }
        }

        # add to final return structure
        push @{$ret->{Pic}}, $picret;
    }

    # register return value with parent Request
    $resp->add_method_vars(UploadPrepare => $ret);

    return 1;
}

1;
