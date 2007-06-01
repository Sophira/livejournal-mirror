package LJ::S2Theme::sturdygesture;
use base qw(LJ::S2Theme);

sub layouts { qw( 2lnh 2rnh ) }
sub layout_prop { "opt_navbar_pos" }
sub cats { qw( clean dark ) }
sub designer { "Martin Atkins" }

sub hidden_props {
    my $self = shift;
    my @props = qw( opt_navbar_pos );
    return $self->_append_props("hidden_props", @props);
}

sub display_option_props {
    my $self = shift;
    my @props = qw( opt_always_userpic );
    return $self->_append_props("display_option_props", @props);
}

sub text_props {
    my $self = shift;
    my @props = qw( clr_page_link clr_page_vlink );
    return $self->_append_props("text_props", @props);
}


### Themes ###

package LJ::S2Theme::sturdygesture::boxless;
use base qw(LJ::S2Theme::sturdygesture);
sub cats { qw( clean ) }

package LJ::S2Theme::sturdygesture::martialblue;
use base qw(LJ::S2Theme::sturdygesture);
sub cats { qw( clean cool ) }

package LJ::S2Theme::sturdygesture::redmond;
use base qw(LJ::S2Theme::sturdygesture);
sub cats { qw( clean cool ) }

1;
