package LJ::Event::CommunityJoinReject;
use strict;
use Carp qw(croak);
use base 'LJ::Event';

sub new {
    my ($class, $u, $cu) = @_;
    foreach ($u, $cu) {
        croak 'Not an LJ::User' unless LJ::isu($_);
    }
    return $class->SUPER::new($u, $cu->{userid});
}

sub is_common { 1 } # As seen in LJ/Event.pm, event fired without subscription

# Override this with a false value make subscriptions to this event not show up in normal UI
sub is_visible { 0 }

# Whether Inbox is always subscribed to
sub always_checked { 1 }

my @_ml_strings_en = (
    'esn.comm_join_reject.email_subject',  # 'Your Request to Join [[community]] community',
    'esn.comm_join_reject.alert',          # 'Your request to join [[community]] community has been declined.',
    'esn.comm_join_reject.email_text',      # 'Dear [[user]],
                                            #
                                            #Your request to join the "[[community]]" community has been declined.
                                            #
                                            #Replies to this email are not sent to the community's maintainer(s). If you would 
                                            #like to discuss the reasons for your request's rejection, you will need to contact 
                                            #a maintainer directly.
                                            #
                                            #Regards,
                                            #[[sitename]] Team
                                            #
                                            #',
);

sub as_email_subject {
    my ($self, $u) = @_;
    my $cu      = $self->community;
    my $lang    = $u->prop('browselang');
    return LJ::Lang::get_text($lang, 'esn.comm_join_reject.email_subject', undef, { 'community' => $cu->{user} });
}

sub _as_email {
    my ($self, $u, $cu, $is_html) = @_;

    # Precache text lines
    my $lang    = $u->prop('browselang');
    #LJ::Lang::get_text_multi($lang, undef, \@_ml_strings_en);

    my $vars = {
            'user'      => $u->{name},
            'username'  => $u->{name},
            'community' => $cu->{user},
            'sitename'  => $LJ::SITENAME,
            'siteroot'  => $LJ::SITEROOT,
    };

    return LJ::Lang::get_text($lang, 'esn.comm_join_reject.email_text', undef, $vars);
}

sub as_email_string {
    my ($self, $u) = @_;
    my $cu = $self->community;
    return '' unless $u && $cu;
    return _as_email($self, $u, $cu, 0);
}

sub as_email_html {
    my ($self, $u) = @_;
    my $cu = $self->community;
    return '' unless $u && $cu;
    return _as_email($self, $u, $cu, 1);
}

sub as_alert {
    my $self = shift;
    my $u = shift;
    my $cu = $self->community;
    return '' unless $u && $cu;
    return LJ::Lang::get_text($u->prop('browselang'),
        'esn.comm_join_reject.alert', undef, { 'community' => $cu->ljuser_display(), });
}

sub community {
    my $self = shift;
    return LJ::load_userid($self->arg1);
}

1;
