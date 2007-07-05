package LJ::Widget::CurrentTheme;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Customize );

sub ajax { 1 }
sub need_res { qw( stc/widgets/currenttheme.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} || LJ::get_remote();
    $u = LJ::load_userid($u) unless LJ::isu($u);
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

    my $layout_link = "<a href='$LJ::SITEROOT/customize2/?layoutid=" . $theme->layoutid . "' class='theme-current-layout'><em>$layout_name</em></a>";
    my $special_link_opts = "href='$LJ::SITEROOT/customize2/?cat=special' class='theme-current-cat'";
    $ret .= "<p class='theme-current-desc'>";
    if ($designer) {
        my $designer_link = "<a href='$LJ::SITEROOT/customize2/?designer=" . LJ::eurl($designer) . "' class='theme-current-designer'>$designer</a>";
        if (LJ::run_hook("layer_is_special", $theme->uniq)) {
            $ret .= $class->ml('widget.currenttheme.specialdesc', {'aopts' => $special_link_opts, 'designer' => $designer_link});
        } else {
            $ret .= $class->ml('widget.currenttheme.desc', {'layout' => $layout_link, 'designer' => $designer_link});
        }
    } elsif ($layout_name) {
        $ret .= $layout_link;
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

sub js {
    q [
        initWidget: function () {
            var self = this;

            var filter_links = DOM.getElementsByClassName(document, "theme-current-cat");
            filter_links = filter_links.concat(DOM.getElementsByClassName(document, "theme-current-layout"));
            filter_links = filter_links.concat(DOM.getElementsByClassName(document, "theme-current-designer"));

            // add event listeners to all of the category, layout, and designer links
            filter_links.forEach(function (filter_link) {
                var href = filter_link.href;
                var urlParts = href.split("?");
                getArgs = urlParts[1].split("&");
                for (var arg in getArgs) {
                    var pair = getArgs[arg].split("=");
                    if (pair[0] == "cat" || pair[0] == "layoutid" || pair[0] == "designer") {
                        DOM.addEventListener(filter_link, "click", function (evt) { Customize.updateThemeChooser(evt, pair[0], pair[1]) });
                        break;
                    }
                }
            });
        },
        onRefresh: function (data) {
            this.initWidget();
        },
    ];
}

1;
