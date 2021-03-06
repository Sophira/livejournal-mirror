package LJ::CProd::FriendsFriends;
use strict;

use base 'LJ::CProd';

sub applicable {
    my ($class, $u) = @_;
    return 0 unless LJ::get_cap($u, "friendsfriendsview");
    return 1;
}

sub render {
    my ($class, $u, $version) = @_;
    my $user = LJ::ljuser($u);

    my $icon = "<img border=\"0\" src=\"$LJ::SITEROOT/img/friendgroup.gif?v=5744\" class='cprod-image'  />";
    my $link = $class->clickthru_link('cprod.friendsfriends.link2', $version);

    return "$icon ".BML::ml($class->get_ml($version), { "user" => $user, "link" => $link });

}

sub ml { 'cprod.friendsfriends.text2' }
sub link {
    my $remote = LJ::get_remote()
        or return "$LJ::SITEROOT/login.bml";
    return $remote->friendsfriends_url . "/";
}
sub button_text { "Friends of Friends" }

1;
