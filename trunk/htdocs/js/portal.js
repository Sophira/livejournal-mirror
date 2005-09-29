var LJVAR;
if (!LJVAR) LJVAR=new Object();
var portalAnimating = 0;
var box_reloading = {};

function getXTR () {
  var xtr;
  var ex;

  if (typeof(XMLHttpRequest) != "undefined") {
    xtr = new XMLHttpRequest();
  } else {
    try {
      xtr = new ActiveXObject("Msxml2.XMLHTTP.4.0");
    } catch (ex) {
      try {
        xtr = new ActiveXObject("Msxml2.XMLHTTP");
      } catch (ex) {
      }
    }
  }

  // let me explain this.  Opera 8 does XMLHttpRequest, but not setRequestHeader.
  // no problem, we thought:  we'll test for setRequestHeader and if it's not present
  // then fall back to the old behavior (treat it as not working).  BUT --- IE6 won't
  // let you even test for setRequestHeader without throwing an exception (you need
  // to call .open on the .xtr first or something)
  try {
    if (xtr && ! xtr.setRequestHeader)
      xtr = null;
  } catch (ex) { }

  return xtr;
}

function doXrequest (postdata, finishcallback) {
  var state_callback = function () {
    if (xtr && xtr.readyState == 4) {
      if (xtr.status == 200) {
        var result = xtr.responseText;
        if (result) {
          if (finishcallback)
            finishcallback(result);
          return false;
        }
      } else {
        alert("Error contacting server: " + xtr.statusText);
        return true;
      }
    }
  };

  var xtr = getXTR();
  if (xtr) {
    xtr.open("POST", LJVAR.postUrl, true);

    xtr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
    postdata = "jsmode=1&" + postdata;
    xtr.send(postdata);
    xtr.onreadystatechange = state_callback;
    return false;
  }
  return true;
}

function deletePortalBox (pboxid) {
  return evalXrequest("delbox=1&pboxid=" + pboxid);
}

function addPortalBox (type, col, sortorder) {
  return evalXrequest("addbox=1&boxtype=" + type + "&boxcol=" + col);
}

function resetBox (pboxid) {
  return evalXrequest("resetbox=1&pboxid="+pboxid);
}

function evalXrequest(request) {
  var doEval = function(result) { eval(result); };

  return doXrequest(request, doEval);
}

function showConfigPortalBox (pboxid) {
  var box = xGetElementById("config"+pboxid);

  if (!box) {
    if(!evalXrequest("configbox=1&pboxid="+pboxid)) {
      return false;
    }
  } else {
    animateOpen(box);
    return false;
  }

  return true;
}

function hideConfigPortalBox (pboxid) {
  var box = xGetElementById("config"+pboxid);
  if (box) {
    fadeOut(box);
  }
  return false;
}

function savePortalBoxConfig (pboxid) {
  // check to see if this is an actual form instead of us wanting to do an XML HTTP request
  var formelements = xGetElementById("box_config_elements"+pboxid);
  if (formelements) {
    var elementlist = formelements.value.split(',');
    var postdata = "saveconfig=1&pboxid="+pboxid+"&";
    var valuesfound = false;
    for(var i=0; i<elementlist.length; i++) {
      var element = xGetElementById(elementlist[i]+pboxid);
      var value = "";
      if (element) {
        if (element.type == 'checkbox') {
          value = element.checked ? "1" : "0";
        } else {
          value = escape(element.value);
        }

        // if min and max values defined, check them
        var minvalue = element.getAttribute('min');
        var maxvalue = element.getAttribute('max');
        if (minvalue && maxvalue) {
          element.value = parseInt(element.value);
          if (element.value > parseInt(maxvalue) || element.value < parseInt(minvalue)) {
            alert("You must enter a value between "+minvalue+" and "+maxvalue+".");
            return false; // do not do submit, let the user correct their mistake
          }
        }
        postdata += elementlist[i] + "=" + value + "&";
        valuesfound = true;
      }
    }
    if (valuesfound) {
      //remove trailing "&"
      postdata = postdata.substr(0, postdata.length-1);
      return evalXrequest(postdata);
    }
  }

  return true;
}

function centerBoxX (obj) {
  xLeft(obj, (xClientWidth()/2) - (xWidth(obj))/2);
}

