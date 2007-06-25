var JournalTitle = new Object();

JournalTitle.init = function () {
    // store current field values
    JournalTitle.journaltitle_value = $("journaltitle").value;
    JournalTitle.journalsubtitle_value = $("journalsubtitle").value;
    JournalTitle.friendspagetitle_value = $("friendspagetitle").value;

    // show view mode
    $("journaltitle_view").style.display = "inline";
    $("journalsubtitle_view").style.display = "inline";
    $("friendspagetitle_view").style.display = "inline";
    $("journaltitle_cancel").style.display = "inline";
    $("journalsubtitle_cancel").style.display = "inline";
    $("friendspagetitle_cancel").style.display = "inline";
    $("journaltitle_modify").style.display = "none";
    $("journalsubtitle_modify").style.display = "none";
    $("friendspagetitle_modify").style.display = "none";

    // set up edit links
    DOM.addEventListener($("journaltitle_edit"), "click", JournalTitle.editTitle.bindEventListener("journaltitle"));
    DOM.addEventListener($("journalsubtitle_edit"), "click", JournalTitle.editTitle.bindEventListener("journalsubtitle"));
    DOM.addEventListener($("friendspagetitle_edit"), "click", JournalTitle.editTitle.bindEventListener("friendspagetitle"));

    // set up cancel links
    DOM.addEventListener($("journaltitle_cancel"), "click", JournalTitle.cancelTitle.bindEventListener("journaltitle"));
    DOM.addEventListener($("journalsubtitle_cancel"), "click", JournalTitle.cancelTitle.bindEventListener("journalsubtitle"));
    DOM.addEventListener($("friendspagetitle_cancel"), "click", JournalTitle.cancelTitle.bindEventListener("friendspagetitle"));
}

JournalTitle.editTitle = function (evt) {
    var id = this;
    $(id + "_modify").style.display = "inline";
    $(id + "_view").style.display = "none";
}

JournalTitle.cancelTitle = function (evt) {
    var id = this;
    $(id + "_modify").style.display = "none";
    $(id + "_view").style.display = "inline";

    // reset appropriate field to default
    if (id == "journaltitle") {
        $("journaltitle").value = JournalTitle.journaltitle_value;
    } else if (id == "journalsubtitle") {
        $("journalsubtitle").value = JournalTitle.journalsubtitle_value;
    } else if (id == "friendspagetitle") {
        $("friendspagetitle").value = JournalTitle.friendspagetitle_value;
    }
}

LiveJournal.register_hook("page_load", JournalTitle.init);
