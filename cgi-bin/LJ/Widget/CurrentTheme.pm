package LJ::Widget::CurrentTheme;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Customize );

sub need_res { qw( stc/widgets/currenttheme.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user};
    die "Invalid user." unless LJ::isu($u);

    my $theme = LJ::Customize->get_current_theme($u);
    my $userlay = LJ::S2::get_layers_of_user($u);
    my $layout_name = $theme->layout_name;
    my $designer = $theme->designer;

    my $ret;
    $ret .= "<h2 class='widget-header'><span>" . $class->ml('widget.currenttheme.title', {'user' => $u->ljuser_display}) . "</span></h2>";
    $ret .= "<div class='theme-current-content pkg'>";
    $ret .= "<img src='" . $theme->preview_imgurl . "' class='theme-current-image' />";
    $ret .= "<h3>" . $theme->name . "</h3>";
    $ret .= "<p class='theme-current-desc'>";
    if ($designer) {
        $ret .= $class->ml('widget.currenttheme.desc', {'layout' => "<a href='#'><em>" . $theme->layout_name . "</em></a>", 'designer' => "<a href='#'>" . $theme->designer . "</a>"});
    } elsif ($layout_name) {
        if ($userlay->{$theme->layoutid}) {
            $ret .= "<em>" . $theme->layout_name . "</em>";
        } else {
            $ret .= "<a href='#'><em>" . $theme->layout_name . "</em></a>";
        }
    }
    $ret .= "</p>";
    $ret .= "<div class='theme-current-links'>";
    $ret .= $class->ml('widget.currenttheme.options');
    $ret .= "<ul class='nostyle'>";
    $ret .= "<li><a href='$LJ::SITEROOT/customize2/options.bml'>" . $class->ml('widget.currenttheme.options.change') . "</a></li>";
    $ret .= "<li><a href='$LJ::SITEROOT/customize2/#layout'>" . $class->ml('widget.currenttheme.options.layout') . "</a></li>";
    $ret .= "</ul>";
    $ret .= "</div><!-- end .theme-current-links -->";
    $ret .= "</div><!-- end .theme-current-content -->";

    return $ret;
}

1;
