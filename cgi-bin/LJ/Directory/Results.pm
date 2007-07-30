package LJ::Directory::Results;
use strict;
use warnings;
use Carp qw(croak);

sub new {
    my ($pkg, %args) = @_;
    my $self = bless {}, $pkg;
    $self->{page_size} = int(delete $args{page_size} || 100);
    $self->{pages} = int(delete $args{pages} || 0);
    $self->{page} = int(delete $args{page} || 1);
    $self->{userids} = delete $args{userids} || [];

    $self->{format} = delete $args{format};
    $self->{format} = "pics" unless
        $self->{format} && $self->{format} =~ /^(pics|simple)$/;

    return $self;
}

sub empty_set {
    my ($pkg) = @_;
    return $pkg->new;
}

sub pages {
    my $self = shift;
    $self->{pages};
}

sub userids {
    my $self = shift;
    return @{$self->{userids}};
}

sub format {
    my $self = shift;
    return $self->{format};
}

sub users {
    my $self = shift;
    my $us = LJ::load_userids($self->userids);
    return grep { $_
                      && $_->is_visible
                      && (!$_->is_person || !$_->age || $_->age > 13)
                  } values %$us;
}

sub as_string {
    my $self = shift;
    my @uids = $self->userids;
    return join(',', @uids);
}

sub render {
    my $self = shift;

    return $self->render_simple if $self->format eq "simple";
    return $self->render_pics if $self->format eq "pics";
}

sub render_simple {
    my $self = shift;
    my @users = $self->users;

    my $updated = LJ::get_timeupdate_multi($self->userids);

    my $ret = "<table id='SearchResults' cellspacing='1'>";
    foreach my $u (@users) {
        $ret .= "<tr><td class='SearchResult'>";
        $ret .= $u->ljuser_display . " - " . $u->name_html;
        $ret .= " <small>(Last updated: ". LJ::ago_text($updated->{$u->id}) . ")</small>";
        $ret .= "</td></tr>";
    }
    $ret .= "</table>";
    return $ret;
}

sub render_pics {
    my $self = shift;
    my @users = $self->users;

    my $tablecols = 5;
    my $col = 0;

    my $updated = LJ::get_timeupdate_multi($self->userids);

    my $ret = "<table id='SearchResults' cellspacing='1'>";
    foreach my $u (@users) {
        $ret .= "</tr>\n<tr>\n" if ($col++ % $tablecols == 0);

        my $userpic = $u->userpic ? $u->userpic->imgtag : '';

        $ret .= qq {
            <td class="SearchResult" width="20%" align="middle">
                <div class="ResultUserpic">$userpic</div>
            };
        $ret .= '<div class="Username">' . $u->ljuser_display . '</div>';

        if ($updated->{$u->id}) {
            $ret .= "<small>Updated ". LJ::ago_text($updated->{$u->id}) . "</small>";
        } else {
            $ret .= "<small>Never updated</small>";
        }

        $ret .= "</td>";
    }
    $ret .= "</tr></table>";

    return $ret;
}

1;
