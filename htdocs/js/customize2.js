var Customize = new Object();

Customize.init = function () {
    Customize.username = "";
    Customize.cat = "";
    Customize.layoutid = 0;
    Customize.designer = "";
    Customize.custom = 0;
    Customize.filter_available = 0;
    Customize.page = 1;
    Customize.getExtra = "";

    var pageGetArgs = LiveJournal.parseGetArgs(document.location.href);

    if (pageGetArgs["authas"]) {
        Customize.username = pageGetArgs["authas"];
        Customize.getExtra = "?authas=" + Customize.username;
    }

    if (pageGetArgs["cat"]) {
        Customize.cat = pageGetArgs["cat"];
    }

    if (pageGetArgs["layoutid"]) {
        Customize.layoutid = pageGetArgs["layoutid"];
    }

    if (pageGetArgs["designer"]) {
        Customize.designer = pageGetArgs["designer"];
    }

    if (pageGetArgs["custom"]) {
        Customize.custom = pageGetArgs["custom"];
    }

    if (pageGetArgs["filter_available"]) {
        Customize.filter_available = pageGetArgs["filter_available"];
    }

    if (pageGetArgs["page"]) {
        Customize.page = pageGetArgs["page"];
    }
}

Customize.resetFilters = function () {
    Customize.cat = "";
    Customize.layoutid = 0;
    Customize.designer = "";
    Customize.custom = 0;
    Customize.page = 1;
}

LiveJournal.register_hook("page_load", Customize.init);
