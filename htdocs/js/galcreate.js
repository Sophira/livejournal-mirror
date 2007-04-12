/* galcreate.js
   By Mischa Spiegelmock, Nov. 2005

   This library does all the work of letting a user create a new gallery through
   a nifty popup window.

//////////
   Usage:
   GalCreate.setGalleryCreatedCallback(gal_created);
   GalCreate.showNewGalleryPopup();

   function gal_created(galname, galid) {
       //do stuff
   }
//////////
*/

var GalCreate = {};

GalCreate.popup = null;
GalCreate.eventTags = ['party', 'concert', 'vacation'];
GalCreate.personTags = ['friend', 'family', 'coworker'];
GalCreate.created_callback = null;
GalCreate.cancelled_callback = null;
GalCreate.lastGalType = null;
GalCreate.hourglass = null;

GalCreate.createGal = function () {
    var galField = $("create_gal_name");
    if (!galField || !galField.value) return;

    var reqOpts = {};
    reqOpts.url = "/tools/endpoints/creategal.bml";
    reqOpts.onError = GalCreate.errorCallback;
    reqOpts.onData = GalCreate.galCreated;
    reqOpts.method = "POST";

    var gal_info = {};
    gal_info["gal_tags"] = $('gal_tags').value;
    gal_info["gal_date"] = $('gal_date').value;
    gal_info["gal_name"] = galField.value;
    reqOpts.data = HTTPReq.formEncoded(gal_info);

    if (!GalCreate.hourglass)
      GalCreate.hourglass = new Hourglass($("createGalButton"));

    $("createGalButton").disabled = true;

    HTTPReq.getJSON(reqOpts);
    return false;
};

GalCreate.stopSpinning = function () {
    if (GalCreate.hourglass) {
        GalCreate.hourglass.hide();
        GalCreate.hourglass = null;
    }
};

GalCreate.errorCallback = function (res) {
  GalCreate.stopSpinning();
  alert("Error: " + res);
};

GalCreate.galCreated = function (res) {
  GalCreate.stopSpinning();
  $("createGalButton").disabled = false;

  if (res.alert) {
    alert(res.alert);
    return;
  }

  if (!res.gal_created) {
    alert("Could not create gallery.");
    return;
  }

  if (GalCreate.created_callback)
    GalCreate.created_callback(res.gal_name, res.gal_id);

  // Could allow caller to do this explicitly... but I can't possibly
  // imagine when you would not want to close this dialog after your
  // gallery has been created.
  GalCreate.popup.hide();
};

GalCreate.setCancelledCallback = function(callback) {
  GalCreate.cancelled_callback = callback;
  if (GalCreate.popup)
    GalCreate.popup.setCancelledCallback(GalCreate.cancelled_callback);
};

GalCreate.setGalleryCreatedCallback = function (callback) {
  GalCreate.created_callback = callback;
};

GalCreate.gal_type_changed = function (evt) {
  var gal_type;

  if ($("gal_type_event").checked) {
    $("GalNameLabel").innerHTML = 'Event Name: ';
    gal_type = 'event';
  }
  if ($("gal_type_person").checked) {
    $("GalNameLabel").innerHTML = 'Person Name: ';
    gal_type = 'person';
  }
  if ($("gal_type_other").checked) {
    $("GalNameLabel").innerHTML = 'Gallery Name: ';
    gal_type = 'other';
  }

  var galTagFields = DOM.getElementsByClassName( $("galTagFields"), 'galTagField' );
  for (var i=0; i < galTagFields.length; i++) {
    DOM.addClassName(galTagFields[i], 'hiddenLabel');
    DOM.removeClassName(galTagFields[i], 'shownLabel');
  }

  DOM.removeClassName($("galDateField"), 'hiddenLabel');

  var taglist = null;

  if (gal_type == 'event') {
    DOM.addClassName($("EventTags"), 'shownLabel');
    taglist = GalCreate.eventTags;
  } else if (gal_type == 'person') {
    DOM.addClassName($("PersonTags"), 'shownLabel');
    DOM.addClassName($("galDateField"), 'hiddenLabel');
    taglist = GalCreate.personTags;
  }

  if (taglist)
    $("tagreco").innerHTML = GalCreate.generateTagCheckboxes(taglist);
  else
    $("tagreco").innerHTML = "";

  GalCreate.updateNewGalTagsList();
  setTimeout(function () { $("create_gal_name").focus() }, 100);
  return true;
};

