package LJ::Widget::InboxFolder;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
#use Class::Autouse qw( LJ::NotificationInbox );

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
    my $remote = LJ::get_remote();

    my $unread_count = 1; #TODO get real number
    my $disabled = $unread_count ? '' : 'disabled';

    # check all checkbox
    my $checkall = LJ::html_check({
        id      => "${name}_CheckAll",
    });

    # print form
    my $msgs_body .= qq {
        <form action="$LJ::SITEROOT/inbox/" method="POST" id="${name}Form" onsubmit="return false;">
        };

    $msgs_body .= LJ::html_hidden({
                    name  => "view",
                    value => "${name}"
                  });

    # create table of messages
    my $messagetable = qq {
     <div id="${name}_Table" class="NotificationTable">
        <table id="${name}" class="inbox" cellspacing="0" border="0" cellpadding="0">
            <tr class="header">
                <thead>
                    <td class="checkbox">$checkall</td>
                    <td class="actions" colspan="2">
                        <input type="submit" name="markRead" value="Read" $disabled id="${name}_MarkRead" />
                        <input type="submit" name="markUnread" value="Unread" id="${name}_MarkUnread" />
                        <input type="submit" name="delete" value="Delete" id="${name}_Delete" />
                        <input type="submit" name="markAllRead" value="Mark All Read" $disabled id="${name}_MarkAllRead" />
                    </td>
                </thead>
            </tr>

            <tbody id="${name}_Body">
        };

    unless (@$nitems) {
        $messagetable .= qq {
            <tr><td class="NoItems" colspan="3">No Messages</td></tr>
            };
    }

    @$nitems = sort { $b->when_unixtime <=> $a->when_unixtime } @$nitems;

    # print out messages
    my $rownum = 0;
    my $page = 1;
    my $page_limit = 15;

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

        my $bookmark = $inbox->is_bookmark($qid)
            ? "<span class='InboxItem_Bookmark'>F</span>"
            : "<span class='InboxItem_Bookmark'>--</span>";

        my $when = LJ::ago_text(time() - $inbox_item->when_unixtime);
        my $contents = $inbox_item->as_html || ' ';

        my $row_class = ($rownum++ % 2 == 0) ? "InboxItem_Meta" : "InboxItem_Meta alt";

        my $expandbtn = '';
        my $content_div = '';

        my $msgid = $inbox_item->event->load_message->msgid;
        my $buttons = qq {
                          <div style="border: 1px dashed #ddd; background-color: #eee; padding: 2px; float: left;" class="pkg">
                          <a href="./compose.bml?mode=reply&msgid=$msgid"
                          style="padding: 2px; background-color: #fff"> REPLY </a></div>
                          <div style="clear: both"></div>
                      };


        if ($contents) {
            # TODO check that clean_event will be cool instead of ebml
            #BML::ebml(\$contents);
            LJ::CleanHTML::clean_event(\$contents);

            my $expanded = $expand && $expand == $qid;
            $expanded ||= $remote->prop('esn_inbox_default_expand');
            $expanded = 0 if $inbox_item->read;

            my $img = $expanded ? "expand.gif" : "collapse.gif";

            $expandbtn = qq {
                <a href="$LJ::SITEROOT/inbox/?page=$page&expand=$qid"><img src="$LJ::IMGPREFIX/$img" class="InboxItem_Expand" border="0" /></a>
                };

            my $display = $expanded ? "block" : "none";

            $content_div = qq {
                <div class="InboxItem_Content" style="display: $display;">$buttons $contents</div>
                };
        }

        $messagetable .= qq {
            <tr class="InboxItem_Row $row_class" lj_qid="$qid" id="${name}_Row_$qid">
                <td class="checkbox">$checkbox</td>
                <td class="item">
                    <span class="$read_class" id="${name}_Title_$qid">$bookmark$title</span>
                    $expandbtn
                    $content_div
                    </td>
                    <td class="time">$when</td>
                </tr>
        };
    }

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
