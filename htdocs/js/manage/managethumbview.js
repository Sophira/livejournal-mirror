ManageThumbView = new Class(ManageListView, {
  // extra parameter: cellsPerRow = number of cells to display on a row
  init: function (opts) {
    this.cellsPerRow = opts.cellsPerRow;
    ManageThumbView.superClass.init.apply(this, arguments);
  },

  render: function (data) {
    this.view.innerHTML = '';
    var table = document.createElement("table");
    table.width = "100%";
    DOM.addClassName(table, "FBManageListTable");
    this.view.appendChild(table);

    var tbody = document.createElement("tbody");
    table.appendChild(tbody);

    for (var i=0; i<data.length; i+=this.cellsPerRow) {
      // draw row
      var row = document.createElement("tr");
      tbody.appendChild(row);

      for (var j=0; j<this.cellsPerRow; j++)
        this.drawCell(row, data[i+j]);
    }
  },

  drawRow: function (table, gallery) {
    var view = this.view;

    // make a new row every three passes, otherwise just draw cell
    if (++this.cellCount % this.cellsPerRow == 0) {
      var row = document.createElement("tr");
      DOM.addClassName(row, "FBManageListTableRow");
      table.appendChild(row);
      this.lastRow = row;
    }

    if (!this.lastRow)
      return;

    this.drawCell(this.lastRow, gallery);
  }
});
