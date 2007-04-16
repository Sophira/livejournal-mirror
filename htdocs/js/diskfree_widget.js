// attach to an element and make it a diskfree widget

DiskFree_Widget = new Class(Object, {

  init: function (ele) {
    DiskFree_Widget.superClass.init.apply(this, arguments);
    this.ele = ele;
    this.update();
  },

  update: function () {
    if (!this.ele)
      return;

    var reqOpts = {};
    var handleErrorFunc = this.handleError.bind(this);
    reqOpts.onError = handleErrorFunc;
    reqOpts.url = "/tools/endpoints/diskfree_widget.bml";
    reqOpts.onData = this.widgetReceived.bind(this);
    HTTPReq.getJSON(reqOpts);
  },

  handleError: function (err) {

  },

  widgetReceived: function (widget) {
    if (!this.ele)
      return;

    this.ele.innerHTML = widget.diskfree_widget;
  }

});
