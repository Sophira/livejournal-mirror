package LJ::Widget::MoodThemeChooser;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Customize );

sub ajax { 1 }
sub need_res { qw( stc/widgets/moodthemechooser.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} || LJ::get_remote();
    $u = LJ::load_user($u) unless LJ::isu($u);
    die "Invalid user." unless LJ::isu($u);

    my $getextra = $opts{getextra} ? $opts{getextra} : "";
    my $preview_moodthemeid = defined $opts{preview_moodthemeid} ? $opts{preview_moodthemeid} : $u->{moodthemeid};
    my $forcemoodtheme = defined $opts{forcemoodtheme} ? $opts{forcemoodtheme} : $u->{opt_forcemoodtheme} eq 'Y';

    my $ret = "<fieldset><legend>" . $class->ml('widget.moodthemechooser.title') . "</legend></fieldset>";
    $ret .= "<p class='detail'>" . $class->ml('widget.moodthemechooser.desc') . " " . LJ::help_icon('mood_themes') . "</p>";

    my @themes = LJ::Customize->get_moodtheme_select_list($u);

    $ret .= "<div class='moodtheme-form'>";
    $ret .= $class->html_select(
        { name => 'moodthemeid',
          id => 'moodtheme_dropdown',
          selected => $preview_moodthemeid },
        map { {value => $_->{moodthemeid}, text => $_->{name}, disabled => $_->{disabled}} } @themes,
    ) . "<br />";
    $ret .= $class->html_check(
        name => 'opt_forcemoodtheme',
        id => 'opt_forcemoodtheme',
        selected => $forcemoodtheme,
    );
    $ret .= "<label for='opt_forcemoodtheme'>" . $class->ml('widget.moodthemechooser.forcetheme') . "</label>";

    my $journalarg = $getextra ? "?journal=" . $u->user : "";
    $ret .= "<ul class='moodtheme-links nostyle'>";
    $ret .= "<li><a href='$LJ::SITEROOT/moodlist.bml$journalarg'>" . $class->ml('widget.moodthemechooser.links.allthemes') . "</a></li>";
    $ret .= "<li><a href='$LJ::SITEROOT/manage/moodthemes.bml$getextra'>" . $class->ml('widget.moodthemechooser.links.customthemes') . "</a></li>";
    $ret .= "</ul>";
    $ret .= "</div>";

    LJ::load_mood_theme($preview_moodthemeid);
    my @show_moods = ('happy', 'sad', 'angry', 'tired');

    if ($preview_moodthemeid) {
        $ret .= "<div class='moodtheme-preview'>";
        foreach my $mood (@show_moods) {
            my %pic;
            if (LJ::get_mood_picture($preview_moodthemeid, LJ::mood_id($mood), \%pic)) {
                $ret .= "<img class='moodtheme-img' align='absmiddle' alt='$mood' src=\"$pic{pic}\" width='$pic{w}' height='$pic{h}' />";
            }
        }
        $ret .= "<a href='$LJ::SITEROOT/moodlist.bml?moodtheme=$preview_moodthemeid'>" . $class->ml('widget.moodthemechooser.viewtheme') . "</a>";
        $ret .= "</div>";
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

    my %update;
    my $moodthemeid = LJ::Customize->validate_moodthemeid($u, $post->{moodthemeid});
    $update{moodthemeid} = $moodthemeid;
    $update{opt_forcemoodtheme} = $post->{opt_forcemoodtheme} ? "Y" : "N";

    # update 'user' table
    foreach (keys %update) {
        delete $update{$_} if $u->{$_} eq $update{$_};
    }
    LJ::update_user($u, \%update) if %update;

    # reload the user object to force the display of these changes
    $u = LJ::load_user($u->user, 'force');

    return;
}

sub js {
    q [
        initWidget: function () {
            var self = this;

            DOM.addEventListener($('moodtheme_dropdown'), "change", function (evt) { self.previewMoodTheme(evt) });
        },
        previewMoodTheme: function (evt) {
            var opt_forcemoodtheme = 0;
            if ($('opt_forcemoodtheme').checked) opt_forcemoodtheme = 1;

            this.updateContent({
                user: Customize.username,
                getextra: Customize.getExtra,
                preview_moodthemeid: $('moodtheme_dropdown').value,
                forcemoodtheme: opt_forcemoodtheme,
            });
        },
        onRefresh: function (data) {
            this.initWidget();
        },
    ];
}

1;
