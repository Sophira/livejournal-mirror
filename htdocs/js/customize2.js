var Customize = new Object();

Customize.init = function () { }

Customize.updateThemeChooser = function (evt, key, value) {
    Customize.ThemeChooser.filterThemes(evt, key, value);
}

Customize.updateCurrentTheme = function (params) {
    Customize.CurrentTheme.updateContent(params);
}

LiveJournal.register_hook("page_load", Customize.init);