GalCreate.updateNewGalTagsList = function() {
  var tags = $("gal_tags").value.split(",");
  var cur_gal;

  // trim whitespace
  for (var i=0; i < tags.length; i++) {
    tags[i] = tags[i].replace(/^\s*/, '');
    tags[i] = tags[i].replace(/\s*$/, '');
  }

  var defaultTags = null;

  if ($("gal_type_event").checked) {
    defaultTags = GalCreate.eventTags;
    cur_gal = "event";
  } else if ($("gal_type_person").checked) {
    defaultTags = GalCreate.personTags;
    cur_gal = "person";
  } else if ($("gal_type_other").checked) {
    cur_gal = "other";
  }

  if (!defaultTags) return;

  for (var i = 0; i < defaultTags.length; i++) {
    var tag = defaultTags[i];
    if (tags.indexOf(tag) == -1 && $(tag + "_tag") && $(tag + "_tag").checked) {
      tags.push(tag);
    } else if (tags.indexOf(tag) != -1 && $(tag + "_tag").checked != true) {
      tags.remove(tag);
    }
  }

  if (GalCreate.lastGalType != cur_gal) {
    var tagsToRemove = null;
    if (GalCreate.lastGalType == "person")
      tagsToRemove = GalCreate.personTags;
    else if (GalCreate.lastGalType == "event")
      tagsToRemove = GalCreate.eventTags;

    if (tagsToRemove) {
      for (var i = 0; i < tagsToRemove.length; i++) {
        var tag = tagsToRemove[i];

        if (tags.indexOf(tag) != -1)
          tags.remove(tag);
      }
    }
  }

  // remove empty tags
  for (var i=0; i<tags.length; i++) {
    if (tags[i].match(/^\s*$/))
      tags.remove(tags[i]);
  }

  GalCreate.lastGalType = cur_gal;
  $("gal_tags").value = tags.join(', ');
};

GalCreate.generateTagCheckboxes = function (tagList) {
  var tagsText = "";

  for (var i=0; i<tagList.length; i++) {
    var tagname = tagList[i];
    tagsText += "<input type='checkbox' name='" + tagname + "' id='" + tagname + "_tag' onchange='GalCreate.updateNewGalTagsList();' /><label for='" + tagname +"_tag'>" + tagname + "</label>\n";
  }

  return tagsText;
};

GalCreate.showNewGalleryPopup = function () {
  if (GalCreate.popup && GalCreate.popup.visible()) return;
  GalCreate.popup = new LJ_IPPU("Create Gallery");
  if (!GalCreate.popup) return true;

    var popupContent = "<form onsubmit='return GalCreate.createGal();'>\
<table border='0' class='galCreateFields'><tr><td align='right'><nobr>Gallery Type:</nobr></td><td nowrap='1'><input id='gal_type_event' name='gal_type' type='radio' onclick='return GalCreate.gal_type_changed();' value='event'><label for='gal_type_event'>Event</label>\
                  <input id='gal_type_person' name='gal_type' type='radio' onclick='return GalCreate.gal_type_changed();' value='person'><label for='gal_type_person'>Person</label>\
                  <input id='gal_type_other' name='gal_type' type='radio' onclick='return GalCreate.gal_type_changed();' checked='checked' value='other'><label for='gal_type_other'>Other</label></td></tr>\
    <tr> <td align='right' nowrap='1'>\
       <span id='GalNameLabel'>Gallery Name: </span>\
    </td><td>\
      <input name='gal_name' type='text' id='create_gal_name'>\
    </td></tr>\
    <tr valign='top'><td align='right'>\
      Tags:\
    </td><td width='100%'>\
        <input type='text' name='tags' id='gal_tags'/><div class='note'>Gallery-level tags. (\"What is this gallery?\")</div><div id='tagreco'></div>\
    </td></tr>\
\
    <tr id='galDateField'><td align='right' valign='top'>\
       Date:\
    </td><td width='100%'>\
        <input type='text' name='gal_date' id='gal_date'/><br/>\
        <div class='note'>Acceptable formats: 2000, 2000-12, 2000-12-31</div>\
    </td></tr>\
    <tr><td colspan='2' align='right'>\
      <input type='submit' id='createGalButton' value='Create' />\
    </td></tr>\
  </table>\
    </form>";

    var titlebarContent = "\
      <div style='width:100%; text-align:left; padding: 4px; border: 0px solid yellow;'><div style='float:right; padding-right: 8px'><img src='/img/CloseButton.gif' width='15' height='15' onclick='GalCreate.popup.cancel();' /></div>Create New Gallery</div>";

    GalCreate.popup.setContent(popupContent);
    GalCreate.popup.setCancelledCallback(GalCreate.cancelled_callback);
    GalCreate.popup.show();

  if ($("create_gal_name"))
  setTimeout(function () { $("create_gal_name").focus() }, 200);
};
