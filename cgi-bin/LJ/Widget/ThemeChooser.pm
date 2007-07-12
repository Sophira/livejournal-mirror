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
    $u = LJ::load_user($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my $getextra = $opts{getextra};
    my $getsep = $getextra ? "&" : "?";

    # filter criteria
    my $cat = defined $opts{cat} ? $opts{cat} : "";
    my $layoutid = defined $opts{layoutid} ? $opts{layoutid} : 0;
    my $designer = defined $opts{designer} ? $opts{designer} : "";
    my $custom = defined $opts{custom} ? $opts{custom} : 0;
    my $filter_available = defined $opts{filter_available} ? $opts{filter_available} : 0;
    my $page = defined $opts{page} ? $opts{page} : 1;

    my $filterarg = $filter_available ? "&filter_available=1" : "";

    my %cats = LJ::Customize->get_cats;
    my $num_per_page = 12;
    my $ret .= "<div class='theme-selector-content pkg'>";

    my @getargs;
    my @themes;
    if ($cat) {
        $ret .= "<h3>$cats{$cat}->{text}</h3>";
        push @getargs, "cat=$cat";
        @themes = LJ::S2Theme->load_by_cat($cat);
    } elsif ($layoutid) {
        my $layout_name = LJ::Customize->get_layout_name($layoutid, user => $u);
        $ret .= "<h3>$layout_name</h3>";
        push @getargs, "layoutid=$layoutid";
        @themes = LJ::S2Theme->load_by_layoutid($layoutid, $u);
    } elsif ($designer) {
        $designer = LJ::durl($designer);
        $ret .= "<h3>$designer</h3>";
        push @getargs, "designer=$designer";
        @themes = LJ::S2Theme->load_by_designer($designer);
    } elsif ($custom) {
        $ret .= "<h3>" . $class->ml('widget.themechooser.header.custom') . "</h3>";
        push @getargs, "custom=$custom";
        @themes = LJ::S2Theme->load_by_user($u);
    } else {
        $ret .= "<h3>" . $class->ml('widget.themechooser.header.all') . "</h3>";
        @themes = LJ::S2Theme->load_all($u);
    }

    if ($filter_available) {
        push @getargs, "filter_available=$filter_available";
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

    $ret .= "<ul class='theme-paging theme-paging-top nostyle'>";
    $ret .= $class->print_paging(
        themes => \@themes,
        num_per_page => $num_per_page,
        page => $page,
        getargs => \@getargs,
        getextra => $getextra,
    );
    $ret .= "</ul>";

    foreach my $theme (@themes_this_page) {
        next unless defined $theme;

        # figure out the type(s) of theme this is so we can modify the output accordingly
        my %theme_types;
        $theme_types{current} = 1 if
            (defined $theme->themeid && ($theme->themeid == $current_theme->themeid)) ||
            (!defined $theme->themeid && ($theme->layoutid == $current_theme->layoutid));
        $theme_types{upgrade} = 1 if !$filter_available && !$theme->available_to($u);
        $theme_types{special} = 1 if LJ::run_hook("layer_is_special", $theme->uniq);

        my ($theme_class, $theme_options, $theme_icons) = ("", "", "");

        $theme_icons .= "<div class='theme-icons'>" if $theme_types{upgrade} || $theme_types{special};
        if ($theme_types{current}) {
            $theme_class .= " current";
            $theme_options .= "<strong><a href='$LJ::SITEROOT/customize2/options.bml$getextra'>" . $class->ml('widget.themechooser.theme.customize') . "</a></strong>";
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

        my $layout_link = "<a href='$LJ::SITEROOT/customize2/$getextra${getsep}layoutid=" . $theme->layoutid . "$filterarg' class='theme-layout'><em>$theme_layout_name</em></a>";
        my $special_link_opts = "href='$LJ::SITEROOT/customize2/$getextra${getsep}cat=special$filterarg' class='theme-cat'";
        $ret .= "<p class='theme-desc'>";
        if ($theme_designer) {
            my $designer_link = "<a href='$LJ::SITEROOT/customize2/$getextra${getsep}designer=" . LJ::eurl($theme_designer) . "$filterarg' class='theme-designer'>$theme_designer</a>";
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
                user => $u->user,
                apply_themeid => $theme->themeid,
                apply_layoutid => $theme->layoutid,
            );
            $ret .= $class->html_submit( "apply" => $class->ml('widget.themechooser.theme.apply'), { raw => "class='theme-button'" });
            $ret .= $class->end_form;
        }
        $ret .= "</div><!-- end .theme-item -->";
    }

    $ret .= "<ul class='theme-paging theme-paging-bottom nostyle'>";
    $ret .= $class->print_paging(
        themes => \@themes,
        num_per_page => $num_per_page,
        page => $page,
        getargs => \@getargs,
        getextra => $getextra,
    );
    $ret .= "</ul>";

    $ret .= "</div><!-- end .theme-selector-content -->";

    return $ret;
}

sub print_paging {
    my $class = shift;
    my %opts = @_;

    my $themes = $opts{themes};
    my $page = $opts{page};
    my $num_per_page = $opts{num_per_page};

    my $max_page = POSIX::ceil(scalar(@$themes) / $num_per_page) || 1;
    return "" if $page == 1 && $max_page == 1;

    my $page_padding = 2; # number of pages to show on either side of the current page
    my $start_page = $page - $page_padding > 1 ? $page - $page_padding : 1;
    my $end_page = $page + $page_padding < $max_page ? $page + $page_padding : $max_page;

    my $getargs = $opts{getargs};
    my $getextra = $opts{getextra};

    my $q_string = join("&", @$getargs);
    my $q_sep = $q_string ? "&" : "";
    my $getsep = $getextra ? "&" : "?";

    my $url = "$LJ::SITEROOT/customize2/$getextra$getsep$q_string$q_sep";

    my $ret;
    if ($page - 1 >= 1) {
        $ret .= "<li class='first'><a href='${url}page=" . ($page - 1) . "' class='theme-page'>&lt;</a></li>";
    }
    if ($page - $page_padding > 1) {
        $ret .= "<li><a href='${url}page=1' class='theme-page'>1</a></li><li>&hellip;</li>";
    }
    for (my $i = $start_page; $i <= $end_page; $i++) {
        my $li_class = " class='on'" if $i == $page;
        if ($i == $page) {
            $ret .= "<li$li_class>$i</li>";
        } else {
            $ret .= "<li$li_class><a href='${url}page=$i' class='theme-page'>$i</a></li>";
        }
    }
    if ($page + $page_padding < $max_page) {
        $ret .= "<li>&hellip;</li><li><a href='${url}page=$max_page' class='theme-page'>$max_page</a></li>";
    }
    if ($page + 1 <= $max_page) {
        $ret .= "<li class='last'><a href='${url}page=" . ($page + 1) . "' class='theme-page'>&gt;</a></li>";
    }

    return $ret;
}

sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    my $u = $post->{user} || LJ::get_remote();
    $u = LJ::load_user($u) unless LJ::isu($u);
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
            filter_links = filter_links.concat(DOM.getElementsByClassName(document, "theme-page"));

            // add event listeners to all of the category, layout, designer, and page links
            // adding an event listener to page is done separately because we need to be sure to use that if it is there,
            //     and we will miss it if it is there but there was another arg before it in the URL
            filter_links.forEach(function (filter_link) {
                var getArgs = LiveJournal.parseGetArgs(filter_link.href);
                if (getArgs["page"]) {
                    DOM.addEventListener(filter_link, "click", function (evt) { Customize.ThemeNav.filterThemes(evt, "page", getArgs["page"]) });
                } else {
                    for (var arg in getArgs) {
                        if (arg == "authas" || arg == "filter_available") continue;
                        DOM.addEventListener(filter_link, "click", function (evt) { Customize.ThemeNav.filterThemes(evt, arg, getArgs[arg]) });
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
        applyTheme: function (evt, form) {
            this.doPost({
                user: Customize.username,
                apply_themeid: form.Widget_ThemeChooser_apply_themeid.value,
                apply_layoutid: form.Widget_ThemeChooser_apply_layoutid.value,
            });
            Event.stop(evt);
        },
        onData: function (data) {
            Customize.ThemeNav.updateContent({
                user: Customize.username,
                cat: Customize.cat,
                layoutid: Customize.layoutid,
                designer: Customize.designer,
                custom: Customize.custom,
                filter_available: Customize.filter_available,
                page: Customize.page,
                getextra: Customize.getExtra,
                theme_chooser_id: $('theme_chooser_id').value,
            });
            Customize.CurrentTheme.updateContent({
                user: Customize.username,
                getextra: Customize.getExtra,
                filter_available: Customize.filter_available,
            });
        },
        onRefresh: function (data) {
            this.initWidget();
        },
    ];
}

1;
