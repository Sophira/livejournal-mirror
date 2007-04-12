GalleryManageController = new Class(Controller, {

  init: function (galdatasource) {
    GalleryManageController.superClass.init.apply(this, arguments);
    this.galDataSource = galdatasource;
    this.galViews = [];
    this.checkedBoxes = {};

    this.registerActionHandlers({
      "galEditSave": this.galEditSave.bind(this),
        "galAddSelection": this.galAddSelection.bind(this),
        "galRemoveSelection": this.galRemoveSelection.bind(this),
        "galToggleSelection": this.galToggleSelection.bind(this),
        "createGallery": this.createGallery.bind(this)
        });
  },

  addGalView: function (galView) {
    this.galViews.add(galView);

    galView.addWatcher(this.updateViews.bind(this));
  },

  removeGalView: function (galView) {
    this.galViews.remove(galView);
  },

  updateViews: function () {
    for (var i=0; i<this.galViews.length; i++) {
      var view = this.galViews[i];
      if (!view)
        continue;

      // set up handlers for this view
      // gallery checkboxes
      var checkboxes = this.getCheckboxes(view.getView());
      for (var i=0; i<checkboxes.length; i++)
        DOM.addEventListener(checkboxes[i], "click", this.boxClicked.bindEventListener(this));

      // checkall checkbox
      var checkall = DOM.getElementsByClassName(view.getView(), "GalleryCheckAllBox")[0];
      if (checkall)
        DOM.addEventListener(checkall, "click", this.checkallClicked.bindEventListener(this));

      // empty selection
      this.uncheckAll(view.view);
    }
  },

  checkAll: function (view) {
    if (!view)
      return;

    var checkboxes = this.getCheckboxes(view);
    for (var i=0; i<checkboxes.length; i++) {
      checkboxes[i].checked = "on";

      if (FB.galSelected.indexOf(checkboxes[i].galleryid) == -1)
        this.dispatchAction("galAddSelection", checkboxes[i].galleryid);
    }
  },

  uncheckAll: function (view) {
    if (!view)
      return;

    var checkboxes = this.getCheckboxes(view);
    for (var i=0; i<checkboxes.length; i++) {
      checkboxes[i].checked = "";
      this.dispatchAction("galRemoveSelection", checkboxes[i].galleryid);
    }
  },

  getCheckboxes: function (view) {
    if (!view)
      return;

    var viewobjects = view.getElementsByTagName("*");
    return DOM.filterElementsByClassName(viewobjects, "GalleryCheckbox") || [];
  },

  checkallClicked: function (evt) {
    var target = evt.target;
    if (!target)
      return;

    var parentView = DOM.getFirstAncestorByClassName(evt.target, ("FBGalleryView"));
    if (target.checked)
      this.checkAll(parentView);
    else
      this.uncheckAll(parentView);
  },

  boxClicked: function (evt) {
    var target = evt.target;
    if (!target)
      return;

    var galid = target.galleryid;
    if (!galid)
      return;

    // target is not always the checkbox
    var box = $("GalleryCheckbox" + galid);
    if (!box)
      return;

    this.dispatchAction("galToggleSelection", galid);
  },

  galToggleSelection: function (galid) {
    var selected = FB.galSelected.indexOf(galid);
    if (selected < 0) {
      this.dispatchAction("galAddSelection", galid);
    } else {
      this.dispatchAction("galRemoveSelection", galid);
    }
  },

  galAddSelection: function (galid) {
    FB.galSelected.push(galid);
  },

  galRemoveSelection: function (galid) {
    FB.galSelected.remove(galid);
  },

  // save gallery edits
  galEditSave: function (info) {
    if (!FB.galSelected || FB.galSelected.length() < 1) {
      alert("You do not have any galleries selected.");
      this.saveDone();
      return;
    }

    switch(info.actionid) {
    case "GalleryChangeSecurityRadio":
      var newsec = $("GalleryChangeSecurity").value;
      if (newsec < 0) {
        alert("You have not selected a new security level.");
        this.saveDone();
        break;
      }
      this.saveEdit("secid", newsec);
      break;

    case "GalleryNewLinkRadio":
      var linkTo = info.linkTo;
      if (linkTo == undefined || linkTo == -1) {
        alert("You must choose a gallery to link to.");
        this.saveDone();
        break;
      }

      this.saveEdit("addlink", linkTo);
      break;

    case "GalleryDelLinkRadio":
      var delLink = info.delLink;
      if (delLink == undefined || delLink == -1) {
        alert("You must choose a gallery link to remove.");
        this.saveDone();
        break;
      }

      this.saveEdit("dellink", delLink);
      break;

    case "GalleryDelWithImagesRadio":
      var demonstrative = FB.galSelected.length() > 1 ? "these galleries" : "this gallery";
      if (confirm("Are you really sure you want to delete " + demonstrative + " and all the images in " +
                  demonstrative + "?\nThis cannot be undone."))
        this.saveEdit("delgal", "delete");
      else
        this.saveDone();
      break;

    case "GalleryDelSaveImagesRadio":
      this.saveEdit("delgal", "save");
      break;

    case "GalleryMergeRadio":
      var err = "";

      if (FB.galSelected.length() < 2)
        err = "You must have more than one gallery selected to merge.";
      else if (FB.galSelected.length() > 2)
        err = "You can only merge two galleries at a time.";

      if (err)
        alert(err);
      else if (confirm("Are you really sure you want to combine all of the selected galleries into one gallery?\nThis cannot be undone."))
        this.saveEdit("merge");

      this.saveDone();

      break;

    default:
      alert("Unknown Action");
      break;
    }
  },

  // http request stuff
  handleError: function (err) {
    alert("Error: " + err);
  },

  saveDone: function (data) {
    if (data && data.alert)
      alert(data.alert);

    this.dispatchAction("galEditSaveFinished", data);

    // make sure the diskfree widget is up to date
    if (FB.diskFreeWidget)
      FB.diskFreeWidget.update();
  },

  saveEdit: function (key, val) {
    var reqOpts = {};
    reqOpts.onError = this.handleError.bind(this);
    reqOpts.url = "/tools/endpoints/edit";
    reqOpts.onData = this.saveDone.bind(this);
    reqOpts.method = "POST";
    reqOpts.data = HTTPReq.formEncoded({"galids": FB.galSelected.data(), "key": key, "value":val});
    HTTPReq.getJSON(reqOpts);
  },

  // help a user create a new gallery
  createGallery: function () {
    GalCreate.setGalleryCreatedCallback(this.galCreated.bind(this));
    GalCreate.showNewGalleryPopup();
  },

  // new gallery was created, refresh everything
  galCreated: function (galname, galid) {
    this.galDataSource.update();
  }

});
