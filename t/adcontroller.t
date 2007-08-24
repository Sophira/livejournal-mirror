# -*-perl-*-

use strict;
use Test::More 'no_plan';
use lib "$ENV{LJHOME}/cgi-bin";

require 'ljlib.pl';

use Class::Autouse qw
    (
     LJ::AdController
     LJ::Test
     );

#
# Set up config for testing
#

# map valid ad unit types
%LJ::T_AD_TYPE = 
    ( skyscraper  => { width => 160, height => 600, },
      leaderboard => { width => 728, height => 90,  },
      smrect      => { width => 185, height => 150, },
      medrect     => { width => 300, height => 250, },
      badge       => { width => 160, height => 90,  },
      );

# information per-page
%LJ::T_AD_PAGE = 
    ( TestPage => 
      { 
          # which units do we want to display on the page?
          units  => { skyscraper => 1, badge => 1 },

          # how should targeting be done?
          target => 'user',

          # what units are accepted by each ad location?
          accept => {
              top    => [ 'leaderboard' ],
              bottom => [ 'leaderboard' ],
              right  => [
                         [ 'skyscraper', 'badge' ], 
                         [ 'medrect' ], 
                         ],
          },
      },
      );

#
# Real tests start here
#

my $test_u = LJ::Test->temp_user;

my $adc = LJ::AdController->new
    ( page  => "TestPage",
      for_u => $test_u, );
isa_ok($adc, "LJ::AdController");

{ # AdPage

    my $adpage = $adc->page;
    isa_ok($adpage, "LJ::AdPage");

    my $ident = $adpage->ident;
    is($ident, "TestPage", "ident is 'TestPage'");

    my @supported_locations = $adpage->supported_locations;
    
    # all locations should be supported in our case
    ok( scalar(grep { $_->isa('LJ::AdLocation') } @supported_locations) == @supported_locations,
        "Supported Locations: " . join(", ", map { $_->ident } @supported_locations) );

    # was the location map properly allocated?

    # 1) simple case, all satisfied by 'right'
    is_deeply($adpage->adunit_map, { right => [ 'skyscraper', 'badge' ] },
              "adunit_map decision satisfied by 'right' location");

    # 2) needs to be satisfied by multiple locations
    {
        local $LJ::T_AD_PAGE{TestPage}->{units} = { leaderboard => 1, medrect => 1 };

        $adpage->build_adunit_map;

        is_deeply($adpage->adunit_map, 
                  { top    => [ 'leaderboard' ],
                    right  => [ 'medrect' ], },
                  "adunit_map decision satisfied by 2 locations");
    }

    # 3) another test case
    {
        local $LJ::T_AD_PAGE{TestPage}->{units} = { leaderboard => 2, badge => 1, skyscraper => 1, };

        $adpage->build_adunit_map;

        is_deeply($adpage->adunit_map, 
                  { top    => [ 'leaderboard' ],
                    right  => [ 'skyscraper', 'badge' ],
                    bottom => [ 'leaderboard' ], },
                  "adunit_map decision satisfied by 3 locations");
    }

    # Now, can we find all adunits for a location?
    {
        my @adunits = $adpage->adunits_for_location('right');
        
        my %want = ( skyscraper => 1, badge => 1 );
        ok((grep { $want{$_->ident} } @adunits) == @adunits, "Found correct units for 'right' location");
    }

    # Can we construct adcalls?
    {



    }

}



my $for_u = $adc->for_u;
isa_ok($for_u, "LJ::User");

