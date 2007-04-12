// Provide gallery data on a user
// the M in MVC

GalleryDataSource = new Class (JSONDataSource, {

  init: function (opts) {
    GalleryDataSource.superClass.init.apply(this, ["/tools/endpoints/getgals", this.gotGals.bind(this), opts]);
  },

  setGalInfo: function (data) {
    if (!data)
      return;

    this.receivedData(data);
  },

  gotGals: function (gals) {
    var realgals = [];

    for (var i=0; i<gals.length; i++) {
      if (!gals[i].tag)
        realgals.push(gals[i]);
    }

    this.setData(realgals);
  },

  galById: function (id) {
    var gals = this.allData();

    for (var i=0; i<gals.length; i++) {
      if (gals[i].id == id)
        return gals[i];
    }

    return null;
  }

});
