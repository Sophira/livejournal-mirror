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
    my %opts  = shift;

    my $self = {
        
    };

    return bless $self, $class;
}

sub render {
    my $self = shift;

    return "";
}

sub should_render {
    my $self = shift;

    return 1;
}

sub need_res {
    my $class = shift;

    return qw();
}
