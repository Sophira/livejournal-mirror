package LJ::Event::CommunityJoinRequest;
use strict;
use Class::Autouse qw(LJ::Entry);
use Carp qw(croak);
use base 'LJ::Event';

sub new {
    my ($class, $u, $requestor, $comm) = @_;

    foreach ($u, $requestor, $comm) {
        LJ::errobj('Event::CommunityJoinRequest', u => $_)->throw unless LJ::isu($_);
    }

    # Shouldn't these be method calls? $requestor->id, etc.
    return $class->SUPER::new($u, $requestor->{userid}, $comm->{userid});
}

sub is_common { 0 }

sub comm {
    my $self = shift;
    return LJ::load_userid($self->arg2);
}

sub requestor {
    my $self = shift;
    return LJ::load_userid($self->arg1);
}

sub authurl {
    my $self = shift;
    my $auth = LJ::get_authaction($self->comm->id, "comm_join_request", "targetid=". $self->requestor->id)
        or die "Unable to fetch authcode";
    return "$LJ::SITEROOT/approve/" . $auth->{aaid} . "." . $auth->{authcode};
}

sub as_html {
    my $self = shift;
    return sprintf("The user %s has <a href=\"$LJ::SITEROOT/community/pending.bml?comm=%s\">requested to join</a> the community %s.",
                   $self->requestor->ljuser_display, $self->comm->user,
                   $self->comm->ljuser_display);
}

sub as_html_actions {
    my ($self) = @_;

    my $ret .= "<div class='actions'>";
    $ret .= " <a href='" . $self->requestor->profile_url . "'>View Profile</a>";
    $ret .= " <a href='$LJ::SITEROOT/community/pending.bml?comm=" . $self->comm->user . "'>Manage Members</a>";
    $ret .= "</div>";

    return $ret;
}

sub content {
    my ($self, $target) = @_;

    return $self->as_html_actions;
}

sub as_string {
    my $self = shift;
    return sprintf("The user %s has requested to join the community %s.",
                   $self->requestor->display_username,
                   $self->comm->display_username);
}

sub as_email_subject {
    my $self = shift;
    return sprintf "%s membership request by %s",
      $self->comm->display_username, $self->requestor->display_username;
}

sub as_email_string {
    my ($self, $u) = @_;

    my $maintainer = $u->user;
    my $username = $self->requestor->user;
    my $communityname = $self->comm->user;
    my $authurl = $self->authurl;
    my $email = "Hi $maintainer,

$username has requested to join your community, $communityname.

You can:
  - Approve $username\'s request to join
    $authurl
  - Manage $communityname\'s membership requests
    $LJ::SITEROOT/community/pending.bml?comm=$communityname
  - Manage your communities
    $LJ::SITEROOT/community/manage.bml";

    return $email;
}

sub as_email_html {
    my ($self, $u) = @_;

    my $maintainer = $u->ljuser_display;
    my $user = $self->comm->user;
    my $username = $self->requestor->ljuser_display;
    my $community = $self->comm->ljuser_display;
    my $communityname = $self->comm->user;
    my $authurl = $self->authurl;

    my $email = "Hi $maintainer,

$username has requested to join your community, $community.

You can:<ul>";

    $email .= "<li><a href=\"$authurl\">Approve $user\'s request to join</a></li>";
    $email .= "<li><a href=\"$LJ::SITEROOT/community/pending.bml?comm=$communityname\">Manage $communityname\'s membership requests</a></li>";
    $email .= "<li><a href=\"$LJ::SITEROOT/community/manage.bml\">Manage your communities</a></li>";
    $email .= "</ul>";

    return $email;

}

sub as_sms {
    my $self = shift;

    return sprintf("%s requests membership in %s. Visit community settings to approve.",
                   $self->requestor->display_username,
                   $self->comm->display_username);
}

sub subscription_as_html {
    my ($class, $subscr) = @_;
    return 'Someone requests membership in a community I maintain';
}

package LJ::Error::Event::CommunityJoinRequest;
sub fields { 'u' }
sub as_string {
    my $self = shift;
    return "LJ::Event::CommuinityJoinRequest passed bogus u object: $self->{u}";
}

1;
