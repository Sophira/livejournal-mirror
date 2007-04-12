// Provide picture data for a gallery

PictureDataSource = new Class(JSONDataSource, {

  init: function (galid) {
    this.gals = [];
    this.galid = galid;

    PictureDataSource.superClass.init.apply(this, ["/tools/endpoints/getpics?galleryid="+this.galid, this.gotPics.bind(this)]);
  },

  gotPics: function (pics) {
    this.setData(pics);
  }

});
