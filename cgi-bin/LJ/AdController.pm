package LJ::AdController;

# This is the controller that wrangles many adcalls
# depending on per-page policy decisions.  It is
# expected to evolve over time to suit our needs,
# which are difficult to outline monolithically.
#
# my $adc = LJ::AdController->new
#    ( page   => $adpage_obj,
#      for_u  => $u, # opt, default remote
#      search_terms => "optional term",
#      );
#
# FIXME: more descriptive accept_spec format
# $adc->render_adcalls( location => $adlocation_obj );
#
# my $adlocation = LJ::AdLocation->new( ident => 'top' );
#
# my $adunit = LJ::AdUnit->new( ident  => 'leaderboard',
#                               width  => 768,
#                               height =>  90, );
#
# my $adpage = LJ::AdPage->new( ident  => 'UpdatePage' );
#
# my $adcall = LJ::AdCall->new($u, $adunit);
#
# my $adconfig = LJ::AdConfig->new($u);
# $adconfig->want_for_page;

use strict;
use Class::Autouse qw(
                      LJ::AdPage
                      LJ::AdLocation
                      LJ::AdUnit
                      LJ::AdCall
                      );

sub new {
    my $class = shift;
    my %opts = @_;

    # safe to delete because we're passing a copy
    my $page         = delete $opts{page};
    my $for_u        = delete $opts{for_u};
    my $search_terms = delete $opts{search_terms};

    # page can be an ident string for a page object, or an instantiated AdPage
    $for_u ||= LJ::get_remote();
    $page = ref $page ? $page : LJ::AdPage->new( for_u => $for_u, ident => $page );


    # FIXME: validate

    my $self = {
        page         => $page,
        for_u        => $for_u,
        search_terms => $search_terms,
    };

    return bless $self, $class;
}

sub for_u {
    my $self = shift;
    return $self->{for_u};
}

sub page {
    my $self = shift;
    return $self->{page};
}

sub render_adcalls {
    my $self = shift;
    my %opts = @_;

    my $adlocation = $opts{location};
    
    my $adpage = $self->page;
    my @adunits = $adpage->adunits_for_location($adlocation);

    # build adcalls
    my @adcalls = LJ::AdCall->new_for_adunits($self->for_u, adunits => \@adunits);

    my $ret = "";
    foreach my $adcall (@adcalls) {
        $ret .= $adcall->render;
    }

    return $ret;
}

# locations:  [ $adlocation1, $adlocation2 ]
# want_units: { $adlocation => $want_ct }
sub allocate_adunits {
    my $class = shift;
    my %opts = @_;

    my $locations  = delete $opts{locations}  || [];
    my $want_units = delete $opts{want_units} || {};

    my %alloc_map = (); # location > [ unit1, unit2 ]

}

1;
