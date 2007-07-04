package LJ::Widget::ThemeChooser;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::S2Theme LJ::Customize );

sub ajax { 1 }
sub need_res { qw( stc/widgets/themechooser.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} || LJ::get_remote();
    $u = LJ::load_userid($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    # filter criteria
    my $cat = defined $opts{cat} ? $opts{cat} : "";
    my $layoutid = defined $opts{layoutid} ? $opts{layoutid} : 0;
    my $designer = defined $opts{designer} ? $opts{designer} : "";
    my $custom = defined $opts{custom} ? $opts{custom} : 0;
    my $filter_available = defined $opts{filter_available} ? $opts{filter_available} : 0;
    my $page = defined $opts{page} ? $opts{page} : 1;
    my $num_per_page = defined $opts{num_per_page} ? $opts{num_per_page} : 12;

    my %cats = LJ::Customize->get_cats;
    my $ret;

    my @themes;
    if ($cat) {
        $ret .= "<h3>$cats{$cat}</h3>";
        @themes = LJ::S2Theme->load_by_cat($cat);
    } elsif ($layoutid) {
        my $layout_name = LJ::Customize->get_layout_name($layoutid, user => $u);
        $ret .= "<h3>$layout_name</h3>";
        @themes = LJ::S2Theme->load_by_layoutid($layoutid, $u);
    } elsif ($designer) {
        $designer = LJ::durl($designer);
        $ret .= "<h3>$designer</h3>";
        @themes = LJ::S2Theme->load_by_designer($designer);
    } elsif ($custom) {
        $ret .= "<h3>" . $class->ml('widget.themechooser.header.custom') . "</h3>";
        @themes = LJ::S2Theme->load_by_user($u);
    } else {
        $ret .= "<h3>" . $class->ml('widget.themechooser.header.all') . "</h3>";
        @themes = LJ::S2Theme->load_all($u);
    }

    if ($filter_available) {
        @themes = LJ::S2Theme->filter_available($u, @themes);
    }

    # sort themes with custom at the end, then alphabetically
    @themes =
        sort { $a->is_custom <=> $b->is_custom }
        sort { lc $a->name cmp lc $b->name } @themes;

    LJ::run_hook("modify_theme_list", \@themes, user => $u, cat => $cat);

    my $current_theme = LJ::Customize->get_current_theme($u);
    my $index_of_first_theme = $num_per_page * ($page - 1);
    my $index_of_last_theme = ($num_per_page * $page) - 1;
    my @themes_this_page = @themes[$index_of_first_theme..$index_of_last_theme];

    $ret .= "<p class='detail'>" . $class->ml('widget.themechooser.desc') . "</p>";
    foreach my $theme (@themes_this_page) {
        next unless defined $theme;

        # figure out the type(s) of theme this is so we can modify the output accordingly
        my %theme_types;
        $theme_types{current} = 1 if
            ($theme->themeid && ($theme->themeid == $current_theme->themeid)) ||
            (!$theme->themeid && ($theme->layoutid == $current_theme->layoutid));
        $theme_types{upgrade} = 1 if !$filter_available && !$theme->available_to($u);
        $theme_types{special} = 1 if LJ::run_hook("layer_is_special", $theme->uniq);

        my ($theme_class, $theme_options, $theme_icons) = ("", "", "");

        $theme_icons .= "<div class='theme-icons'>" if $theme_types{upgrade} || $theme_types{special};
        if ($theme_types{current}) {
            $theme_class .= " current";
            $theme_options .= "<strong><a href='$LJ::SITEROOT/customize2/options.bml'>" . $class->ml('widget.themechooser.theme.customize') . "</a></strong>";
        }
        if ($theme_types{upgrade}) {
            $theme_class .= " upgrade";
            $theme_options .= "<br />" if $theme_options;
            $theme_options .= LJ::run_hook("customize_special_options");
            $theme_icons .= LJ::run_hook("customize_special_icons", $u, $theme);
        }
        if ($theme_types{special}) {
            $theme_class .= " special" if $cat eq "featured" && LJ::run_hook("should_see_special_content", $u);
            $theme_icons .= LJ::run_hook("customize_available_until", $theme);
        }
        $theme_icons .= "</div><!-- end .theme-icons -->" if $theme_icons;

        my $theme_layout_name = $theme->layout_name;
        my $theme_designer = $theme->designer;

        $ret .= "<div class='theme-item$theme_class'>";
        $ret .= "<img src='" . $theme->preview_imgurl . "' class='theme-preview' />";
        $ret .= "<h4>" . $theme->name . "</h4>";

        my $preview_redirect_url;
        if ($theme->themeid) {
            $preview_redirect_url = "$LJ::SITEROOT/customize2/preview_redirect.bml?user=" . $u->id . "&themeid=" . $theme->themeid;
        } else {
            $preview_redirect_url = "$LJ::SITEROOT/customize2/preview_redirect.bml?user=" . $u->id . "&layoutid=" . $theme->layoutid;
        }
        $ret .= "<a href='$preview_redirect_url' class='theme-preview-link' title='" . $class->ml('widget.themechooser.theme.preview') . "'>";

        $ret .= "<img src='$LJ::IMGPREFIX/customize/preview-theme.gif' class='theme-preview-image' /></a>";
        $ret .= $theme_icons;

        my $layout_link = "<a href='$LJ::SITEROOT/customize2/?layoutid=" . $theme->layoutid . "' class='theme-layout'><em>$theme_layout_name</em></a>";
        my $special_link_opts = "href='$LJ::SITEROOT/customize2/?cat=special' class='theme-cat'";
        $ret .= "<p class='theme-desc'>";
        if ($theme_designer) {
            my $designer_link = "<a href='$LJ::SITEROOT/customize2/?designer=" . LJ::eurl($theme_designer) . "' class='theme-designer'>$theme_designer</a>";
            if ($theme_types{special}) {
                $ret .= $class->ml('widget.themechooser.theme.specialdesc', {'aopts' => $special_link_opts, 'designer' => $designer_link});
            } else {
                $ret .= $class->ml('widget.themechooser.theme.desc', {'layout' => $layout_link, 'designer' => $designer_link});
            }
        } elsif ($theme_layout_name) {
            $ret .= $layout_link;
        }
        $ret .= "</p>";

        if ($theme_options) {
            $ret .= $theme_options;
        } else { # apply theme form
            $ret .= $class->start_form( class => "theme-form" );
            $ret .= $class->html_hidden(
                apply_uid => $u->id,
                apply_themeid => $theme->themeid,
                apply_layoutid => $theme->layoutid,
                view_cat => $cat,
                view_layoutid => $layoutid,
                view_designer => $designer,
                view_custom => $custom,
                view_filter_available => $filter_available,
                view_page => $page,
                view_num_per_page => $num_per_page,
            );
            $ret .= $class->html_submit( "apply" => $class->ml('widget.themechooser.theme.apply'), { raw => "class='theme-button'" });
            $ret .= $class->end_form;
        }
        $ret .= "</div><!-- end .theme-item -->";
    }

    return $ret;
}

sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    my $u = $post->{apply_uid} || LJ::get_remote();
    $u = LJ::load_userid($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my $themeid = $post->{apply_themeid}+0;
    my $layoutid = $post->{apply_layoutid}+0;

    my $theme;
    if ($themeid) {
        $theme = LJ::S2Theme->load_by_themeid($themeid, $u);
    } elsif ($layoutid) {
        $theme = LJ::S2Theme->load_custom_layoutid($layoutid, $u);
    } else {
        die "No theme id or layout id specified.";
    }

    LJ::Customize->apply_theme($u, $theme);

    return;
}

sub js {
    q [
        initWidget: function () {
            var self = this;

            var filter_links = DOM.getElementsByClassName(document, "theme-cat");
            filter_links = filter_links.concat(DOM.getElementsByClassName(document, "theme-layout"));
            filter_links = filter_links.concat(DOM.getElementsByClassName(document, "theme-designer"));

            // add event listeners to all of the category, layout, and designer links
            filter_links.forEach(function (filter_link) {
                var href = filter_link.href;
                var urlParts = href.split("?");
                getArgs = urlParts[1].split("&");
                for (var arg in getArgs) {
                    var pair = getArgs[arg].split("=");
                    if (pair[0] == "cat" || pair[0] == "layoutid" || pair[0] == "designer") {
                        DOM.addEventListener(filter_link, "click", function (evt) { self.reloadWidget(evt, pair[0], pair[1]) });
                        break;
                    }
                }
            });

            var apply_forms = DOM.getElementsByClassName(document, "theme-form");

            // add event listeners to all of the apply theme forms
            apply_forms.forEach(function (form) {
                DOM.addEventListener(form, "submit", function (evt) { self.applyTheme(evt, form) });
            });
        },
        reloadWidget: function (evt, key, value) {
            if (key == "cat") {
                this.updateContent({ cat: value, page: 1 });
            } else if (key == "layoutid") {
                this.updateContent({ layoutid: value, page: 1 });
            } else if (key == "designer") {
                this.updateContent({ designer: value, page: 1 });
            }
            Event.stop(evt);
        },
        applyTheme: function (evt, form) {
            this.doPostAndUpdateContent({
                apply_uid: form.Widget_ThemeChooser_apply_uid.value,
                apply_themeid: form.Widget_ThemeChooser_apply_themeid.value,
                apply_layoutid: form.Widget_ThemeChooser_apply_layoutid.value,
                cat: form.Widget_ThemeChooser_view_cat.value,
                layoutid: form.Widget_ThemeChooser_view_layoutid.value,
                designer: form.Widget_ThemeChooser_view_designer.value,
                custom: form.Widget_ThemeChooser_view_custom.value,
                filter_available: form.Widget_ThemeChooser_view_filter_available.value,
                page: form.Widget_ThemeChooser_view_page.value,
                num_per_page: form.Widget_ThemeChooser_view_num_per_page.value,
            });
            Event.stop(evt);
        },
        onRefresh: function (data) {
            this.initWidget();
        },
    ];
}

1;
