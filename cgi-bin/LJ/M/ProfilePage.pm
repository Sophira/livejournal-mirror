package LJ::M::ProfilePage;

use strict;
use warnings;

use Carp qw(croak);

sub new {
    my $class = shift;
    my $u = shift || die;
    my $self = bless {
        u => $u,
    }, (ref $class || $class);
    return $self;
}

sub friends {
    my $self = shift;
    return $self->_process_friendlist('frienduids', 'friendofuids', @_);
}

sub friendofs {
    my $self = shift;
    return $self->_process_friendlist('friendofuids', 'frienduids', @_);
}

sub _process_friendlist {
    my $self = shift;
    my $left_method = shift;
    my $right_method = shift;
    my %opts = @_;

    my $userpics = $opts{userpics};

    croak "Left method not defined"  unless $left_method;
    croak "Right method not defined" unless $right_method;

    my $u = $self->{u};

    my $left  = $u->$left_method;
    my $right = $u->$right_method;

    my $users;
    {
        my %alluserids = (%$left, %$right);
        $users = LJ::load_userids(keys %alluserids);
    }

    my @return;

    foreach my $leftid (map { $_->[1] }
                        sort { $a->[0] cmp $b->[0] }
                        map { [$users->{$_}->display_name, $_] } keys %$left) {
        my $mutual = exists $right->{$leftid};
        my $html = '';

        my $fu = $users->{$leftid};

        if ($userpics and my $userpic = $fu->userpic) {
            $html .= $userpic->imgtag . "<br />";
        }

        $html .= $fu->ljuser_display({ bold => $mutual });
        push @return, $html;
    }

    return @return;
}

sub friends_count {
    my $self = shift;
    return $self->_process_friendcount('frienduids', @_);
}

sub friendofs_count {
    my $self = shift;
    return $self->_process_friendcount('friendofuids', @_);
}

sub _process_friendcount {
    my $self = shift;
    my $method = shift;
    my %opts = @_;

    croak "Method not defined" unless $method;

    my $u = $self->{u};

    my @userids = $u->$method;

    return scalar @userids unless $opts{remove};

    my $users = LJ::load_userids($u->$method);

    my %statusvis_counter = (
        suspended => 0,
    );

    foreach my $u (values %$users) {
        if ($u->{statusvis} eq 'S') {
            $statusvis_counter{suspended}++;
        }
    }

    my $count = @userids;

    foreach my $remove (@{$opts{remove}}) {
        croak "Unknown removal type '$remove' requested" unless exists $statusvis_counter{$remove};
        $count -= $statusvis_counter{$remove};
    }

    return $count;
}

1;
