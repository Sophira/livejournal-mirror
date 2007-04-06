#!/usr/bin/perl

package FB::Protocol::GetSecGroups;

use strict;

sub handler {
    my $resp = shift or return undef;
    my $req  = $resp->{req};
    my $vars = $req->{vars};
    my $u = $resp->{u};

    my $err = sub {
        $resp->add_method_error(GetSecGroups => @_);
        return undef;
    };

    my $ret = { SecGroup => [] };

    my $groups = FB::load_secgroups($u);
    # always returns true

    if (%$groups) {

        my $grpmem = FB::load_secmembers_multi($u, [ keys %$groups ]);
        return $err->(500 => FB::last_error()) unless ref $grpmem eq 'HASH';

        foreach my $grp (values %$groups) {
            my $secid = $grp->{secid};

            my $grpret = { id           => $secid, 
                           Name         => [ $grp->{grpname} ],
                           GroupMembers => {},
                       };

            foreach my $mem (values %{$grpmem->{$secid}}) {
                push @{$grpret->{GroupMembers}->{GroupMember}||=[]}, {
                    id   => $mem->{userid},
                    user => $mem->{user},
                };
            }

            push @{$ret->{SecGroup}}, $grpret;
        }
    }

    # register return value with parent Request
    $resp->add_method_vars(GetSecGroups => $ret);

    return 1;
}

1;
