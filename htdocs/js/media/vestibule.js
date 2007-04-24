var iframe = 'content';
var timer;

// direction == u|d|l|r
function scrollstart (dir) {
    if (timer) clearTimeout(timer);
    scrollmove(dir, scrollspeed);
    // repeat smoothly while mouseover
    timer = setTimeout("scrollstart('" + dir + "')", 20);
}

function scrollstop () {
    if (timer) clearTimeout(timer);
}

function scrolljump (dir) {
    var amt = scrollspeed * 15;
    scrollmove(dir, amt);
    scrollstop();
}

function scrollmove (dir, speed) {
    if (window.frames[iframe]) {
        if (dir == "u") window.frames[iframe].scrollBy(0, -speed);
        if (dir == "d") window.frames[iframe].scrollBy(0, speed);
        if (dir == "l") window.frames[iframe].scrollBy(-speed, 0);
        if (dir == "r") window.frames[iframe].scrollBy(speed, 0);
    }
}

// This seems to break the back button.  :|
// Currently disabled in the style.
function setframetext (text) {
    var c = window.frames[iframe].document;
    if (c) {
       c.open();
       c.write(text);
       c.close();
    }
}

function imgswp (obj, newsrc) {
    var imgstr = 'document.' + obj;
    obj = eval(imgstr);
    if (document.images && obj.src) obj.src = newsrc;
}

function sswap(tbl, sname) { tbl.className = sname; }

