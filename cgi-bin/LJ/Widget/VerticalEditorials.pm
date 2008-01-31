package LJ::Widget::VerticalEditorials;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Vertical LJ::VerticalEditorials LJ::Image );

sub need_res { qw( stc/widgets/verticaleditorials.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $vertical = $opts{vertical};
    die "Invalid vertical object passed to widget." unless $vertical;

    my $preview_params = $opts{preview_params};
    my $editorial = keys %$preview_params ? $preview_params : LJ::VerticalEditorials->get_editorial_for_vertical( vertical => $vertical );
    return "" unless $editorial;

    foreach my $item ($editorial->{title}, $editorial->{editor}, $editorial->{submitter}, $editorial->{block_1_title},
                      $editorial->{block_2_title}, $editorial->{block_3_title}, $editorial->{block_4_title}) {
        LJ::CleanHTML::clean_subject(\$item);
    }
    foreach my $item ($editorial->{block_1_text}, $editorial->{block_2_text}, $editorial->{block_3_text}, $editorial->{block_4_text}) {
        LJ::CleanHTML::clean_event(\$item);
    }

    my $ret;
    $ret .= "<h2>$editorial->{title}</h2>";
    if ($editorial->{editor}) {
        $ret .= "<span class='editorials-header-right'>" . $class->ml('widget.verticaleditorials.byperson', { person => $editorial->{editor} }) . "</span>";
    }
    $ret .= "<div class='editorials-content'>";
    $ret .= "<table cellspacing='0' cellpadding='0'><tr valign='top'>";

    my $image_url = $editorial->{img_url};
    if ($image_url) {
        $ret .= "<td>";
        if ($image_url =~ /[<>]/) { # HTML
            LJ::CleanHTML::clean_event(\$image_url);
            $ret .= $image_url;
        } else {
            if ($editorial->{img_width} && $editorial->{img_height}) {
                my $img_link_url = $editorial->{img_link_url} || $image_url;
                $ret .= "<a href='$img_link_url'><img src='$image_url' width='$editorial->{img_width}' height='$editorial->{img_height}' border='0' alt='' /></a>";
            }
        }
        if ($editorial->{submitter}) {
            $ret .= "<p class='editorials-submitter'>" . $class->ml('widget.verticaleditorials.byperson', { person => $editorial->{submitter} }) . "</p>";
        }
        $ret .= "</td>";
    }

    $ret .= "<td class='editorials-blocks'>";
    foreach my $i (1..4) {
        my $title = $editorial->{"block_${i}_title"};
        my $text = $editorial->{"block_${i}_text"};

        if ($title) {
            $ret .= "<p class='editorials-block-title'>$title</p>";
        }
        if ($text) {
            $ret .= "<p class='editorials-block-text'>$text</p>";
        }
    }
    $ret .= "</td>";

    $ret .= "</tr></table>";
    $ret .= "</div>";

    return $ret;
}

1;
