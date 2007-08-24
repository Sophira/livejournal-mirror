package LJ::AdPage;

use strict;
use Carp qw(croak);

# ident: UpdatePage
# locations: top, bottom, left, right

sub new {
    my $class = shift;
    my %opts = @_;

    my $self = { 
        ident      => $opts{ident},
        for_u      => $opts{for_u},
        adunit_map => {}, # location => [ units ]
    };
    bless $self, $class;

    $self->{for_u} ||= LJ::get_remote();

    croak "invalid ad unit: $self->{ident}"
        unless $self->is_valid_ident;

    $self->build_adunit_map;

    return $self;
}

sub ident {
    my $self = shift;
    return $self->{ident};
}

sub for_u {
    my $self = shift;
    return $self->{for_u};
}

sub is_valid_ident {
    my $self = shift;

    return $self->conf ? 1 : 0;
}

sub supported_locations {
    my $self = shift;

    return map { LJ::AdLocation->new( ident => $_ ) } keys %{$self->conf('accept') || {}};
}

sub accept_map_for_location {
    my $self = shift;
    my $adlocation = shift;

    my $map = $self->accept_map->{$adlocation->ident};
    $map = [ $map ] unless ref $map->[0] eq 'ARRAY';
    
    return @$map;
}

sub accept_map {
    my $self = shift;

    return $self->conf('accept');
}

sub want_adunits {
    my $self = shift;

    my $rv = $self->conf('units') || {};
    return $rv;
}

sub adunit_want_map {
    my $self = shift;

    my $want_adunits = $self->want_adunits;

    # adunit, adunit, adunit, adunit...
    my @map = ();
    while (my ($unit, $ct) = each %$want_adunits) {
        push @map, map { $unit } 1..$ct;
    }

    return @map;
}

sub adunit_map {
    my $self = shift;

    if (@_) {
        my %map  = @_;
        return $self->{adunit_map} = \%map;
    }

    return $self->{adunit_map};
}

sub build_adunit_map {
    my $self = shift;

    my @want_map = $self->adunit_want_map;
    my %want_map = ();
    $want_map{$_}++ foreach @want_map;

    my $want_str = join(" ", sort @want_map);

    # 1) short-cut case: does any one ad location satisfy the entire want map?
    foreach my $adlocation ($self->supported_locations) {
        my @accept_map = $self->accept_map_for_location($adlocation);

        foreach my $accept_term (@accept_map) {
            my $term_str = join(" ", sort @$accept_term);

            if ($term_str eq $want_str) {
                return $self->adunit_map($adlocation->ident => $accept_term);
            }

        }
    }

    # 2) okay, it wasn't so easy.  try to find an acceptable way to satisfy with
    #    multiple ad locations
    my %adunit_map = ();
    my $satisfy = sub {
        my ($adlocation_ident, $adunit_ident) = @_;

        if ($want_map{$adunit_ident} > 1) {
            $want_map{$adunit_ident}--;
        } else {
            delete $want_map{$adunit_ident};
        }

        push @{$adunit_map{$adlocation_ident}}, $adunit_ident;
    };

  ADLOCATION:
    foreach my $adlocation ($self->supported_locations) {

        # are we finished?
        last unless %want_map;

        my @accept_map = $self->accept_map_for_location($adlocation);

        # sort in reverse order of scalar size
        foreach my $accept_term (sort { @$b <=> @$a } @accept_map) {
            my $term_str = join(" ", sort @$accept_term);

            # are all elements of this accept term in the want_map?
            my $all_apply = 1;
            foreach (@$accept_term) {
                next if $want_map{$_};
                $all_apply = 0;
                last;
            }
            unless ($all_apply) {
                next;
            }

            # all elements of this accept term applied, that's some progress
            foreach (@$accept_term) {
                $satisfy->($adlocation->ident, $_);
            }
            next ADLOCATION;
        }
    }

    # it's possible we get to here and don't have all wanted units satisfied
    if ($LJ::IS_DEV_SERVER && %want_map) {
        warn "unsatisfied want_map: " . LJ::D(\%want_map);
    }

    return $self->adunit_map(%adunit_map);
}

# given a location, which adunits should be displayed?
sub adunits_for_location {
    my $self = shift;
    my $adlocation = shift;

    # allow an ident string to be passed
    my $ident = ref $adlocation ? $adlocation->ident : $adlocation;

    my $adunit_map = $self->adunit_map;
    my $for_u = $self->for_u;
    return map { LJ::AadUnit->new( for_u => $for_u, ident => $_ ) } @{$adunit_map->{$adlocation} || []};
}

sub adcalls_for_location {
    my $self = shift;
    my $adlocation = shift;

    my @adunits = $self->adunits_for_location($adlocation);

    my $ret = "";
    foreach my $adunit (@adunits) {
        $ret .= LJ::ads(
                        type   => 'app',
                        orient => 

    }

}

sub conf {
    my $self = shift;
    my $key  = shift;

    my $for_u = $self->for_u;

    # use default config
    my $conf = \%LJ::AD_PAGE;

    # can be overridden by tests
    if (%LJ::T_AD_PAGE) {
        $conf = \%LJ::T_AD_PAGE;
    }

    # allow a hook to override config (of same format) per-user
    my $hook_conf = LJ::run_hook("ad_page_config", $for_u);
    if ($hook_conf) {
        $conf = $hook_conf;
    }

    my $ident = $self->ident;
    return undef unless $conf->{$ident};
    return $conf->{$ident}->{$key} if $key;
    return $conf->{$ident};
}

1;
