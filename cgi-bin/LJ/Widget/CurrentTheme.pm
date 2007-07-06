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
    $u = LJ::load_user($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my $getextra = $opts{getextra};
    my $getsep = $getextra ? "&" : "?";

    my $theme = LJ::Customize->get_current_theme($u);
    my $userlay = LJ::S2::get_layers_of_user($u);
    my $layout_name = $theme->layout_name;
    my $designer = $theme->designer;

    my $ret;
    $ret .= "<h2 class='widget-header'><span>" . $class->ml('widget.currenttheme.title', {'user' => $u->ljuser_display}) . "</span></h2>";
    $ret .= "<div class='theme-current-content pkg'>";
    $ret .= "<img src='" . $theme->preview_imgurl . "' class='theme-current-image' />";
    $ret .= "<h3>" . $theme->name . "</h3>";

    my $layout_link = "<a href='$LJ::SITEROOT/customize2/$getextra${getsep}layoutid=" . $theme->layoutid . "' class='theme-current-layout'><em>$layout_name</em></a>";
    my $special_link_opts = "href='$LJ::SITEROOT/customize2/$getextra${getsep}cat=special' class='theme-current-cat'";
    $ret .= "<p class='theme-current-desc'>";
    if ($designer) {
        my $designer_link = "<a href='$LJ::SITEROOT/customize2/$getextra${getsep}designer=" . LJ::eurl($designer) . "' class='theme-current-designer'>$designer</a>";
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
    $ret .= "<li><a href='$LJ::SITEROOT/customize2/options.bml$getextra'>" . $class->ml('widget.currenttheme.options.change') . "</a></li>";
    $ret .= "<li><a href='$LJ::SITEROOT/customize2/$getextra#layout'>" . $class->ml('widget.currenttheme.options.layout') . "</a></li>";
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
                var getArgs = LiveJournal.parseGetArgs(filter_link.href);
                for (var arg in getArgs) {
                    if (!getArgs.hasOwnProperty(arg)) continue;
                    if (arg == "cat" || arg == "layoutid" || arg == "designer") {
                        DOM.addEventListener(filter_link, "click", function (evt) { Customize.updateThemeChooser(evt, arg, getArgs[arg]) });
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
