
if (document.getElementById) {
    // If there's no getElementById, this whole script won't do anything

    var radio_remote = document.getElementById("talkpostfromremote");
    var radio_user = document.getElementById("talkpostfromlj");
    var radio_anon = document.getElementById("talkpostfromanon");

    var check_login = document.getElementById("logincheck");
    var sel_pickw = document.getElementById("prop_picture_keyword");
    var commenttext = document.getElementById("commenttext");

    var username = document.getElementById("username");
    var password = document.getElementById("password");
    
    var form = document.getElementById("postform");
    var remotef = document.getElementById("cookieuser");
    var remote;
    if (remotef) {
        remote = remotef.value;
    }
}

var apicurl = "";
var picprevt;

if (! sel_pickw) {
    // make a fake sel_pickw to play with later
    sel_pickw = new Object();
}

function handleRadios(sel) {
    password.disabled = check_login.disabled = (sel != 2);
    if (password.disabled) password.value='';
    if (sel_pickw.disabled = (sel != 1)) sel_pickw.value='';
}

function submitHandler() {
    if (remote && username.value == remote && ! radio_anon.checked) {
        //  Quietly arrange for cookieuser auth instead, to avoid
        // sending cleartext password.
        password.value = "";
        username.value = "";
        radio_remote.checked = true;
        return true;
    }
    if (username.value && ! radio_user.checked) {
        alert(usermismatchtext);
        return false;
    }
    return true;
}

if (document.getElementById) {

    if (radio_anon.checked) handleRadios(0);
    if (radio_user.checked) handleRadios(2);

    if (radio_remote) {
        radio_remote.onclick = function () {
            handleRadios(1);
        };
        if (radio_remote.checked) handleRadios(1);
    }
    radio_user.onclick = function () {
        handleRadios(2);
    };
    radio_anon.onclick = function () {
        handleRadios(0);
    };
    username.onkeydown = username.onchange = function () {
        radio_user.checked = true;
        handleRadios(2);  // update the form
    }
    form.onsubmit = submitHandler;

    document.onload = function () {
        if (radio_anon.checked) handleRadios(0);
        if (radio_user.checked) handleRadios(2);
        if (radio_remote && radio_remote.checked) handleRadios(1);
    }

}
