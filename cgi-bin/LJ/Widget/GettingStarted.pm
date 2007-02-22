package LJ::Widget::GettingStarted;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub render_body {
    my $class = shift;
    my %opts = @_;
    my $ret;

    my $remote = LJ::get_remote();
    return "" unless $remote;

    # epoch -> pretty
    my $date_format = sub {
        my $epoch = shift;
        my $exp = $epoch ? DateTime->from_epoch( epoch => $epoch ) : "";
        return $exp ? $exp->date() : "";
    };

    $ret .= "<h2>Getting Started</h2>";

    unless ($remote->postreg_completed) {
        $ret .= "<p>You haven't filled out your profile.<br />";
        $ret .= "&raquo; <a href='$LJ::SITEROOT/postreg/'>Edit Profile</a></p>";
    }

    unless ($remote->has_enough_friends) {
        $ret .= "<p>You've only made " . $remote->get_friends_count( include_initial_friends => 0 ) . " friends.<br />";
        $ret .= "&raquo; <a href='$LJ::SITEROOT/postreg/find.bml'>Find Friends and Communities</a></p>";
    }

    if ($remote->number_of_posts < 1) {
        $ret .= "<p>You haven't made an entry in your journal yet.<br />";
        $ret .= "&raquo; <a href='$LJ::SITEROOT/update.bml'>Post an Entry</a></p>";
    }

    if ($remote->get_userpic_count < 1) {
        $ret .= "<p>You have no userpics.<br />";
        $ret .= "&raquo; <a href='$LJ::SITEROOT/editpics.bml'>Upload a Userpic</a></p>";
    }

    $ret .= "<p>" . LJ::name_caps($remote->{caps});
    if ($remote->in_class('paid') && !$remote->in_class('perm')) {
        my $exp_epoch = LJ::Pay::get_account_exp($remote);
        my $exp = $date_format->($exp_epoch);
        $ret .= " (<a href='$LJ::SITEROOT/manage/payments/'>Expires $exp</a>)"
            if $exp;
    }
    $ret .= "</p>";
    $ret .= "<p><a href='$LJ::SITEROOT/manage/'>Manage Account</a></p>";

    return $ret;
}

1;
