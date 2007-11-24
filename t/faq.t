# -*-perl-*-

use strict;
use Test::More qw(no_plan);
use lib "$ENV{LJHOME}/cgi-bin";

require 'ljlib.pl';
require 'ljlang.pl';

use LJ::Faq;
use LJ::Test qw(memcache_stress);

sub run_tests {
    # constructor tests
    {   
        my %skel = 
            ( faqid         => 123,
              question      => 'some question',
              summary       => 'summary info',
              answer        => 'this is the answer',
              faqcat        => 'category',
              lastmoduserid => 456,
              sortorder     => 789,
              lastmodtime   => scalar(gmtime(time)),
              unixmodtime   => time
              );

        {
            my $f = eval { LJ::Faq->new(%skel, lang => 'xx') };
            is($f->lang, $LJ::DEFAULT_LANG, "unknown language code falls back to default");
        }

        foreach my $lang (qw(en es)) {

            my $f;

            $f = eval { LJ::Faq->new(%skel, lang => $lang, foo => 'bar') };
            like($@, qr/unknown parameters/, "$lang: superfluous parameter");

            # FIXME: more failure cases
            $skel{lang} = $lang;
            $f = eval { LJ::Faq->new(%skel) };

            # check members
            is_deeply($f, \%skel, "$lang: members set correctly");

            # check accessors
            {
                my $r = {};
                foreach my $meth (keys %skel) {
                    my $el = $meth;
                    $meth =~ s/^(question|summary|answer)$/${1}_raw/;
                    $r->{$el} = $f->$meth;
                }
                is_deeply($r, $f, "$lang: accessors return correctly");

                # FIXME: test for _html accessors
            }

            # check loaders
            {
                my @faqs = LJ::Faq->load_all;
                is_deeply([ map { LJ::Faq->load($_->{faqid}) } @faqs ], \@faqs,
                          "single and multi loaders okay");
            }
        }

        # check multi-lang support
        SKIP: {
            $LJ::_T_FAQ_SUMMARY_OVERRIDE = "la cabra esta bailando en la biblioteca!!!";

            my @all = LJ::Faq->load_all;
            skip "No FAQs in the database", 1 unless @all;
            my $faqid = $all[0]->{faqid};
            
            my $default = LJ::Faq->load($faqid);
            my $es      = LJ::Faq->load($faqid, lang => 'es');
            ok($default && $es->summary_raw ne $default->summary_raw, 
               "multiple languages with different results")
        }
    }

    # FIXME: more robust tests

}

memcache_stress {
    run_tests();
};

1;
