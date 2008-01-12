var ESN_Inbox = {
    "hourglass": null,
    "selected_qids": []
};

DOM.addEventListener(window, "load", function (evt) {
  for (var i=0; i<folders.length; i++) {
      var folder = folders[i];
      ESN_Inbox.initTableSelection(folder);
      ESN_Inbox.initContentExpandButtons(folder);
      ESN_Inbox.initInboxBtns(folder);
  }
});

// Set up table events
ESN_Inbox.initTableSelection = function (folder) {
    var selectedRows = new SelectableTable;
    selectedRows.init({
        "table": $(folder),
            "selectedClass": "Selected",
            "multiple": true,
            "checkboxClass": "InboxItem_Check",
            "selectableClass": "InboxItem_Row"
            });

    if (!selectedRows) return;

    selectedRows.addWatcher(ESN_Inbox.selectedRowsChanged);

    // find selected checkboxes in rows, and select those rows
    var domElements = document.getElementsByTagName("input");
    var checkboxes = DOM.filterElementsByClassName(domElements, "InboxItem_Check") || [];

    Array.prototype.forEach.call(checkboxes, function (checkbox) {
        if (!checkbox.checked) return;

        var parentRow = DOM.getFirstAncestorByClassName(checkbox, "InboxItem_Row");
        if (parentRow)
            parentRow.rowClicked();
    });

    var bookmarks = DOM.getElementsByClassName($(folder), "InboxItem_Bookmark") || [];

    ESN_Inbox.bookmarked = []; /* Keep record of qids that are bookmarked */
    Array.prototype.forEach.call(bookmarks, function (bmark) {
        bmark.folder = folder;
        /* Listen for click on bookmark icon */
        DOM.addEventListener(bmark, "click", ESN_Inbox.bookmarkClicked.bindEventListener(bmark));
        var on_string = /_on/;

        /* Populate hash of qids bookmarked */
        if (bmark.src.match(on_string)) {
            var row = DOM.getFirstAncestorByClassName(bmark, "InboxItem_Row");
            var qid = row.getAttribute("lj_qid");
            ESN_Inbox.bookmarked[qid] = true;
        }
    });

};

ESN_Inbox.is_bookmark = function(qid) {
    if (ESN_Inbox.bookmarked[qid]) return true;
    return false;
}

// Handle the event where the bookmark flag is clicked on
ESN_Inbox.bookmarkClicked = function(evt) {
    var row = DOM.getFirstAncestorByClassName(this, "InboxItem_Row");
    var qid = row.getAttribute("lj_qid");
    ESN_Inbox.bookmark(evt, this.folder, qid);
}

// Callback for when selected rows of the inbox change
ESN_Inbox.selectedRowsChanged = function (rows) {
    // find the selected qids
    ESN_Inbox.selected_qids = [];
    rows.forEach(function (row) {
        ESN_Inbox.selected_qids.push(row.getAttribute("lj_qid"));
    });
};

// set up event handlers on expand buttons
ESN_Inbox.initContentExpandButtons = function (folder) {
    var domElements = document.getElementsByTagName("*");
    var buttons = DOM.filterElementsByClassName(domElements, "InboxItem_Expand") || [];

    Array.prototype.forEach.call(buttons, function (button) {
        DOM.addEventListener(button, "click", function (evt) {
            if (evt.shiftKey) {
                // if shift key, make all like inverse of current button
                var expand = button.src == Site.imgprefix + "/collapse.gif" ? 'collapse' : 'expand';
                ESN_Inbox.saveDefaultExpanded(expand == 'collapse');
                buttons.forEach(function (btn) { ESN_Inbox.toggleExpand(btn, expand) });
            } else {
                if (ESN_Inbox.toggleExpand(button))
                    return true;
            }

            Event.stop(evt);
            return false;
        });
    });
};