function xRight (obj) {
  if (obj.style.position != "absolute") {
    return xLeft(obj) + xWidth(obj);
  } else {
    return xPageX(obj) + xWidth(obj);
  }
}
function xBottom (obj) {
  if (obj.style.position != "absolute") {
    return xTop(obj) + xHeight(obj);
  } else {
    return xPageY(obj) + xHeight(obj);
  }
}

function openConfigMenu() {
  var configbar = xGetElementById('PortalConfigMenuBar');
  var configbuttonbar = xGetElementById('PortalConfigButtonBar');

  if (!configbar || !configbuttonbar) return true;

  showBox(configbar);
  hideBox(configbuttonbar);

  return false;
}

function hideMe(e) {
  hideBox(e);
}

function closeConfigMenu() {
  var configbar = xGetElementById('PortalConfigMenuBar');
  var configbuttonbar = xGetElementById('PortalConfigButtonBar');
  var content = xGetElementById('PortalContentContainer');
  if (!configbar || !content || !configbuttonbar) return;

  hideBox(configbar);
  // make sure all open menus are closed
  hidePortalMenu();
  showBox(configbuttonbar);
}

function opacity(id, opacStart, opacEnd, millisec, endcallback) {
    //speed for each frame
    var speed = Math.round(millisec / 100);
    var timer = 0;

    //determine the direction for the blending, if start and end are the same nothing happens
    if(opacStart > opacEnd) {
        for(i = opacStart; i >= opacEnd; i--) {
            setTimeout("changeOpac(" + i + ",'" + id + "')",(timer * speed));
            timer++;
        }
    } else if(opacStart < opacEnd) {
        for(i = opacStart; i <= opacEnd; i++)
            {
            setTimeout("changeOpac(" + i + ",'" + id + "')",(timer * speed));
            timer++;
        }
    }
    if(endcallback)
      setTimeout(""+endcallback, millisec);
}

//change the opacity for different browsers
function changeOpac(opacity, id) {
  var e =  xGetElementById(id);
  if (e && xDef(e.style)) {
    var object = e.style;
    if (object) {
      //reduce flicker
      if (opacity == 100 && (navigator.userAgent.indexOf('Gecko') != -1 && navigator.userAgent.indexOf('Safari') == -1)) opacity = 99.99;

      object.opacity = (opacity / 100);
      object.MozOpacity = (opacity / 100);
      object.KhtmlOpacity = (opacity / 100);
      object.filter = "alpha(opacity=" + opacity + ")";
    }
  }
}

function dropDownMenu(e, menu) {
  // hide if the menu is already showing
  var menuelement = getPortalMenu(menu);
  var finish_callback = function (menuhtml) {
    if (menuhtml) {
      doDropDownMenu(e, menuhtml);
    } else {
      alert("Error retrieving menu.");
    }
  };

  return doXrequest("getmenu=1&menu="+menu, finish_callback);
}

function doDropDownMenu(e, menuHTML) {
  var menuBox = xGetElementById('PortalConfigMenu');

  if (!menuBox) {
    menuBox = xCreateElement('div');
  }

  if (xDef(menuBox)) {
    // hide if open
    if (xDisplay(menuBox) == "block") {
      hidePortalMenu();
    } else {
      xAppendChild(document.body, menuBox);
      menuBox.innerHTML = menuHTML;
      menuBox.id = "PortalConfigMenu";
      menuBox.className = "DropDownMenu";
      menuBox.newRight = xRight(menuBox);
      menuBox.newBottom = xBottom(menuBox);

      xLeft(menuBox, xPageX(e));
      xTop(menuBox, xPageY(e) + xHeight(e));
      fadeIn(menuBox, 200);
      menuBox.isOpen = 1;
      var addbutton = xGetElementById("AddPortalMenuButtonImage");
      if (addbutton && LJVAR.imgprefix) {
        addbutton.src = LJVAR.imgprefix + "/portal/PortalAddButtonSelected.gif";
      }
    }
  }
}

function getPortalMenu(menu) {
  return xGetElementById('PortalConfigMenu');
}

