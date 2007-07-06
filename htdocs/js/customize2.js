var Customize = new Object();

Customize.init = function () {
    // figure out which username we are working with
    var pageGetArgs = LiveJournal.parseGetArgs(document.location.href);
    if (pageGetArgs["authas"]) {
        Customize.username = pageGetArgs["authas"];
        Customize.getExtra = "?authas=" + Customize.username;
    } else {
        Customize.username = "";
        Customize.getExtra = "";
    }
}

Customize.updateThemeChooser = function (evt, key, value) {
    Customize.ThemeChooser.filterThemes(evt, key, value);
}

Customize.updateCurrentTheme = function (params) {
    Customize.CurrentTheme.updateContent(params);
}

LiveJournal.register_hook("page_load", Customize.init);