ESN_Inbox.toggleExpand = function (button, state) {
    // find content div
    var parent = DOM.getFirstAncestorByClassName(button, "InboxItem_Row");
    var children = parent.getElementsByTagName("div");
    var contentContainers = DOM.filterElementsByClassName(children, "InboxItem_Content");
    var contentContainer = contentContainers[0];

    if (!contentContainer) return true;

    if (state) {
        if (state == "expand") {
            contentContainer.style.display = "none";
            button.src = Site.imgprefix + "/collapse.gif";
        } else {
            contentContainer.style.display = "block";
            button.src = Site.imgprefix + "/expand.gif";
        }
    } else {
        if (contentContainer.style.display == "none") {
            contentContainer.style.display = "block";
            button.src = Site.imgprefix + "/expand.gif";
        } else {
            contentContainer.style.display = "none";
            button.src = Site.imgprefix + "/collapse.gif";
        }
    }
    return false;
};

// do ajax request to save the default expanded state
ESN_Inbox.saveDefaultExpanded = function (expanded) {
    var postData = {
        "action": "set_default_expand_prop",
        "default_expand": (expanded ? "Y" : "N")
    };

    var opts = {
        "data": HTTPReq.formEncoded(postData),
        "method": "POST",
        "onError": ESN_Inbox.reqError
    };

    opts.url = Site.currentJournal ? "/" + Site.currentJournal + "/__rpc_esn_inbox" : "/__rpc_esn_inbox";

    HTTPReq.getJSON(opts);
};

// set up inbox buttons
ESN_Inbox.initInboxBtns = function (folder) {
    // 2 instances of action buttons
    for (var i=1; i<=2; i++) {
        DOM.addEventListener($(folder + "_MarkRead_" + i), "click", function(e) { ESN_Inbox.markRead(e, folder) });
        DOM.addEventListener($(folder + "_MarkUnread_" + i), "click", function(e) { ESN_Inbox.markUnread(e, folder) });
        DOM.addEventListener($(folder + "_Delete_" + i), "click", function(e) { ESN_Inbox.deleteItems(e, folder) });
        DOM.addEventListener($(folder + "_MarkAllRead_" + i), "click", function(e) { ESN_Inbox.markAllRead(e, folder) });
    }
};

ESN_Inbox.markRead = function (evt, folder) {
    Event.stop(evt);
    ESN_Inbox.updateItems('mark_read', evt, folder);
    return false;
};

ESN_Inbox.markUnread = function (evt, folder) {
    Event.stop(evt);
    ESN_Inbox.updateItems('mark_unread', evt, folder);
    return false;
};

ESN_Inbox.deleteItems = function (evt, folder) {
    Event.stop(evt);

    var has_bookmark = false;
    Array.prototype.forEach.call( ESN_Inbox.selected_qids, function (qid) {
        if (ESN_Inbox.is_bookmark(qid)) has_bookmark = true;
    });
    var msg = ESN_Inbox.confirmDelete;
    if (has_bookmark && msg && !confirm(msg)) return false;

    ESN_Inbox.updateItems('delete', evt, folder);
    return false;
};

ESN_Inbox.markAllRead = function (evt, folder) {
    Event.stop(evt);
    ESN_Inbox.updateItems('mark_all_read', evt, folder);
    return false;
};

ESN_Inbox.bookmark = function (evt, folder, qid) {
    Event.stop(evt);
    ESN_Inbox.updateItems('toggle_bookmark', evt, folder, qid);
    return false;
}

// do an ajax action on the currently selected items
ESN_Inbox.updateItems = function (action, evt, folder, qid) {
    if (!ESN_Inbox.hourglass) {
        var coords = DOM.getAbsoluteCursorPosition(evt);
        ESN_Inbox.hourglass = new Hourglass();
        ESN_Inbox.hourglass.init();
        ESN_Inbox.hourglass.hourglass_at(coords.x, coords.y);
        ESN_Inbox.evt = evt;
    }

    var qids = qid || ESN_Inbox.selected_qids.join(",");

    var postData = {
        "action": action,
        "qids": qids
    };

    var opts = {
        "data": HTTPReq.formEncoded(postData),
        "method": "POST",
        "onError": ESN_Inbox.reqError,
        "onData": function(info) { ESN_Inbox.finishedUpdate(info, folder) }
    };

    opts.url = Site.currentJournal ? "/" + Site.currentJournal + "/__rpc_esn_inbox" : "/__rpc_esn_inbox";

    HTTPReq.getJSON(opts);
};

