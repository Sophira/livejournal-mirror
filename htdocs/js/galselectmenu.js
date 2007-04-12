GallerySelectMenu = new Class(Object, {
  init: function (menu) {
    GallerySelectMenu.superClass.init.apply(this, arguments);
    if (!menu)
      return;

    this.menu = menu;

    DOM.addEventListener(menu, "change", this.gal_changed.bind(this));
  },

  gal_changed: function (evt) {
    switch (this.menu.value) {
    case "new":
      GalCreate.setCancelledCallback(this.gal_action_cancelled.bind(this));
      GalCreate.setGalleryCreatedCallback(this.gal_created.bind(this));
      GalCreate.showNewGalleryPopup();
      break;
    case "sel":
      var selgal = new GallerySelect();
      selgal.init();
      selgal.setCancelledCallback(this.gal_action_cancelled.bind(this));
      selgal.setGallerySelectedCallback(this.gal_selected.bind(this));
      selgal.show();
      break;
    default:
      break;
    }
  },

  gal_action_cancelled: function () {
    if (!this.menu)
      return;

    this.menu.selectedIndex = 0;
  },

  gal_created: function (galname, galid) {
    // add to list and select
    if (!this.menu)
      return;

    // create new option
    var galopt = document.createElement("option");
    galopt.selected = true;
    galopt.text = galname;
    galopt.value = galid;
    this.menu.add(galopt, null);
  },

  gal_selected: function (galid, galname) {
    if (!galid || !galname)
      return;

    if (!this.menu)
      return;

    var addItem = 1;

    for (var i=0; i<this.menu.options.length; i++) {
      var option = this.menu.options[i];
      if (option.value == galid) {
        this.menu.selectedIndex = i;
        addItem = 0;
      }
    }

    if (!addItem)
      return;

    // add selected item to the dropdown
    var galopt = document.createElement("option");
    galopt.selected = true;
    galopt.text = galname;
    galopt.value = galid;
    this.menu.add(galopt, null);
  }
});
