package LJ::AdUnit;

use strict;
use Carp qw(croak);

# width:  768
# height:  90

sub new {
    my $class = shift;
    my %opts = @_;

    my $self = { 
        ident  => $opts{ident},
        for_u  => $opts{for_u},
        width  => $opts{width},
        height => $opts{height},
    };
    bless $self, $class;

    $self->{for_u} ||= LJ::get_remote();

    # if this ident is configured in %LJ::AD_TYPE, we can guess the 
    # width / height from there
    if (my $type = $self->conf) {
        $self->{width}  ||= $type->{width};
        $self->{height} ||= $type->{height};
    }

    unless ($self->is_valid_adunit) {
        croak "invalid ad unit: $self->{ident} (" . 
            join("x", $self->{width}+0, $self->{height}+0) . ")";
    }

    return $self;
}

sub is_valid_adunit {
    my $self = shift;
    
    my $conf = $self->conf;
    return 0 unless $conf;
    return 0 unless $conf->{width} == $self->width;
    return 0 unless $conf->{height} == $self->height;

    return 1;
}

sub ident {
    my $self = shift;
    return $self->{ident};
}

sub for_u {
    my $self = shift;
    return $self->{for_u};
}

sub width {
    my $self = shift;
    return $self->{width};
}

sub height {
    my $self = shift;
    return $self->{height};
}

sub conf {
    my $self = shift;
    my $key  = shift;

    # use default config
    my $conf = \%LJ::AD_TYPE;

    # can be overridden by tests
    if (%LJ::T_AD_TYPE) {
        $conf = \%LJ::T_AD_TYPE;
    }

    # allow a hook to override config (of same format) per-user
    my $for_u = $self->for_u;
    my $hook_conf = LJ::run_hook("ad_type_config", $for_u);
    if ($hook_conf) {
        $conf = $hook_conf;
    }

    return $conf->{$self->ident}->{$key} if $key;
    return $conf->{$self->ident};
}

1;
