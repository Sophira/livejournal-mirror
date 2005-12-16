var slidingTo;
var slideStatus = 0;  // 0 to 1
var slideStep = 0.1;
var slideDelay = 0;
var tagCloudRefresh;

// Let them override refresh time
if (!defined(tagCloudRefresh)) {
    tagCloudRefresh = 10000; // 10 seconds
}

setInterval(dataRefresh, tagCloudRefresh);

function drawWithData (data) {
    slidingTo = data;
    slideStatus = 0;
    setTimeout(slideAnimate, slideDelay);
}

function slideAnimate () {
    slideStatus += slideStep;
    if (slideStatus > 1) slideStatus = 1;

    for (var i=0; i<ids.length; i++) {
        var id = ids[i];
        var ele = $("taglink_" + id);
        var newpt = Math.floor(curData[id] * (1 - slideStatus) +
                               slidingTo[id] * (slideStatus));
        ele.style.fontSize = newpt + "pt";
    }

    if (slideStatus < 1) {
        setTimeout(slideAnimate, slideDelay);
    } else {
        curData = slidingTo;
    }
}

function dataRefresh () {
    HTTPReq.getJSON({
      url: "tagcloud.bml?js=1",
      onData: function (data) { drawWithData(data); },
      onError: function (msg) { alert("error: " + msg); }
    });
}

var ids = [];
var curData = {};
var initData = {};

onload = function () {
    var tc = $("tagcloud");

    HTTPReq.getJSON({
      url: "tagcloud.bml?js=1",
      onData: function (data) { initData = curData = data; },
      onError: function (msg) { alert("error on initial data: " + msg); }
    });

    var setupLink = function (node) {
       if (!node.id) return;

       var id;
       var m;

       if (m = node.id.match(/^taglink_(\w+)$/)) {
           id = m[1]; // id == tagname
       }

       ids.push(id);

    };

    var cn = tc.childNodes;
    for (var i=0; i<cn.length; i++) {
       var ce = cn[i];
       setupLink(ce);
    }
};