function hidePortalMenu(menu) {
  var menuelement = getPortalMenu(menu);

  if (menuelement) {
    menuelement.isOpen = 0;
    hideBox(xGetElementById('PortalConfigMenu'));
    var addbutton = xGetElementById("AddPortalMenuButtonImage");
    if (addbutton && LJVAR.imgprefix) {
      addbutton.src = LJVAR.imgprefix + "/portal/PortalAddButton.gif";
    }
  }
}

function showAddPortalBoxMenu() {
  return dropDownMenu(xGetElementById('AddPortalMenuButton'), 'addbox');
}

function movePortalBoxUp(pboxid) {
  var box = xGetElementById("pbox"+pboxid);

  if (!box) return true;

  var prevbox = xPrevSib(box);
  if (prevbox) {
    swapnodes(prevbox, box);
  }

  return evalXrequest ("movebox=1&pboxid="+pboxid+"&up=1");
}

function movePortalBoxDown(pboxid) {
  var box = xGetElementById("pbox"+pboxid);

  if (!box) return true;

  var nextbox = xNextSib(box);
  if (nextbox) {
    swapnodes(nextbox, box);
  }

  return evalXrequest ("movebox=1&pboxid="+pboxid+"&down=1");
}

function movePortalBoxToCol(pboxid, col, boxcolpos) {
  var box = xGetElementById("pbox"+pboxid);
  var colelement = xGetElementById("PortalCol"+col);
  if (!boxcolpos)
    boxcolpos = "";

  if (colelement && box) {
    xAppendChild(colelement, box);
    return evalXrequest ("movebox=1&pboxid="+pboxid+"&boxcol="+col+"&boxcolpos="+boxcolpos);
  }
  return true;
}

function swapnodes (orig, to_swap) {
  var orig_pn = xParent(orig, true);
  var to_swap_pn = xParent(to_swap, true);
  var orig_next_sibling = xNextSib(orig);
  var to_swap_next_sibling = xNextSib(to_swap);
  if (!to_swap_pn || !orig_pn) {
    return;
  }

  // if next to each other
  if ( orig_next_sibling == to_swap ) {
    orig_pn.insertBefore(to_swap, orig);
    return;
  } else if ( to_swap_next_sibling == orig ) {
    orig_pn.insertBefore(orig, to_swap);
    return;
  }

  to_swap_pn.removeChild(to_swap);
  orig_pn.removeChild(orig);

  if (xDef(orig_next_sibling))
    orig_pn.insertBefore(to_swap, orig_next_sibling);
  else
    orig_pn.appendChild(to_swap);

  if (xDef(to_swap_next_sibling))
    to_swap_pn.insertBefore(orig, to_swap_next_sibling);
  else
    to_swap_pn.appendChild(orig);
}

function swapBoxes(pboxid1, pboxid2) {
  var e1 = xGetElementById("pbox"+pboxid1);
  var e2 = xGetElementById("pbox"+pboxid2);

  if (e1 && e2) {
    swapnodes(e1,e2);
  }
}

function updatePortalBox(pboxid) {
  return evalXrequest("updatebox=1&pboxid="+pboxid);
}

function reloadPortalBox(pboxid) {
  // don't let user double-click portal update
  if (!box_reloading[pboxid]) {
    box_reloading[pboxid] = 1;
    return updatePortalBox(pboxid);
  }

  return false;
}

function regEvent (target, evt, func) {
  if (! target) return;
  if (target.attachEvent)
    target.attachEvent("on"+evt, func);
  if (target.addEventListener)
    target.addEventListener(evt, func, false);
}

function hideBox (e) {
  var target = xGetElementById(e);
  xDisplay(target, 'none');
}
function showBox (e) {
  var target = xGetElementById(e);

  xDisplay(target, 'block');

  if (xDef(target.oldwidth) && target.oldwidth > 0)
    xWidth(target, target.oldwidth);

  if (xDef(target.oldheight) && target.oldheight > 0)
    xHeight(target, target.oldheight);
}

function animateClose(target, speed) {
  fadeOut(target, speed, "1;");
  animateCollapse(target, speed);
}

function animateOpen(target, speed) {
  fadeIn(target, speed);
}

function fadeIn(target, speed) {
  var targetelement = xGetElementById(target);
  if (!speed) speed = 500;
  showBox(targetelement);

  if (LJVAR.doFade)
    opacity(targetelement.id, 0, 100, speed);
}

