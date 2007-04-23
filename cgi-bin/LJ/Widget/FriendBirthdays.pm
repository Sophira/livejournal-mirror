package LJ::Widget::FriendBirthdays;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub need_res { }

# args
#   user: optional $u whose friend birthdays we should get (remote is default)
#   limit: optional max number of birthdays to show; default is 5
sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} && LJ::isu($opts{user}) ? $opts{user} : LJ::get_remote();
    return "" unless $u;

    my $limit = defined $opts{limit} ? $opts{limit} : 5;

    my @bdays = $u->get_friends_birthdays( months_ahead => 1 );
    @bdays = @bdays[0..$limit-1]
        if @bdays > $limit;

    return "" unless @bdays;

    my $ret;
    $ret .= "<h2>" . $class->ml('widget.friendbirthdays.title') . "</h2>";
    $ret .= "<p>&raquo; <a href='$LJ::SITEROOT/birthdays.bml'>" . $class->ml('widget.friendbirthdays.viewall') . "</a></p>";

    foreach my $bday (@bdays) {
        my $u = LJ::load_user($bday->[2]);
        my $month = $bday->[0];
        my $day = $bday->[1];
        next unless $u && $month && $day;

        $ret .= "<p>";
        $ret .= $class->ml('widget.friendbirthdays.userbirthday', {user => $u->ljuser_display, month => LJ::Lang::month_short($month) . ".", day => $day});
        $ret .= " <a href='$LJ::SITEROOT/shop/view.bml?item=paidaccount&gift=1&for=" . $u->user . "'><img src='$LJ::IMGPREFIX/btn_gift.gif' alt='' /> ";
        $ret .= $class->ml('widget.friendbirthdays.gift') . "</a>";
        $ret .= "</p>";
    }

    return $ret;
}

1;
