PictureThumbView = new Class(ManageThumbView, {

  init: function (opts) {
    opts.cellsPerRow = 3;
    // 3 cells per row
    PictureThumbView.superClass.init.apply(this, [opts]);
    this.cellCount = 0;
    this.lastRow = null;

    this.cells = {}; // picid -> cell mapping

    this.controller.registerActionHandler("picAddSelection", this.picAddSelection.bind(this));
    this.controller.registerActionHandler("picRemoveSelection", this.picRemoveSelection.bind(this));
  },

  picAddSelection: function (picid) {
    var cell = this.cells[picid];
    if (!cell)
      return;

    DOM.addClassName(cell, "FBManageListPictureSelected");
  },

  picRemoveSelection: function (picid) {
    var cell = this.cells[picid];
    if (!cell)
      return;

    DOM.removeClassName(cell, "FBManageListPictureSelected");
  },

  drawCell: function (row, pic) {
    if (!pic)
      return;

    var view = this.view;
    var html = "";
    var cell = this.addCellElement(row);
    if(!pic.title)
      pic.title = "";
    var upDate;

    var imgCell = document.createElement("div");
    var prevImg = document.createElement("img");
    prevImg.src = pic.smallurl;
    prevImg.width = pic.smallw;
    prevImg.height = pic.smallh;
    imgCell.appendChild(prevImg);

    var nameCell = document.createElement("a");
    nameCell.innerHTML = pic.secicontag + pic.title;
    nameCell.href = FB.siteRoot + "/manage/pic?id=" + pic.id;

    cell.underlay.appendChild(imgCell);
    cell.underlay.appendChild(nameCell);

    this.cells[pic.id] = cell;

    if (FB.picsSelected.indexOf(pic.id) != -1)
      DOM.addClassName(cell, "FBManageListPictureSelected");

    // for each element in the table that does not have a HREF attribute, or is an INPUT or TD element,
    // add a click handler to select this row
    var cellElements = cell.getElementsByTagName("*") || [];
    var self = this;
    for (var i=0; i<cellElements.length; i++) {
      var cellElement = cellElements[i];

      var tagName = cellElement.tagName.toLowerCase();

      if (!cellElement || cellElement.href || tagName == "input" || tagName == "td")
        continue;

      DOM.addEventListener(cellElement, "click", function (evt) {
        evt = Event.prep(evt);

        if (evt.target && evt.target.href) return true;

        Event.stop(evt);

        self.controller.dispatchAction("picToggleSelection", pic.id);
      });
    }
  }

});