function fadeOut(target, speed, callback) {
  var targetelement = xGetElementById(target);
  var targetid = targetelement.id;
  if (!speed) speed = 500;
  if (!callback)
    callback = "hideMe('"+targetid+"')";

  if (LJVAR.doFade)
    opacity(targetid, 100, 0, speed, callback);
  else
    eval(callback);
}

function animateCollapse(target, speed, callback) {
  if (portalAnimating)
    return;

  if (!callback)
    callback = function () { hideMe(targetelement); };

  var targetelement = xGetElementById(target);

  if (xHeight(targetelement)>0) {
    if (!speed) speed = 500;

    targetelement.oldheight = xHeight(targetelement);
    targetelement.oldwidth = xWidth(targetelement);

    if (LJVAR.doAnimate) {
      xSlideCornerTo2(targetelement, "se", xRight(targetelement), xTop(targetelement), speed);
      targetelement.onslideend = callback;
    } else {
      callback();
    }
  } else {
    callback();
  }
}

// xSlideCornerTo, Copyright 2005 Michael Foster (Cross-Browser.com)
// Part of X, a Cross-Browser Javascript Library, Distributed under the terms of the GNU LGPL

function xSlideCornerTo2(e, corner, targetX, targetY, totalTime)
{
  if (!(e=xGetElementById(e))) return;
  if (!e.timeout) e.timeout = 25;
  e.xT = targetX;
  e.yT = targetY;
  e.slideTime = totalTime;
  e.corner = corner.toLowerCase();
  e.stop = false;
  switch(e.corner) { // A = distance, D = initial position
  case 'nw': e.xA = e.xT - xLeft(e); e.yA = e.yT - xTop(e); e.xD = xLeft(e); e.yD = xTop(e); break;
  case 'sw': e.xA = e.xT - xLeft(e); e.yA = e.yT - (xTop(e) + xHeight(e)); e.xD = xLeft(e); e.yD = xTop(e) + xHeight(e); break;
  case 'ne': e.xA = e.xT - (xLeft(e) + xWidth(e)); e.yA = e.yT - xTop(e); e.xD = xLeft(e) + xWidth(e); e.yD = xTop(e); break;
  case 'se': e.xA = e.xT - (xLeft(e) + xWidth(e)); e.yA = e.yT - (xTop(e) + xHeight(e)); e.xD = xLeft(e) + xWidth(e); e.yD = xTop(e) + xHeight(e); break;
  default: alert("xSlideCornerTo: Invalid corner"); return;
  }
  if (e.slideLinear) e.B = 1/e.slideTime;
  else e.B = Math.PI / (2 * e.slideTime); // B = period
  var d = new Date();
  e.C = d.getTime();
  if (!e.moving) _xSlideCornerTo2(e);
}

function _xSlideCornerTo2(e)
{
  if (!(e=xGetElementById(e))) return;
  var now, seX, seY;
  now = new Date();
  t = now.getTime() - e.C;
  if (e.stop) { e.moving = false; e.stop = false; return; }
  else if (t < e.slideTime) {
    portalAnimating = 1;
    setTimeout("_xSlideCornerTo2('"+e.id+"')", e.timeout);

    s = e.B * t;
    if (!e.slideLinear) s = Math.sin(s);

    newX = Math.round(e.xA * s + e.xD);
    newY = Math.round(e.yA * s + e.yD);
  }
  else { newX = e.xT; newY = e.yT; }
  seX = xRight(e);
  seY = xBottom(e);
  switch(e.corner) {
  case 'nw': xMoveTo(e, newX, newY); xResizeTo(e, seX - xLeft(e), seY - xTop(e)); break;
  case 'sw': if (e.xT != xLeft(e)) { xLeft(e, newX); xWidth(e, seX - xLeft(e)); } xHeight(e, newY - xTop(e)); break;
  case 'ne': xWidth(e, newX - xLeft(e)); if (e.yT != xTop(e)) { xTop(e, newY); xHeight(e, seY - xTop(e)); } break;
  case 'se': xWidth(e, newX - xLeft(e)); xHeight(e, newY - xTop(e)); break;
  default: e.stop = true;
  }
  e.moving = true;
  if (t >= e.slideTime) {
    e.moving = false;
    if (e.onslideend) e.onslideend();
    e.onslideend=null;
    portalAnimating = 0;
  }
}
