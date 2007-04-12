/*
  Dialog box to select a gallery
*/

GallerySelect = new Class( Object, {
  init: function () {
    this.galleriesLoaded = false;
    this.galleries = [];
    this.sortMethod = "name";

    var popup = new LJ_IPPU("Select Gallery");
    popup.setContent(this.generateContent());
    popup.setHiddenCallback(this.hide.bind(this));
    popup.setDimensions("50%", 400);
    this.popup = popup;

    this.gallerySelectedCallback = null;
    this.selectedGallery = null;
    this.selectedRow = null;
    this.galRowIds = [];
  },

  show: function () {
    if (this.popup)
      this.popup.show();
    else
      return;

    this.loadGalleries();

    var clickHandler = this.selectGallery.bind(this);
    DOM.addEventListener($("galselect_selectbutton"), "click", clickHandler, true);

    var searchHandler = this.buildGalTable.bind(this);
    DOM.addEventListener($("galselect_search"), "keyup", searchHandler, false);
    DOM.addEventListener($("galselect_search"), "keydown", searchHandler, false);

    this.updateControls();
  },

  updateControls: function () {
    var btn = $("galselect_selectbutton");
    if (!btn)
      return;

    if (this.selectedGallery)
      btn.disabled = false;
    else
      btn.disabled = true;
  },

  selectGallery: function (evt) {
    if (this.gallerySelectedCallback)
      this.gallerySelectedCallback(this.getSelectedGallery(), this.getSelectedGalleryName());
    this.popup.hide();
  },

  hide: function () {
    var clickHandler = this.selectGallery.bind(this);
    DOM.removeEventListener($("galselect_selectbutton"), "click", clickHandler, true);

    var searchHandler = this.buildGalTable.bind(this);
    DOM.removeEventListener($("galselect_search"), "keyup", searchHandler, false);
    DOM.removeEventListener($("galselect_search"), "keydown", searchHandler, false);

    if (this.hourglass)
      this.hourglass.hide();
  },

  getSelectedGallery: function () {
    return this.selectedGallery;
  },

  getSelectedGalleryName: function () {
    return this.selectedGalleryName;
  },

  generateContent: function () {
    return "\
      <div class='galselect_filters'>\
       <span class='galselect_searchbox'>Search: <input type='text' id='galselect_search'></span>\
      </div><div class='galselect_gals' id='galselect_gals'>\
       loading...\
      </div>\
      <div class='galselect_closebuttonarea'>\
       <input type='button' id='galselect_selectbutton' value='Select' />\
      </div>\
    ";
  },

  setField: function (content) {
    $("galselect_gals").innerHTML = content;
  },

  handleError: function (err) {
    this.setField("<div class='FBError'>Error: " + err + "</div>");
    this.galleriesLoaded = false; // ?
    if (this.hourglass)
      this.hourglass.hide();
  },

  listReceived: function (list) {
    list = this.filterGalList(list);
    this.setField(list);
    this.galleriesLoaded = true;

    // copy from list has into galleries array, so we can sort it
    for (var i=0; i<list.length; i++)
      this.galleries.push(list[i]);

    this.galleriesSorted();
    this.buildGalTable();
    if (this.hourglass)
      this.hourglass.hide();

    var galNames = [];
    for (var i=0; i<list.length; i++)
      galNames.push(list[i].name);

    var compdata = new InputCompleteData(galNames);
    var whut = new InputComplete($("galselect_search"), compdata);
  },

  filterGalList: function (list) {
    var newlist = [];

    for (var i=0; i<list.length; i++) {
      var gal = list[i];
      if (!gal.tag && !gal.is_unsorted)
        newlist.push(list[i]);
    }
    return newlist;
  },

  // build a table of galleries
  buildGalTable: function () {
    this.galleriesSorted();
    var gals = this.galleries;
    if (!gals || !gals.length) return;

    // filter by search box
    gals = this.filterBySearchBox(gals);

    var table = "<div class='FBGalleryTable ippu'>\
                 <div class='FBGalleryTableRow'>\
                 <div class='FBGalleryTableHeader' id='FBGallerySelectNameColHeader' >\
                 Gallery Name\
                 </div>\
                 <div class='FBGalleryTableHeader' id='FBGallerySelectDateColHeader' >\
                 Date\
                 </div>\
                 </div>";

    var numberOfCells = 0;
    var numberOfRows = 0;
    var galIds = [], galNames = [];

    this.galRowIds = [];
    this.selectedGallery = null;
    this.selectedGalleryName = null;
    this.selectedRow = null;

    // build gallery table
    for (var i=0; i<gals.length; i++) {
      var gal = gals[i];
      var galname = gal.name;

      // save galId and name for later
      galIds.push(gal.id);
      galNames.push(galname);

      var galDate = "";

      if (gal.date)
        galDate = gal.date;

      // get a unique identifier for these cells
      var cell1id = 'FBGallerySelectCell' + numberOfCells++;
      var cell2id = 'FBGallerySelectCell' + numberOfCells++;
      var rowid = 'FBGallerySelectRow' + numberOfRows++;

      table += "<div class='FBGalleryTableRow' id='" + rowid + "' >\
                <div class='FBGalleryTableCell' id='" + cell1id + "' >" +
        galname +
                "</div><div class='FBGalleryTableCell' id='" + cell2id + "' >" +
        galDate + "</div></div>";

      this.galRowIds.push(rowid);
    }

    table += "</div>";

    this.setField(table);
    this.updateCols();

    // bind mouse clicks to column sortby headers
    var sortNameFunc = this.setNameSort.bind(this);
    var sortDateFunc = this.setDateSort.bind(this);
    DOM.addEventListener($("FBGallerySelectNameColHeader"), "click", sortNameFunc, true);
    DOM.addEventListener($("FBGallerySelectDateColHeader"), "click", sortDateFunc, true);

    // bind mouse clicks to cells and put data in cells
    for (var i=0; i<numberOfCells; i++) {
      var cell = $("FBGallerySelectCell"+i);

      if (!cell)
        continue;

      DOM.addEventListener(cell, "click", this.cellClickHandler.bindEventListener(this));

      cell.cellnum = i;
      cell.rownum = i % 2 == 0 ? i/2 : (i - 1)/2;
      cell.galid = galIds[cell.rownum];
      cell.galname = galNames[cell.rownum];
    }

    // if there's only one result, select it
    if (gals.length == 1) {
      var gal = gals[0];
      if (gal) {
        this.selectedGallery = gal.id;
        this.selectedGalleryName = gal.name;
        this.selectedRow = $("FBGallerySelectRow0");
        this.updateRows();
      }
    }

    this.updateControls();
  },

  filterBySearchBox: function (gals) {
    var newList = [];
    var searchtext = $("galselect_search").value;
    for (var i=0; i<gals.length; i++) {
      if (gals[i].name.toLocaleUpperCase().indexOf(searchtext.toLocaleUpperCase()) != -1)
        newList.push(gals[i]);
    }
    return newList;
  },

  cellDoubleClickHandler: function (evt) {
    var target = evt.target;
    if (!target)
      return;

    var row = $("FBGallerySelectRow" + target.rownum);
    if (!row)
      return;

    this.selectedGallery = target.galid;
    this.selectedGalleryName = target.galname;
    this.selectedRow = row;

    var btn = $("galselect_selectbutton");
    if (!btn)
      return;

    try {
      btn.click();
    } catch (e) {}
  },

  cellClickHandler: function (evt) {
    // doubleclick?
    if (evt.detail && evt.detail > 1)
      this.cellDoubleClickHandler(evt);

    var target = evt.target;
    if (!target)
      return;

    var row = $("FBGallerySelectRow" + target.rownum);
    if (!row)
      return;

    if (this.selectedGallery != target.galid) {
      this.selectedGallery = target.galid;
      this.selectedGalleryName = target.galname;
      this.selectedRow = row;
    } else {
      // if this row is already selected, deselect it
      this.selectedGallery = null;
      this.selectedGalleryName = null;
      this.selectedRow = null;
    }

    this.updateRows();
    Event.stop(evt);

    this.updateControls();
  },

  updateRows: function () {
    for (i=0; i<this.galRowIds.length; i++) {
      var row = $(this.galRowIds[i]);
      if (!row)
        return;

      if (this.selectedRow == row) {
        DOM.addClassName(row, "FBGallerySelectRowHilighted");
      } else {
        DOM.removeClassName(row, "FBGallerySelectRowHilighted");
      }
    }
  },

  updateCols: function () {
    var namehead = $("FBGallerySelectNameColHeader");
    var datehead = $("FBGallerySelectDateColHeader");
    switch (this.sortMethod) {
    case 'name':
      namehead.style.textDecoration = 'underline';
      break;
    case 'date':
      datehead.style.textDecoration = 'underline';
      break;
    }
  },

  setNameSort: function () {
    this.sortMethod = 'name';
    this.buildGalTable();
  },

  setDateSort: function () {
    this.sortMethod = 'date';
    this.buildGalTable();
  },

  loadGalleries: function () {
    this.hourglass = new Hourglass($("galselect_gals"));
    var reqOpts = {};
    var handleErrorFunc = this.handleError.bind(this);
    var listReceivedFunc = this.listReceived.bind(this);
    reqOpts.onError = handleErrorFunc;
    reqOpts.url = "/tools/endpoints/getgals.bml";
    reqOpts.onData = listReceivedFunc;
    HTTPReq.getJSON(reqOpts);
  },

  galleriesSorted: function () {
    var sortby = this.sortMethod;
    if (!sortby)
      sortby = "date";

    switch(sortby) {
    case "date":
      this.galleries.sort(GallerySelect.dateSort);
      this.galleries.reverse();
      break;
    case "name":
      this.galleries.sort(GallerySelect.nameSort);
      break;
    }
  },

  setGallerySelectedCallback: function (callback) {
    this.gallerySelectedCallback = callback;
  },

  setCancelledCallback: function (callback) {
    if (this.popup)
      this.popup.setCancelledCallback(callback);
  }
});

GallerySelect.dateSort = function (a, b) {
  if (!a || !a.date || !b || !b.date) return 0;
  a = a.date ? a.date : "0000-00-00", b = b.date ? b.date : "0000-00-00";

  if (a < b)
    return -1;
  else if (a > b)
    return 1;
  else
    return 0;
};

GallerySelect.nameSort = function (a,b) {
  if (!a || !a.name || !b || !b.name) return 0;
  a.name += ""; b.name += ""; // force a and B into strings
  var aname = a.name.toUpperCase(), bname = b.name.toUpperCase();

  if (aname < bname)
    return -1;
  else if (aname > bname)
    return 1;
  else
    return 0;
};