// got error doing ajax request
ESN_Inbox.reqError = function (error) {
    log(error);
    if (ESN_Inbox.hourglass) {
        ESN_Inbox.hourglass.hide();
        ESN_Inbox.hourglass = null;
    }
};

// successfully completed request
ESN_Inbox.finishedUpdate = function (info, folder) {
    if (ESN_Inbox.hourglass) {
        ESN_Inbox.hourglass.hide();
        ESN_Inbox.hourglass = null;
    }

    if (info.error) {
        var ele = ESN_Inbox.evt.target;
        var notice = top.LJ_IPPU.showErrorNote(info.error, ele);
        notice.centerOnWidget(ele, 20);
        return;
    }

    if (! info || ! info.success || ! defined(info.items)) return;

    var unread_count = 0;
    var usermsg_recvd_count = 0;
    var friend_count = 0;
    var entrycomment_count = 0;
    var inbox_count  = info.items.length;

    info.items.forEach(function (item) {
        var qid     = item.qid;
        var read    = item.read;
        var deleted = item.deleted;
        var bookmarked = item.bookmarked;
        if (!qid) return;

        if (!read && !deleted) unread_count++;

        var rowElement = $(folder + "_Row_" + qid);
        if (!rowElement) return;

        var bookmarks = DOM.getElementsByClassName(rowElement, "InboxItem_Bookmark") || [];
        for (var i=0; i<bookmarks.length; i++) {
            bookmarks[i].src = bookmarked ? Site.imgprefix + "/flag_on.gif" :
                                Site.imgprefix + "/flag_off.gif";
            ESN_Inbox.bookmarked[qid] = bookmarked ? true : false;
        }

        if (deleted) {
            rowElement.parentNode.removeChild(rowElement);
            inbox_count--;
        } else {
            var titleElement = $(folder + "_Title_" + qid);
            if (!titleElement) return;

            if (read) {
                DOM.removeClassName(titleElement, "InboxItem_Unread");
                DOM.addClassName(titleElement, "InboxItem_Read");
            } else {
                DOM.removeClassName(titleElement, "InboxItem_Read");
                DOM.addClassName(titleElement, "InboxItem_Unread");
            }
        }
    });

    ESN_Inbox.refresh_count("esn_folder_all", info.unread_all);
    ESN_Inbox.refresh_count("esn_folder_usermsg_recvd", info.unread_usermsg_recvd);
    ESN_Inbox.refresh_count("esn_folder_friendplus", info.unread_friend);
    ESN_Inbox.refresh_count("esn_folder_entrycomment", info.unread_entrycomment);

    // Bottom row of action buttons counts as 1 row
    if ($(folder + "_Body").getElementsByTagName("tr").length < 2) {
        // no rows left, refresh page if more messages
        if (inbox_count != 0)
            window.location.href = $("RefreshLink").href;
    }

    if (inbox_count == 0) {
        // reset if no messages
        var row = document.createElement("tr");
        var col = document.createElement("td");
        col.colSpan = "3";
        DOM.addClassName(col, "NoItems");
        col.innerHTML = "(No Messages)";

        row.appendChild(col);
        $(folder + "_Body").appendChild(row);
    }

    // 2 instances of action buttons with suffix 1 and 2
    for (var i=1; i<=2; i++) {
        $(folder + "_MarkRead_" + i).disabled    = unread_count ? false : true;
        $(folder + "_MarkAllRead_" + i).disabled = unread_count ? false : true;
    }
};

ESN_Inbox.refresh_count = function(name, count) {
    var unread_ele = DOM.getElementsByClassName($(name), "unread_count");
    if ($(name)) unread_ele[0].innerHTML = (count > 0) ? "(" +count+ ")" : " ";
};
