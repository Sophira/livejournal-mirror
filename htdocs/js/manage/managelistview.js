ManageListView = new Class(View, {

  init: function (opts) {
    ManageListView.superClass.init.apply(this, arguments);
  },

  render: function (data) {
    this.view.innerHTML = '';
    var tbody = document.createElement("tbody");

    var row = document.createElement("tr");
    DOM.addClassName(row, "FBManageListTableRow");
    tbody.appendChild(row);

    // the select all checkbox table header
    var checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    DOM.addClassName(checkbox, "GalleryCheckAllBox");
    var header = document.createElement("td");
    DOM.addClassName(header, "FBManageListTableHeader");
    row.appendChild(header);
    header.appendChild(checkbox);

    // the other table headers
    if (this.addHeaders)
      this.addHeaders(row);

    for (var i=0; i<data.length; i++)
      this.drawRow(tbody, data[i]);

    var tablecont = document.createElement("table");
    DOM.addClassName(tablecont, "FBManageListTable");
    tablecont.width = "100%";
    tablecont.cellPadding = "0";
    tablecont.cellSpacing = "0";

    tablecont.appendChild(tbody);
    this.view.appendChild(tablecont);
},

  addHeader: function (row, html, sortBy, sortType) {
    var header = document.createElement("td");
    DOM.addClassName(header, "FBManageListTableHeader");
    header.id = "mantableheader" + Unique.id();
    header.sortBy = sortBy;
    header.sortType = sortType;

    // add sorting link
    if (sortBy) {
      var link = document.createElement("a");
      link.innerHTML = html;
      link.href = "#";
      link.sortBy = sortBy;
      link.sortType = sortType;

      // add an arrow indicating the order of the sort
      if (this.datasource.sortBy() == sortBy) {
        if (this.datasource.sortInverted())
          link.innerHTML += " &#x2191;";
        else
          link.innerHTML += " &#x2193;";
      }

      header.appendChild(link);
      DOM.addEventListener(link, "click", this.sortSource.bindEventListener(this));
      DOM.addEventListener(header, "click", this.sortSource.bindEventListener(this));
    } else {
      header.innerHTML = html;
    }

    row.appendChild(header);
  },

  sortSource: function (evt) {
    var target = evt.target;

    Event.stop(evt);

    if (!target || !target.sortBy)
      return;

    var invert = false;

    if (target.sortBy == this.datasource.sortBy())
      invert = this.datasource.sortInverted() ? false : true;

    this.datasource.sortDataBy(target.sortBy, target.sortType, invert);
  },

  // specify HTML to be in the cell
  addCell: function (row, html) {
    var cell = this.createCell();
    cell.underlay.innerHTML = html;

    row.appendChild(cell);
    return cell;
  },

  // specify an element to add as a child of the cell
  addCellElement: function (row, element) {
    var cell = this.createCell();

    if (element)
      cell.underlay.appendChild(element);

    row.appendChild(cell);
    return cell;
  },

  // creates and returns a cell
  createCell: function () {
    var cell = document.createElement("td");
    DOM.addClassName(cell, "FBManageListTableCell");

    var underlay = document.createElement("div");
    cell.appendChild(underlay);
    DOM.addClassName(underlay, "FBManageListUnderlay");

    cell.underlay = underlay;

    return cell;
  }

});
