var Customize = new Object();

Customize.init = function () {
    Customize.cat = "";
    Customize.layoutid = 0;
    Customize.designer = "";
    Customize.filter_available = 0;
    Customize.page = 1;
    Customize.hourglass = null;

    var pageGetArgs = LiveJournal.parseGetArgs(document.location.href);

    if (pageGetArgs["cat"]) {
        Customize.cat = pageGetArgs["cat"];
    }

    if (pageGetArgs["layoutid"]) {
        Customize.layoutid = pageGetArgs["layoutid"];
    }

    if (pageGetArgs["designer"]) {
        Customize.designer = pageGetArgs["designer"];
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
    Customize.page = 1;
}

Customize.cursorHourglass = function (evt) {
    var pos = DOM.getAbsoluteCursorPosition(evt);
    if (!pos) return;

    if (!Customize.hourglass) {
        Customize.hourglass = new Hourglass();
        Customize.hourglass.init();
        Customize.hourglass.hourglass_at(pos.x, pos.y);
    }
}

Customize.elementHourglass = function (element) {
    if (!element) return;

    if (!Customize.hourglass) {
        Customize.hourglass = new Hourglass();
        Customize.hourglass.init();
        Customize.hourglass.hourglass_at_widget(element);
    }
}

Customize.hideHourglass = function () {
    if (Customize.hourglass) {
        Customize.hourglass.hide();
        Customize.hourglass = null;
    }
}

LiveJournal.register_hook("page_load", Customize.init);
