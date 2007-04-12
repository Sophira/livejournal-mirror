GalleryListView = new Class(ManageListView, {

  init: function (opts) {
    GalleryListView.superClass.init.apply(this, arguments);

    this.rows = {}; // gallid -> row mapping

    opts.controller.registerActionHandler("galAddSelection", this.galAddSelection.bind(this));
    opts.controller.registerActionHandler("galRemoveSelection", this.galRemoveSelection.bind(this));
  },

  addHeaders: function (row) {
    var i = 1;
    this.addHeader(row, "");
    this.addHeader(row, "Name", "name", "string");
    this.addHeader(row, "Updated", "timeupdate", "numeric");
    this.addHeader(row, "Pictures", "piccount", "numeric");
    this.addHeader(row, "Untagged", "untaggedcount", "numeric");
    this.addHeader(row, "Privacy", "secgroupname", "string");
  },

  render: function (data) {
    GalleryListView.superClass.render.apply(this, arguments);
  },

  galAddSelection: function (galid) {
    var row = this.rows[galid];

    if (!row)
      return;

    if (!row.checkbox.checked)
      row.checkbox.checked = true;

    DOM.addClassName(row, "FBManageListGallerySelected");
  },

  galRemoveSelection: function (galid) {
    var row = this.rows[galid]
    if (!row)
      return;

    if (row.checkbox.checked)
      row.checkbox.checked = false;

    DOM.removeClassName(row, "FBManageListGallerySelected");
  },

  drawRow: function (table, gallery) {
    var view = this.view;

    var row = document.createElement("tr");
    DOM.addClassName(row, "FBManageListTableRow");
    this.rows[gallery.id] = row;

    if (FB.galSelected.indexOf(gallery.id) == -1)
      DOM.addClassName(row, "FBManageListGallerySelected");

    table.appendChild(row);

    row.galleryid = gallery.id;

    // add checkbox cell
    var checkbox = document.createElement("input");
    var checkboxcell = document.createElement("td");
    DOM.addClassName(checkboxcell, "FBManageListTableCell");

    checkbox.type = "checkbox";
    DOM.addClassName(checkbox, "GalleryCheckbox");
    checkbox.id = "GalleryCheckbox" + gallery.id;
    checkbox.galleryid = gallery.id;

    checkboxcell.appendChild(checkbox);
    row.appendChild(checkboxcell);
    row.checkbox = checkbox;

    // add thumbnail cell
    var thumbcell = "";

    if (gallery.tinypicurl) {
      var thumbimg = document.createElement("img");
      thumbimg.src = gallery.tinypicurl;
      thumbimg.id = "GalleryThumbnail" + gallery.id;
      thumbimg.width = gallery.tinypicw;
      thumbimg.height = gallery.tinypich;
      DOM.addClassName(thumbimg, "GalleryThumbnail");
      this.addCellElement(row, thumbimg);
    } else {
      thumbcell += "";
      this.addCell(row, thumbcell);
    }

    // add name cell
    var namecell = document.createElement("a");
    namecell.innerHTML = gallery.name;
    namecell.href = FB.siteRoot + "/manage/gal?id=" + gallery.id;
    this.addCellElement(row, namecell);

    // add updated cell
    var updatedDate, updatedCell;

    if (gallery.timeupdate)
      updatedDate = new Date(gallery.timeupdate*1000);

    if (updatedDate)
      updatedCell = updatedDate.toISODateString();
    else
      updatedCell = "";

    this.addCell(row, updatedCell);

    // add pic count cell
    var picscell = gallery.pics ? gallery.pics.length : 0;
    this.addCell(row, picscell);

    // add untagged count cell
    var untaggedcell;

    if (gallery.untaggedcount)
      untaggedcell = "<a href='" + gallery.annotateurl + "'>" + gallery.untaggedcount + "</a>";
    else
      untaggedcell = "0";

    this.addCell(row, untaggedcell);

    // add security cell
    var securitycell = gallery.secicontag + gallery.secgroupname;
    this.addCell(row, securitycell);

    // for each element in the row that does not have a HREF attribute, or is an INPUT or TD element,
    // add a click handler to select this row
    var rowElements = row.getElementsByTagName("*") || [];
    for (var i=0; i<rowElements.length; i++) {
      var rowElement = rowElements[i];
      if (!rowElement)
          continue;

      var tagName = rowElement.tagName.toLowerCase();

      if ((rowElement.href && tagName != "img") || tagName == "input" || tagName == "td")
        continue;

      rowElement.galleryid = gallery.id;

      var self = this;
      DOM.addEventListener(rowElement, "click", function (evt) {
        evt = Event.prep(evt);

        // IE thinks images have HREFs
        if (evt.target && evt.target.tagName.toLowerCase() != "img")
            if (evt.target.href) return true;

        var galid = checkbox.galleryid;

        if (!galid)
            return true;

        Event.stop(evt);
        self.controller.dispatchAction("galToggleSelection", galid);
      });
    }
  }

});
