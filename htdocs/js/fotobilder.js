// -*-perl-*-

var FB = {};
FB.footerHeight = function () {
    if (!document.getElementById) return 0;
    var fvar = document.getElementById("varFooterHeight");
    if (!fvar) return 0;
    return fvar.innerHTML * 1;
};


// Toggle all checkboxes for a form.
function checkAll (button, form)
{
    var check;
    if (button.value == "Check All") {
        check = true; button.value = "Uncheck All";
    } else {
        check = false; button.value = "Check All";
    }
    for(i=0;i<form.elements.length;i++) {
        if (form.elements[i].type=='checkbox') {
            if (form.elements[i].checked!=check) { form.elements[i].checked=check; }
        }
    }
}

function setupNewGalHidey(src, target, txtid)
{
    var sel = xbGetElementById(src);
    var span = xbGetElementById(target);
    if (sel && span) {
        sel.onchange = function (evt) {
            var show = sel.selectedIndex == 1;
            if (! document.all) {
                // TODO: make work in IE
                span.style.display = show ? 'block' : 'none';
                if (show) {
                    var txt = xbGetElementById(txtid);
                    if (txt) txt.focus();
                }
            }
            return true;
        };
        if (! document.all) {
            // for initial page load
            sel.onchange();
        }
    }
    return true;
}
