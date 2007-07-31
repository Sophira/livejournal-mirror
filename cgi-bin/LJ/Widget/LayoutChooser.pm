package LJ::Widget::LayoutChooser;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Customize );

sub ajax { 1 }
sub need_res { qw( stc/widgets/layoutchooser.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} || LJ::get_remote();
    $u = LJ::load_user($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my $headextra = $opts{headextra};

    my $ret;
    $ret .= "<h2 class='widget-header'>" . $class->ml('widget.layoutchooser.title') . "</h2>";
    $ret .= "<p class='detail'>" . $class->ml('widget.layoutchooser.desc') . "</p>";

    if (eval "use LJ::Widget::AdLayout; 1;") {
        my $ad_layout = LJ::Widget::AdLayout->new;
        $$headextra .= $ad_layout->wrapped_js( page_js_obj => "Customize" ) if $headextra;
        $ret .= $ad_layout->render(user => $u);
    }

    # Column option
    my $current_theme = LJ::Customize->get_current_theme($u);
    my %layouts = $current_theme->layouts;
    my $layout_prop = $current_theme->layout_prop;
    my $show_sidebar_prop = $current_theme->show_sidebar_prop;
    my %layout_names = LJ::Customize->get_layouts;

    my $prop_value;
    if ($layout_prop || $show_sidebar_prop) {
        my $style = LJ::S2::load_style($u->prop('s2_style'));
        die "Style not found." unless $style && $style->{userid} == $u->id;

        LJ::Customize->load_all_s2_props($u, $style);
 
        if ($layout_prop) {
            my %prop_values = LJ::Customize->get_s2_prop_values($layout_prop, $style);
            $prop_value = $prop_values{override};
        }

        # for layouts that have a separate prop that turns off the sidebar, use the value of that
        # prop instead if the sidebar is set to be off (false/0).
        if ($show_sidebar_prop) {
            my %prop_values = LJ::Customize->get_s2_prop_values($show_sidebar_prop, $style);
            $prop_value = $prop_values{override} if $prop_values{override} == 0;
        }
    }

    foreach my $layout (sort keys %layouts) {
        my $current = (!$layout_prop) || ($layout_prop && $layouts{$layout} eq $prop_value) ? 1 : 0;
        my $current_class = $current ? " current" : "";

        $ret .= "<div class='layout-item$current_class'>";
        $ret .= "<img src='$LJ::IMGPREFIX/customize/layouts/$layout.png' class='layout-preview' />";
        $ret .= "<p class='layout-desc'>$layout_names{$layout}</p>";
        unless ($current) {
            $ret .= $class->start_form( class => "layout-form" );
            $ret .= $class->html_hidden(
                user => $u->user,
                layout_choice => $layout,
                layout_prop => $layout_prop,
                show_sidebar_prop => $show_sidebar_prop,
            );
            $ret .= $class->html_submit( "apply" => $class->ml('widget.layoutchooser.layout.apply'), { raw => "class='layout-button'" });
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

    my $u = $post->{user} || LJ::get_remote();
    $u = LJ::load_user($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my %override;
    my $layout_choice = $post->{layout_choice};
    my $layout_prop = $post->{layout_prop};
    my $show_sidebar_prop = $post->{show_sidebar_prop};
    my $current_theme = LJ::Customize->get_current_theme($u);
    my %layouts = $current_theme->layouts;

    # show_sidebar prop is set to false/0 if the 1 column layout was chosen,
    # otherwise it's set to true/1 and the layout prop is set appropriately.
    if ($show_sidebar_prop && $layout_choice eq "1") {
        $override{$show_sidebar_prop} = 0;
    } else {
        $override{$show_sidebar_prop} = 1 if $show_sidebar_prop;
        $override{$layout_prop} = $layouts{$layout_choice} if $layout_prop;
    }

    my $style = LJ::S2::load_style($u->prop('s2_style'));
    die "Style not found." unless $style && $style->{userid} == $u->id;

    LJ::Customize->save_s2_props($u, $style, \%override);

    return;
}

sub js {
    q [
        initWidget: function () {
            var self = this;

            var apply_forms = DOM.getElementsByClassName(document, "layout-form");

            // add event listeners to all of the apply layout forms
            apply_forms.forEach(function (form) {
                DOM.addEventListener(form, "submit", function (evt) { self.applyLayout(evt, form) });
            });
        },
        applyLayout: function (evt, form) {
            this.doPostAndUpdateContent({
                user: Customize.username,
                layout_choice: form.Widget_LayoutChooser_layout_choice.value,
                layout_prop: form.Widget_LayoutChooser_layout_prop.value,
                show_sidebar_prop: form.Widget_LayoutChooser_show_sidebar_prop.value,
            });
            Event.stop(evt);
        },
        onRefresh: function (data) {
            this.initWidget();
        },
    ];
}

1;
