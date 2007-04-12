GalleryThumbView = new Class(ManageThumbView, {

  init: function (opts) {
    opts.cellsPerRow = 3;
    GalleryThumbView.superClass.init.apply(this, [opts]);
    this.cellCount = 0;
    this.lastRow = null;

    this.cells = {}; // gallid -> cell mapping

    opts.controller.registerActionHandler("galAddSelection", this.galAddSelection.bind(this));
    opts.controller.registerActionHandler("galRemoveSelection", this.galRemoveSelection.bind(this));
  },

  galAddSelection: function (galid) {
    var cell = this.cells[galid];
    if (!cell)
      return;

    DOM.addClassName(cell, "FBManageListGallerySelected");
  },

  galRemoveSelection: function (galid) {
    var cell = this.cells[galid];
    if (!cell)
      return;

    DOM.removeClassName(cell, "FBManageListGallerySelected");
  },

  drawCell: function (row, gallery) {
    if (!gallery)
      return;

    var view = this.view;
    var html = "";
    var cell = this.addCellElement(row);
    var upDate;

    if (gallery.timeupdate)
      upDate = new Date(gallery.timeupdate*1000).toISOTimeString();

    var picPlural = gallery.pics.length == 1 ? "picture" : "pictures";

    var imgCell = document.createElement("div");

    if (gallery.previewpicurl) {
      var prevImg = document.createElement("img");
      prevImg.src = gallery.previewpicurl;
      prevImg.width = gallery.previewpicw;
      prevImg.height = gallery.previewpich;

      imgCell.appendChild(prevImg);
    } else {
      imgCell.innerHTML = "(No preview)";
    }

    var nameCell = document.createElement("a");
    nameCell.innerHTML = gallery.secicontag + gallery.name;
    nameCell.href = FB.siteRoot + "/manage/gal?id=" + gallery.id;

    var countCell = document.createElement("div");
    countCell.innerHTML = gallery.pics.length + " " + picPlural;

    if (upDate)
      countCell.innerHTML += "<div>updated " + upDate + "</div>";

    cell.underlay.appendChild(imgCell);
    cell.underlay.appendChild(nameCell);
    cell.underlay.appendChild(countCell);

    this.cells[gallery.id] = cell;

    if (FB.galSelected.indexOf(gallery.id) != -1)
      DOM.addClassName(cell, "FBManageListGallerySelected");

    // for each element in the table that does not have a HREF attribute, or is an INPUT or TD element,
    // add a click handler to select this row
    var cellElements = cell.getElementsByTagName("*") || [];
    var self = this;
    for (var i=0; i<cellElements.length; i++) {
      var cellElement = cellElements[i];

      var tagName = cellElement.tagName.toLowerCase();

      if ((cellElement.href && tagName != "img") || tagName == "input" || tagName == "td")
        continue;

      DOM.addEventListener(cellElement, "click", function (evt) {
        evt = Event.prep(evt);

        // IE thinks images have HREFs
        if (evt.target && evt.target.tagName.toLowerCase() != "img")
            if (evt.target.href) return true;

        Event.stop(evt);
        self.controller.dispatchAction("galToggleSelection", gallery.id);
      });
    }
  }

});
