package LJ::Widget::JournalTitles;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub ajax { 1 }
sub need_res { qw( stc/widgets/journaltitles.css js/widgets/journaltitles.js ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} || LJ::get_remote();
    $u = LJ::load_userid($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my $ret;
    $ret .= "<h2 class='widget-header'>" . $class->ml('widget.journaltitles.title') . "</h2>";
    $ret .= "<div class='theme-titles-content'>";
    $ret .= "<p class='detail'>" . $class->ml('widget.journaltitles.desc') . " " . LJ::help_icon('journal_titles') . "</p>";

    foreach my $id (qw( journaltitle journalsubtitle friendspagetitle )) {
        $ret .= $class->start_form( id => "${id}_form" );

        $ret .= "<p>";
        $ret .= "<label>" . $class->ml("widget.journaltitles.$id") . "</label> ";
        $ret .= "<span id='${id}_view'>";
        $ret .= "<strong>" . $u->prop($id) . "</strong> ";
        $ret .= "<a href='' class='theme-title-control' id='${id}_edit'>" . $class->ml('widget.journaltitles.edit') . "</a>";
        $ret .= "</span>";

        $ret .= "<span id='${id}_modify'>";
        $ret .= $class->html_text(
            name => 'title_value',
            id => $id,
            value => $u->prop($id),
            size => '30',
            maxlength => LJ::std_max_length(),
            raw => "class='text'",
        ) . " ";
        $ret .= $class->html_hidden( which_title => $id );
        $ret .= $class->html_hidden({ name => "user", value => $u->id, id => "${id}_user" });
        $ret .= $class->html_submit($class->ml('widget.journaltitles.btn')) . " ";
        $ret .= "<a href='' class='theme-title-control' id='${id}_cancel'>" . $class->ml('widget.journaltitles.cancel') . "</a>";
        $ret .= "</span></p>";

        $ret .= $class->end_form;
    }

    $ret .= "</div>";

    return $ret;
}

sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    my $u = $post->{user} || LJ::get_remote();
    $u = LJ::load_userid($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my $eff_val = LJ::text_trim($post->{title_value}, 0, LJ::std_max_length());
    $eff_val = "" unless $eff_val;
    $u->set_prop($post->{which_title}, $eff_val);

    return;
}

sub js {
    q [
        initWidget: function () {
            var self = this;

            DOM.addEventListener($("journaltitle_form"), "submit", function (e) { self.saveTitle(e, "journaltitle") });
            DOM.addEventListener($("journalsubtitle_form"), "submit", function (e) { self.saveTitle(e, "journalsubtitle") });
            DOM.addEventListener($("friendspagetitle_form"), "submit", function (e) { self.saveTitle(e, "friendspagetitle") });
        },
        saveTitle: function (e, id) {
            this.userid = $(id + "_user").value;
            this.doPostAndUpdateContent({which_title: id, title_value: $(id).value, user: this.userid});
            Event.stop(e); // prevent the page from posting without AJAX
        },
        onRefresh: function (data) {
            this.initWidget();
            JournalTitle.init();
        },
    ];    
}

1;
