GalleryManageView = new Class(View, {

  init: function (opts) {
    GalleryManageView.superClass.init.apply(this, arguments);

    DOM.addClassName(this.view, "FBGalleryManageView");

    FB.galSelected.addWatcher(this.update.bind(this));
    this.controller.registerActionHandler("galEditSaveFinished", this.saveFinished.bind(this));

    this.pbar = null;
  },

  update: function () {
    if (!this.rendered) return;
    this.updateEnabled();
    this.updateSelectedText();
    this.updateRemoveLinkFrom();
  },

  // if no galleries are selected, disable everything
  updateEnabled: function () {
    var eles = [];
    var inputs = $("GalleryManageMultipleContainer").getElementsByTagName("input") || [];
    var menus = $("GalleryManageMultipleContainer").getElementsByTagName("select") || [];

    for (var i=0; i<inputs.length; i++)
      eles.push(inputs[i]);
    for (var i=0; i<menus.length; i++)
      eles.push(menus[i]);

    for (var i=0; i<eles.length; i++) {
      var inputElement = eles[i];
      if (FB.galSelected.length() > 0) {
        if (inputElement.disabled)
          inputElement.disabled = false;
      } else {
        if (!inputElement.disabled)
          inputElement.disabled = true;
      }
    }

    // you can only merge two and only two galleries
    if ($("GalleryMergeRadio")) {
      if (FB.galSelected.length() == 2)
        $("GalleryMergeRadio").disabled = false;
      else
        $("GalleryMergeRadio").disabled = true;
    }
  },

  // update the "remove link from" menu so it only contains galleries that
  // the currently selected galleries link to
  updateRemoveLinkFrom: function () {
    var i;

    var menu = $("GalleryDelLink");
    if (!menu)
      return; // what the..

    // first, empty the menu
    var menulength = menu.length;
    for (i=0; i<menulength; i++) {
      menu.remove(i);
    }

    menu.length = 0;

    // load selected galleries
    var gals = [];

    for (i=0; i<FB.galSelected.totalLength(); i++)
      gals.push(this.datasource.galById(FB.galSelected.allData()[i]));

    // now, build a list of gallery ids that galleries link to
    var linksTo = [];

    for (i=0; i<gals.length; i++) {
      var gal = gals[i];

      if (!gal || !gal.linksto)
        continue;

      var galLinksTo = gal.linksto;
      for (var j=0; j<galLinksTo.length; j++) {
        if (linksTo.indexOf(galLinksTo[j]) == -1)
          linksTo.push(galLinksTo[j]);
      }
    }

    // strip out all that all the selected galleries do not have in common
    var temp = linksTo.copy();

    for (i=0; i<linksTo.length; i++) {
      for(var j=0; j<gals.length; j++) {
        var gal = gals[j];
        if (gal.linksto.indexOf(linksTo[i]) == -1)
          temp.remove(linksTo[i]);
      }
    }
    linksTo = temp;

    if (!linksTo.length) {
      menu.disabled = true;
      var opt = document.createElement("option");
      opt.text = "(No common galleries to remove)";
      opt.value = -1;

      // i hate you firefox and IE
      Try.these(
                function () { menu.add(opt, 0);    }, // IE
                function () { menu.add(opt, null); }  // Firefox
                );

      $("GalleryDelLinkRadio").disabled = true;

      return;
    }

    for (i=0; i<linksTo.length; i++) {
      var gal = this.datasource.galById(linksTo[i]);
      if (!gal)
        continue;

      var opt = document.createElement("option");
      opt.text = gal.name;
      opt.value = gal.id;

      Try.these(
                function () { menu.add(opt, 0);    }, // IE
                function () { menu.add(opt, null); }  // Firefox
                );
    }

    menu.disabled = false;
  },

  updateSelectedText: function () {
    var seltext = $("GalleryManageSelectedText");
    if (!seltext)
      return;

    var numsel = FB.galSelected.data().length;
    var galplural = numsel == 1 ? "gallery" : "galleries";
    numsel = numsel ? numsel : "No";
    seltext.innerHTML = numsel + " " + galplural + " selected.";
  },

  render: function (data, ds) {
    var gals = data;
    var i;

    var html = "";

    // create new gallery button + blurb
    html += "<div class='FBGalleryManageBlurb'>";
    html += "</div>";

    // edit multiple galleries container
    html += "<div class='FBGalleryManageMultiple' id='GalleryManageMultipleContainer'>";
    html += "<h2>Edit Selected Galleries</h2>";
    html += "<div id='GalleryManageSelectedText'></div>";
    html += "<div class='advanced'>For all selected galleries</div>";

    // change security
    html += "<div class='FBGalleryManageInput'>" +
      "<input type='radio' name='GalleryManageRadios' id='GalleryChangeSecurityRadio' checked />" +
      "<label for='GalleryChangeSecurityRadio'>Change privacy to:</label>" +
      "<div class='FBGalleryManageInputMenu'><select id='GalleryChangeSecurity'>" +
      "<option value='-1'>(Select security)</option>" +
      "<option value='255'>Public</option>" +
      "<option value='0'>Private</option>" +
      "<option value='254'>All groups</option>" +
      "<option value='253'>Registered users</option>";

    if (FB && FB.secGroups) {
      for(i=0; i<FB.secGroups.ids.length; i++) {
        var secid = FB.secGroups.ids[i];
        html += "<option value='" + secid + "'>" + FB.secGroups.groups[secid] + "</option>";
      }
    }

    html += "</select></div></div>";

    html += "<div class='FBGalleryManageInput'><input type='radio' name='GalleryManageRadios' id='GalleryMergeRadio' />" +
      "<label for='GalleryMergeRadio'>Merge galleries</label></div>";

    html += "<div class='FBGalleryManageInput'><input type='radio' name='GalleryManageRadios' id='GalleryDelWithImagesRadio' />" +
      "<label for='GalleryDelWithImagesRadio'>Delete galleries and images</label></div>";

    html += "<div class='FBGalleryManageInput'><input type='radio' name='GalleryManageRadios' id='GalleryDelSaveImagesRadio' />" +
      "<label for='GalleryDelSaveImagesRadio'>Delete galleries and save images</label></div>";

    html += "<div class='advanced'>Advanced Options</div>"

    // add link
    html += "<div class='FBGalleryManageInput'>" +
    "<input type='radio' name='GalleryManageRadios' id='GalleryNewLinkRadio' />" +
    "<label for='GalleryNewLinkRadio'>Add a sub-gallery:</label>" +
    "<div class='FBGalleryManageInputMenu'><select id='GalleryNewLink'>" +
    "<option value='-1'>(Select gallery)</option>";

    var allGals = ds.allData();
    for (i=0; i<allGals.length; i++)
    html += "<option value='" + allGals[i].id + "'>" + allGals[i].name + "</option>\n";

    html += "</select></div></div>";

    // remove link
    html += "<div class='FBGalleryManageInput'>" +
    "<input type='radio' name='GalleryManageRadios' id='GalleryDelLinkRadio' />" +
    "<label for='GalleryDelLinkRadio'>Remove a sub-gallery:</label>" +
    "<div class='FBGalleryManageInputMenu'><select id='GalleryDelLink' disabled='1'>" +
    "<option>(No common galleries to remove)</option>" +
    "</select></div></div>";

    // save button
    html += "<div class='FBGalleryManageInput'><input type='button' value='Save changes' id='GalleryManageSaveBtn' /></div>";

    // status text
    html += "<div id='GalleryManageInfoText'></div>";

    // progress bar
    html += "<div id='GalleryManageProgress'></div>";

    // end container div
    html += "</div>";

    this.view.innerHTML = html;

    // add event listeners
    var radios = this.radios();
    var savebtn = $("GalleryManageSaveBtn");

    if (!savebtn)
      return; // we don't want to even try messing with any other elements if we can't find one

    DOM.addEventListener(savebtn, "click", this.saveBtnClicked.bindEventListener(this));

    for (i=0; i<radios.length; i++) {
      if (radios[i])
        DOM.addEventListener(radios[i], "change", this.editRadiosChanged.bindEventListener(this));
    }

    DOM.addEventListener($("CreateNewGalleryBtn"), "click", this.createBtnClicked.bindEventListener(this));
    DOM.addEventListener($("UploadPicturesBtn"), "click", this.uploadBtnClicked.bindEventListener(this));

    // for the menus, when a user changes a value in it automatically select the corresponding radio button
    var selectMenus = ["GalleryNewLink", "GalleryDelLink", "GalleryChangeSecurity"];
    selectMenus.forEach(function (menuName) {
      DOM.addEventListener($(menuName), "change", function (evt) {
        $(menuName + "Radio").checked = "on";
      });
    });

    if (!this.pbar) {
      this.pbar = new LJProgressBar();
      this.pbar.init($("GalleryManageProgress"));
      this.pbar.setWidth("100%");
      this.pbar.show();
    }

    this.update();
  },

  uploadBtnClicked: function (evt) {
      // just go to the upload page
      window.location.href = "/manage/upload";
  },

  createBtnClicked: function (evt) {
    this.controller.dispatchAction("createGallery");
  },

  saveBtnClicked: function (evt) {
    Event.stop(evt);
    // what radio is selected?
    var radios = this.radios();
    var actionid;

    for (var i=0; i<radios.length; i++) {
      if (radios[i].checked)
        actionid = radios[i].id;
    }

    // get menu selections
    var delLink = $("GalleryDelLink").value;
    var linkTo = $("GalleryNewLink").value;

    this.setInfoText("Saving...");
    $("GalleryManageSaveBtn").disabled = true;

    this.controller.dispatchAction("galEditSave", {
      "actionid": actionid,
      "delLink" : delLink,
      "linkTo"  : linkTo
    });
  },

  saveFinished: function (data) {
    if (data && data.success) {

      // update gallery data
      FB.galSelected.empty();
      this.datasource.update({"callback": this.hideUpdatingStatus.bind(this)});
      this.setInfoText("Save finished.<br/>Updating...");
      if (this.pbar) {
        this.pbar.show();
      }

    } else {
      this.hideUpdatingStatus();
    }
    $("GalleryManageSaveBtn").disabled = false;
  },

  hideUpdatingStatus: function (data) {
    this.setInfoText("");
    if (this.pbar)
      this.pbar.hide();
  },

  setInfoText: function (text) {
    $("GalleryManageInfoText").innerHTML = text;
  },

  editRadiosChanged: function (evt) {
    // radio button clicked
  },

  radios: function () {
    return [
            $("GalleryChangeSecurityRadio"),
            $("GalleryNewLinkRadio"),
            $("GalleryDelLinkRadio"),
            $("GalleryMergeRadio"),
            $("GalleryDelWithImagesRadio"),
            $("GalleryDelSaveImagesRadio")
    ];
  }

});
