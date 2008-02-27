var CreateAccount = new Object();

CreateAccount.init = function () {
    if (!$('create_user')) return;
    if (!$('create_email')) return;
    if (!$('create_password1')) return;
    if (!$('create_bday_mm')) return;
    if (!$('create_bday_dd')) return;
    if (!$('create_bday_yyyy')) return;
    if (!$('create_answer')) return;

    DOM.addEventListener($('create_user'), "focus", CreateAccount.showTip.bindEventListener("create_user"));
    DOM.addEventListener($('create_email'), "focus", CreateAccount.showTip.bindEventListener("create_email"));
    DOM.addEventListener($('create_password1'), "focus", CreateAccount.showTip.bindEventListener("create_password1"));
    DOM.addEventListener($('create_password2'), "focus", CreateAccount.showTip.bindEventListener("create_password1"));
    DOM.addEventListener($('create_bday_mm'), "focus", CreateAccount.showTip.bindEventListener("create_bday_mm"));
    DOM.addEventListener($('create_bday_dd'), "focus", CreateAccount.showTip.bindEventListener("create_bday_mm"));
    DOM.addEventListener($('create_bday_yyyy'), "focus", CreateAccount.showTip.bindEventListener("create_bday_mm"));
    DOM.addEventListener($('create_answer'), "focus", CreateAccount.showTip.bindEventListener("create_answer"));
}

CreateAccount.showTip = function (evt) {
    var id = this + "";

    var x = DOM.findPosX($(id));
    var y = DOM.findPosY($(id));

    var text;
    if (id == "create_bday_mm") {
        text = CreateAccount.birthdate;
    } else if (id == "create_answer") {
        text = CreateAccount.captcha;
    } else if (id == "create_email") {
        text = CreateAccount.email;
    } else if (id == "create_password1") {
        text = CreateAccount.password;
    } else if (id == "create_user") {
        text = CreateAccount.username;
    }

    if ($('tips_box') && $('tips_box_arrow')) {
        $('tips_box').innerHTML = text;

        $('tips_box').style.left = x + 160 + "px";
        $('tips_box').style.top = y - 205 + "px";
        $('tips_box').style.display = "block";

        $('tips_box_arrow').style.left = x + 149 + "px";
        $('tips_box_arrow').style.top = y - 200 + "px";
        $('tips_box_arrow').style.display = "block";
    }
}

LiveJournal.register_hook("page_load", CreateAccount.init);
