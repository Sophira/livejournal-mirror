package LJ::Widget::VerticalEntries;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Vertical );

sub need_res { qw( stc/widgets/verticalentries.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $name = $opts{name};
    my $page = $opts{page} ? $opts{page} : 1;

    die "Invalid vertical name." unless exists $LJ::VERTICAL_TREE{$name};

    my $display_name = $LJ::VERTICAL_TREE{$name}->{display_name};
    my $vertical = LJ::Vertical->load_by_name($name);

    my $ret;

    my @recent_entries = $vertical->recent_entries;
    my $entries_per_page = 10;
    my $index_of_first_entry = $entries_per_page * ($page - 1);
    my $index_of_last_entry = ($entries_per_page * $page) - 1;
    my @entries_this_page = @recent_entries[$index_of_first_entry..$index_of_last_entry];

    my $title_displayed = 0;
    foreach my $entry (@entries_this_page) {
        next unless defined $entry && $entry->valid;
        next unless $entry->should_be_in_verticals;

        # display the title in here so we don't show it if there's no entries to show
        unless ($title_displayed) {
            $ret .= "<h2>" . $class->ml('widget.verticalentries.title', { verticalname => $display_name }) . "</h2>";
            $title_displayed = 1;
        }

        $ret .= "<table class='entry'><tr>";

        $ret .= "<td class='userpic'>";
        $ret .= $entry->userpic->imgtag_lite if $entry->userpic;
        $ret .= "<p class='poster'>" . $entry->poster->ljuser_display;
        unless ($entry->posterid == $entry->journalid) {
            $ret .= "<br />" . $class->ml('widget.verticalentries.injournal', { user => $entry->journal->ljuser_display });
        }
        $ret .= "</p></td>";

        $ret .= "<td class='content'>";

        # subject
        $ret .= "<p class='subject'><a href='" . $entry->url . "'><strong>";
        $ret .= $entry->subject_text || "<em>" . $class->ml('widget.verticalentries.nosubject') . "</em>";
        $ret .= "</strong></a>";

        # remove from vertical button
        if ($vertical->remote_can_remove_entry($entry)) {
            my $confirm_text = $class->ml('widget.verticalentries.remove.confirm', { verticalname => $display_name });
            my $btn_alt = $class->ml('widget.verticalentries.remove.alt', { verticalname => $display_name });

            $ret .= LJ::Widget::VerticalContentControl->start_form(
                onsubmit => "if (confirm('$confirm_text')) { return true; } else { return false; }"
            );
            $ret .= LJ::Widget::VerticalContentControl->html_hidden( remove => 1, entry_url => $entry->url, verticals => $vertical->vertid );
            $ret .= " <input type='image' src='$LJ::IMGPREFIX/btn_del.gif' alt='$btn_alt' title='$btn_alt' />";
            $ret .= LJ::Widget::VerticalContentControl->end_form;
        }
        $ret .= "</p>";

        # entry text
        $ret .= "<p class='event'>" . substr(LJ::strip_html($entry->event_text), 0, 400) . " &hellip;</p>";

        # tags
        my @tags = $entry->tags;
        if (@tags) {
            my $tag_list = join(", ",
                map  { "<a href='" . LJ::eurl($entry->journal->journal_base . "/tag/$_") . "'>" . LJ::ehtml($_) . "</a>" }
                sort { lc $a cmp lc $b } @tags);
            $ret .= "<p class='tags'>" . $class->ml('widget.verticalentries.tags') . " $tag_list</p>";
        }

        # post time and comments link
        my $secondsago = time() - $entry->logtime_unix;
        my $posttime = LJ::ago_text($secondsago);
        $ret .= "<p class='posttime'>" . $class->ml('widget.verticalentries.posttime', { posttime => $posttime });
        $ret .= " | <a href='" . $entry->url . "'>";
        $ret .= $entry->reply_count ? $class->ml('widget.verticalentries.replycount', { count => $entry->reply_count }) : $class->ml('widget.verticalentries.nocomments');
        $ret .= "</a></p>";

        $ret .= "</td>";
        $ret .= "</tr></table>";

        $ret .= "<hr />";
    }

    return $ret;
}

1;
