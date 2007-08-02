package LJ::Widget::InboxFolder;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

# DO NOT COPY
# This widget is not a good example of how to use JS and AJAX.
# This widget's render_body outputs HTML similar to the HTML
# output originally by the Notifications Inbox page. This was
# done so that the existing JS, CSS and Endpoints could be used.

sub need_res {
    return qw(
            js/core.js
            js/dom.js
            js/view.js
            js/controller.js
            js/datasource.js
            js/checkallbutton.js
            js/selectable_table.js
            js/httpreq.js
            js/hourglass.js
            js/esn_inbox.js
            stc/esn.css
            stc/lj_base.css
            );
}

# args
#   folder: the view or subset of notification items to display
#   reply_btn: should we show a reply button or link
#   expand: display a specified in expanded view
#   inbox: NotificationInbox object
#   items: list of notification items
sub render_body {
    my $class = shift;
    my %opts = @_;

    my $name = $opts{folder};
    my $show_reply_btn = $opts{reply_btn} || 0;
    my $expand = $opts{expand} || 0;
    my $inbox = $opts{inbox};
    my $nitems = $opts{items};
    my $page = $opts{page} || 1;
    my $view = $opts{view} || "all";
    my $remote = LJ::get_remote();

    my $unread_count = 1; #TODO get real number
    my $disabled = $unread_count ? '' : 'disabled';

    # print form
    my $msgs_body .= qq {
        <form action="$LJ::SITEROOT/inbox/" method="POST" id="${name}Form" onsubmit="return false;">
        };

    $msgs_body .= LJ::html_hidden({
                    name  => "view",
                    value => "$view",
                    id    => "inbox_view",
                  });

    # pagination
    my $page_limit = 15;
    $page = 1 if $page < 1;
    my $last_page = POSIX::ceil((scalar @$nitems) / $page_limit);
    $last_page ||= 1;
    $page = $last_page if $page > $last_page;

    my $prev_disabled = ($page <= 1) ? 'disabled' : '';
    my $next_disabled = ($page >= $last_page) ? 'disabled' : '';

    my $actionsrow = sub {
        my $sfx = shift; # suffix

        # check all checkbox
        my $checkall = LJ::html_check({
            id      => "${name}_CheckAll_$sfx",
            class   => "InboxItem_Check",
        });

        return qq {
             <tr class="header">
                <thead>
                    <td class="checkbox">$checkall</td>
                    <td class="actions" colspan="2">
                        <span class="Pages">
                            Page $page of $last_page
                            <input type="button" id="Page_Prev_$sfx" value="Previous" $prev_disabled />
                            <input type="button" id="Page_Next_$sfx" value="Next" $next_disabled />
                        </span>
                        <input type="submit" name="markRead_$sfx" value="Read" $disabled id="${name}_MarkRead_$sfx" />
                        <input type="submit" name="markUnread_$sfx" value="Unread" id="${name}_MarkUnread_$sfx" />
                        <input type="submit" name="delete_$sfx" value="Delete" id="${name}_Delete_$sfx" />
                        <input type="submit" name="markAllRead_$sfx" value="Mark All Read" $disabled id="${name}_MarkAllRead_$sfx" />
                    </td>
                </thead>
            </tr>
        };
    };
    # create table of messages
    my $messagetable = qq {
     <div id="${name}_Table" class="NotificationTable">
        <table id="${name}" class="inbox" cellspacing="0" border="0" cellpadding="0">
        };
    $messagetable .= $actionsrow->(1);
    $messagetable .= "<tbody id='${name}_Body'>";

    unless (@$nitems) {
        $messagetable .= qq {
            <tr><td class="NoItems" colspan="3">No Messages</td></tr>
            };
    }

    @$nitems = sort { $b->when_unixtime <=> $a->when_unixtime } @$nitems;

    # print out messages
    my $rownum = 0;

    my $starting_index = ($page - 1) * $page_limit;
    for (my $i = $starting_index; $i < $starting_index + $page_limit; $i++) {
        my $inbox_item = $nitems->[$i];
        last unless $inbox_item;

        my $qid  = $inbox_item->qid;

        my $read_class = $inbox_item->read ? "InboxItem_Read" : "InboxItem_Unread";

        my $title  = $inbox_item->title;

        my $checkbox_name = "${name}_Check-$qid";
        my $checkbox = LJ::html_check({
            id    => $checkbox_name,
            class => "InboxItem_Check",
            name  => $checkbox_name,
        });

        # HTML for displaying bookmark flag
        my $bookmark = $inbox->is_bookmark($qid)
            ? "on"
            : "off";
        $bookmark = "<a href='$LJ::SITEROOT/inbox/?page=$page&bookmark_$bookmark=$qid'><img src='$LJ::IMGPREFIX/flag_$bookmark.gif' width='16' height='18' class='InboxItem_Bookmark' border='0' /></a>";

        my $when = LJ::ago_text(time() - $inbox_item->when_unixtime);
        my $contents = $inbox_item->as_html || '';

        my $row_class = ($rownum++ % 2 == 0) ? "InboxItem_Meta" : "InboxItem_Meta alt";

        my $expandbtn = '';
        my $content_div = '';

        if ($contents) {
            BML::ebml(\$contents);

            my $expanded = $expand && $expand == $qid;
            $expanded ||= $remote->prop('esn_inbox_default_expand');
            $expanded = 0 if $inbox_item->read;

            my $img = $expanded ? "expand.gif" : "collapse.gif";

            $expandbtn = qq {
                <a href="$LJ::SITEROOT/inbox/?page=$page&expand=$qid"><img src="$LJ::IMGPREFIX/$img" class="InboxItem_Expand" border="0" /></a>
                };

            my $display = $expanded ? "block" : "none";

            $content_div = qq {
                <div class="InboxItem_Content" style="display: $display;">$contents</div>
                };
        }

        $messagetable .= qq {
            <tr class="InboxItem_Row $row_class" lj_qid="$qid" id="${name}_Row_$qid">
                <td class="checkbox">$checkbox</td>
                <td class="item">
                    <div class="InboxItem_Controls">$bookmark $expandbtn</div>
                    <span class="$read_class" id="${name}_Title_$qid">$title</span>
                    $content_div
                    </td>
                    <td class="time">$when</td>
                </tr>
        };
    }

    $messagetable .= $actionsrow->(2);
    $messagetable .= '</tbody></table></div>';


    $msgs_body .= $messagetable;

    $msgs_body .= LJ::html_hidden({
        name  => "page",
        id    => "pageNum",
        value => $page,
    });

    $msgs_body .= qq {
        </form>
        };

    return $msgs_body;
}

1;
