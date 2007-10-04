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
# my $adconfig = LJ::AdConf->new($u);
# $adconfig->want_for_page;

use strict;
use Class::Autouse qw(
                      LJ::AdCall
                      LJ::AdLocation
                      LJ::AdPage
                      LJ::AdPolicy
                      LJ::AdUnit
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

    # build adcalls
    my @adcalls = $adpage->adcalls_for_location($adlocation);

    my $ret = "";
    foreach my $adcall (@adcalls) {
        $ret .= $adcall->render;
    }

    return $ret;
}

sub should_show_ads {
    my $self = shift;

    my $adpage = $self->page;
    my $adpolicy = LJ::AdPolicy->new;
    return $adpolicy->should_show_ads($adpage)? 1 : 0;
}

1;
