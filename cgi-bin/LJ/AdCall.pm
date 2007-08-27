package LJ::AdCall;

# FIXME: 
# -- base implementation that works
# -- remove AdEngine.js from ljlib.pl, replace with need_res
# -- move existing lj hooks into AdCall methods
# -- make selection of adcall per page sane
# -- livejournal.js init should init AdEngine.js via page_load hook
#    in livejournal-local.js

use strict;

sub new {
    my $class = shift;
    my %opts  = @_;

    my $page = $opts{page};

    my $self = {
        page => $page,
        unit => $opts{unit},
    };

    die "no page for adcall" unless $self->{page};
    die "no unit for adcall" unless $self->{unit};

    # should we defer to a different class for this adcall?
    if (my $other_class = LJ::run_hook('alternate_adcall_class', $page->for_u)) {
        bless $self, $other_class;
        return $self;
    }

    bless $self, $class;
    return $self;
}

sub page {
    my $self = shift;
    return $self->{page};
}

sub unit {
    my $self = shift;
    return $self->{unit};
}

sub render {
    my $self = shift;

    my $adcall_url = $self->adcall_url;

    return $self->render_url($adcall_url);
}

sub construct_url {
    my $self = shift;

}

sub render_url {
    my $self = shift;

}

sub should_render {
    my $self = shift;

    return 1;
}

sub need_res {
    my $class = shift;

    return qw();
}
