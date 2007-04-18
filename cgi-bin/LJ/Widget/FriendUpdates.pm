package LJ::Widget::FriendUpdates;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub need_res { }

# args
#   user: optional $u whose friend updates we should get (remote is default)
#   limit: optional max number of updates to show (used for birthdays and inbox separately); default is 5
sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} && LJ::isu($opts{user}) ? $opts{user} : LJ::get_remote();
    return "" unless $u;

    my $limit = defined $opts{limit} ? $opts{limit} : 5;

    my @bdays = $u->get_friends_birthdays( months_ahead => 1 );
    @bdays = @bdays[0..$limit-1]
        if @bdays > $limit;

    my $inbox = $u->notification_inbox;
    my @notifications = ();
    if ($inbox) {
        @notifications = $inbox->friend_items;
        @notifications = sort { $b->when_unixtime <=> $a->when_unixtime } @notifications;
        @notifications = @notifications[0..$limit-1] if @notifications > $limit;
    }

    my $ret;
    $ret .= "<h2>" . $class->ml('widget.friendupdates.title') . "</h2>";
    $ret .= "<p>&raquo; <a href='$LJ::SITEROOT/inbox/'>" . $class->ml('widget.friendupdates.viewall') . "</a></p>";

    unless (@bdays || @notifications) {
        $ret .= $class->ml('widget.friendupdates.noupdates') . "<br />";
        $ret .= $class->ml('widget.friendupdates.noupdates.setup', {'aopts' => "href='$LJ::SITEROOT/manage/subscriptions/'"});
        return $ret;
    }

    $ret .= "<img src='$LJ::IMGPREFIX/vgift/bdayballoons-small.gif' alt='' />";
    foreach my $bday (@bdays) {
        my $u = LJ::load_user($bday->[2]);
        my $month = $bday->[0];
        my $day = $bday->[1];
        next unless $u && $month && $day;

        $ret .= "<p>";
        $ret .= $class->ml('widget.friendupdates.userbirthday', {user => $u->ljuser_display, month => LJ::Lang::month_short($month) . ".", day => $day});
        $ret .= " <a href='$LJ::SITEROOT/shop/view.bml?item=paidaccount&gift=1&for=" . $u->user . "'><img src='$LJ::IMGPREFIX/btn_gift.gif' alt='' /></a>";
        $ret .= "</p>";
    }
    $ret .= "<p>&raquo; <a href='$LJ::SITEROOT/birthdays.bml'>" . $class->ml('widget.friendupdates.morebirthdays') . "</a></p>";

    foreach my $item (@notifications) {
        $ret .= "<p>" . $item->title . "</p>";
    }

    return $ret;
}

1;
