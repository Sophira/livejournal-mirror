# -*-perl-*-

use strict;
use Test::More 'no_plan';
use lib "$ENV{LJHOME}/cgi-bin";
require 'ljlib.pl';
require 'ljprotocol.pl';
require 'talklib.pl';

use LJ::Event;
use LJ::Test qw(memcache_stress temp_user);
use FindBin qw($Bin);

# we want to test eight major cases here, matching and not matching for
# four types of subscriptions, all of subscr etypeid = JournalNewComment
#
#          jid   sarg1   sarg2   meaning
#    S1:     n       0       0   all new comments in journal 'n' (subject to security)
#    S2:     n ditemid       0   all new comments on post (n,ditemid)
#    S3:     n ditemid jtalkid   all new comments UNDER comment n/jtalkid (in ditemid)
#    S4:     0       0       0   all new comments from any journal you watch
#

my %got_sms = ();   # userid -> received sms
local $LJ::_T_SMS_SEND = sub {
    my $sms = shift;
    my $rcpt = $sms->to_u or die "No destination user";
    $got_sms{$rcpt->{userid}} = $sms;
};

my $proc_events = sub {
    %got_sms = ();
    LJ::Event->process_fired_events;
};

my $got_notified = sub {
    my $u = shift;
    $proc_events->();
    return $got_sms{$u->{userid}};
};


# testing case S1 above:
test_esn_flow(sub {
    my ($u1, $u2) = @_;
    my $sms;

    # subscribe $u1 to all posts on $u2
    my $subsc = $u1->subscribe(
                               event   => "JournalNewComment",
                               method  => "SMS",
                               journal => $u2,
                               );
    ok($subsc, "made S1 subscription");

    # post an entry in $u2
    my $u2e1 = eval { $u2->t_post_fake_entry };
    ok($u2e1, "made a post");
    is($@, "", "no errors");

    # $u1 leave a comment on $u2
    my %err = ();
    my $jtalkid = LJ::Talk::Post::enter_comment($u2, {talkid => 0}, {itemid => $u2e1->jitemid},
                                                   {u => $u1, state => 'A', subject => 'comment subject',
                                                    body => 'comment body',}, \%err);

    ok(!%err, "no error posting comment");
    ok($jtalkid, "got jtalkid");

    # make sure we got notification
    $sms = $got_notified->($u1);
    ok($sms, "got the SMS");
    is(eval { $sms->to }, 12345, "to right place");

    # S1 failing case:
    # post an entry on $u1, where nobody's subscribed
    my $u1e1 = eval { $u1->t_post_fake_entry };
    ok($u1e1, "did a post");

    # post a comment on it
    $jtalkid = LJ::Talk::Post::enter_comment($u1, {talkid => 0}, {itemid => $u1e1->jitemid},
                                             {u => $u1, state => 'A', subject => 'comment subject',
                                              body => 'comment body',}, \%err);

    ok(!%err, "no error posting comment");
    ok($jtalkid, "got jtalkid");

    # make sure we got notification
    $sms = $got_notified->($u1);
    ok(! $sms, "got no SMS");

    # S1 failing case, posting to u2, due to security
    my $u2e2f = eval { $u2->t_post_fake_entry(security => "friends") };
    ok($u2e2f, "did a post");
    is($u2e2f->security, "usemask", "is actually friends only");

    # post a comment on it
    $jtalkid = LJ::Talk::Post::enter_comment($u2, {talkid => 0}, {itemid => $u2e2f->jitemid},
                                             {u => $u2, state => 'A', subject => 'comment subject',
                                              body => 'comment body private',}, \%err);

    ok(!%err, "no error posting comment");
    ok($jtalkid, "got jtalkid");

    # make sure we got notification
    $sms = $got_notified->($u1);
    ok(! $sms, "got no SMS, due to security (u2 doesn't trust u1)");

    ok($subsc->delete, "Deleted subscription");

    ###### S2:
    # subscribe $u1 to all comments on u2e1
    $subsc = $u1->subscribe(
                            event   => "JournalNewComment",
                            method  => "SMS",
                            journal => $u2,
                            arg1    => $u2e1->ditemid,
                            );
    ok($subsc, "made S2 subscription");

    # post a comment on u2e1
    $jtalkid = LJ::Talk::Post::enter_comment($u2, {talkid => 0}, {itemid => $u2e1->jitemid},
                                             {u => $u2, state => 'A', subject => 'comment subject',
                                              body => 'comment body',}, \%err);
    ok(!%err, "no error posting comment");
    ok($jtalkid, "got jtalkid");

    $sms = $got_notified->($u1);
    ok($sms, "Got comment notification");

    # post another entry on u2
    my $u2e3 = eval { $u2->t_post_fake_entry };
    ok($u2e3, "did a post");

    # post a comment that $subsc won't match
    my $jtalkid2 = LJ::Talk::Post::enter_comment($u2, {talkid => 0}, {itemid => $u2e3->jitemid},
                                             {u => $u2, state => 'A', subject => 'comment subject',
                                              body => 'comment body',}, \%err);

    $sms = $got_notified->($u1);
    ok(!$sms, "didn't get comment notification on unrelated post");

    $subsc->delete;

    ######## S3 (watching a thread)
    # post a comment under comment with jtalkid2


    ####### S4 (watching new comments on all friends' journals)

    $subsc = $u1->subscribe(
                            event   => "JournalNewComment",
                            method  => "SMS",
                            );
    ok($subsc, "made S4 wildcard subscription");

    my $u2e4 = eval { $u2->t_post_fake_entry };
    ok($u2e4, "Got entry");

    for my $pass (1..2) {
        my $u2c1 = eval { $u2e4->t_enter_comment };
        ok($u2c1, "Posted comment");

        $proc_events->();

        if ($pass == 1) {
            $sms = $got_sms{$u1->{userid}};
            ok($sms, "Got wildcard notification");

            $sms = $got_sms{$u2->{userid}};
            ok(! $sms, "Non-subscribed user did not get notification");

            # remove the friend
            LJ::remove_friend($u1, $u2);

        } elsif ($pass == 2) {
            $sms = $got_sms{$u1->{userid}};
            ok(! $sms, "didn't get wildcard notification");

            # add the friend back
            LJ::add_friend($u1, $u2); # make u1 friend u2
        }
    }

    # leave some comment on u1, make sure no notification received
    my $u1e2 = eval { $u1->t_post_fake_entry };
    ok($u1e2, "Posted entry");

    my $u1c1 = eval { $u1e2->t_enter_comment };
    ok($u1c1, "Got comment");

    $sms = $got_notified->($u1);
    ok(! $sms, "Did not receive notification");
});

sub test_esn_flow {
    my $cv = shift;
    my $u1 = temp_user();
    my $u2 = temp_user();
    my $u3 = temp_user();
    $u1->set_sms_number(12345);
    $u2->set_sms_number(67890);
    LJ::add_friend($u1, $u2); # make u1 friend u2
    $cv->($u1, $u2, $u3);
}

1;

