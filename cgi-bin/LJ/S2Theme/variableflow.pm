package LJ::S2Theme::variableflow;
use strict;

use base qw(LJ::S2Theme);

sub cats { qw( clean cool ) }
sub designer { "Martin Atkins" }

sub display_option_props {
    my $self = shift;
    my @props = qw( page_year_sortorder );
    return $self->_append_props("display_option_props", @props);
}

sub text_props {
    my $self = shift;
    my @props = qw( clr_text clr_link clr_vlink clr_alink );
    return $self->_append_props("text_props", @props);
}

sub entry_props {
    my $self = shift;
    my @props = qw( url_background_img_box background_properties_box background_position_box );
    return $self->_append_props("entry_props", @props);
}

sub comment_props {
    my $self = shift;
    my @props = qw( text_post_comment text_read_comments text_post_comment_friends text_read_comments_friends );
    return $self->_append_props("comment_props", @props);
}


### Themes ###
1;
