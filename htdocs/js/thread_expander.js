
Expander = function(){
	this.__caller__;
	this.url;
	this.id;
	this.onclick;
	this.stored_caller;
	this.iframe;
	this.is_S1;
}
Expander.Collection={};
Expander.make = function(el,url,id,is_S1){
	var local = (new Expander).set({__caller__:el,url:url.replace(/#.*$/,''),id:id,is_S1:!!is_S1});
	local.get();
}

Expander.prototype.set = function(options){
	for(var opt in options){
		this[opt] = options[opt];
	}
	return this;
}

Expander.prototype.getCanvas = function(id,context){
	return context.document.getElementById('ljcmt'+id);	
}

Expander.prototype.parseLJ_cmtinfo = function(context,callback){
 	var map={};
	var LJ = context.LJ_cmtinfo;
	if(!LJ)return false;
	for(var j in LJ){
		if(/^\d*$/.test(j)){
			map[j] = {info:LJ[j],canvas:this.getCanvas(j,context)};
			if(typeof callback == 'function'){
				callback(j,map[j]);		
			}
		}
	}
	return map;	
}

Expander.prototype.loadingStateOn = function(){
	this.stored_caller = this.__caller__.cloneNode(true); 
	this.__caller__.setAttribute('already_clicked','already_clicked');
	this.onclick = this.__caller__.onclick;
	this.__caller__.onclick = function(){return false;}
	this.__caller__.style.color = '#ccc';
}

Expander.prototype.loadingStateOff = function(){
	//try{	
	this.__caller__.removeAttribute('already_clicked','already_clicked');
	this.__caller__.parentNode.replaceChild(this.stored_caller,this.__caller__);
	//document.body.removeChild(this.iframe);
	var obj = this;
	
	window.setTimeout(function(){obj.killFrame()},100);
	//}catch(e){console.log(e)}
}

Expander.prototype.killFrame = function(){
	document.body.removeChild(this.iframe);	
}

Expander.prototype.isFullComment = function(comment){
	//return /(^|\s)ljcmt_full(\s|$)/.test(canvas.className);	
	return !!Number(comment.info.full);
}


Expander.prototype.killDuplicate = function(comments){
	var comment;
	var id,id_,el,el_;
	for(var j in comments){
		if(!/^\d*$/.test(j))continue;
		el_ = comments[j].canvas;
		id_ = el_.id;
		id = id_.replace(/_$/,'');
		el = document.getElementById(id);
		if(el!=null){
			//in case we have a duplicate;
			el_.parentNode.removeChild(el_);
		}else{
			el_.id = id;
		}
	}
}

Expander.prototype.getS1width = function(canvas){
  var w;
  //TODO:  may be we should should add somie ID to the spacer img instead of searching it
  //yet, this works until we have changed the spacers url = 'dot.gif');
  var img, imgs, found;
  imgs = canvas.getElementsByTagName('img');
  if(!imgs)return false;	
  for(var j=0;j<imgs.length;j++){
	img=imgs[j];
 	if(/dot\.gif$/.test(img.src)){
	    found = true;
	    break;	
	}
  }
  if(found&&img.width)return Number(img.width);	  
  else return false;	 
}

Expander.prototype.setS1width = function(canvas,w){
  var img, imgs, found;
  imgs = canvas.getElementsByTagName('img');
  if(!imgs)return false;	
  for(var j=0;j<imgs.length;j++){
	img=imgs[j];
 	if(/dot\.gif$/.test(img.src)){
	    found = true;
	    break;	
	}
  }
  if(found)img.setAttribute('width',w); 		
}

Expander.prototype.onLoadHandler = function(iframe){
		var doc = iframe.contentDocument || iframe.contentWindow;
        doc = doc.document||doc;
		var obj = this;
		var win = doc.defaultView||doc.parentWindow;
		var comments_intersection={};
		var comments_page = this.parseLJ_cmtinfo(window);
		var comments_iframe = this.parseLJ_cmtinfo(win,function(id,new_comment){
									if(id in comments_page){
										//console.log(comment_in_frame.canvas.innerHTML, comments_page[id].canvas.innerHTML);
										comments_page[id].canvas.id = comments_page[id].canvas.id+'_';
										comments_intersection[id] = comments_page[id];
										if(!obj.isFullComment(comments_page[id])&&obj.isFullComment(new_comment)){
											var w;
											if(obj.is_S1){
											    w =obj.getS1width(comments_page[id].canvas);		
											}
											comments_page[id].canvas.innerHTML = new_comment.canvas.innerHTML;
											if(obj.is_S1 && w!==null){
													obj.setS1width(comments_page[id].canvas,w);
											}
											//TODO: may be this should be uncommented
											//comments_page[id].canvas.className = new_comment.canvas.className;
											LJ_cmtinfo[id].full=1;
										}
									}//if(id in comments_page){
								});
	   this.killDuplicate(comments_intersection);	
	   this.loadingStateOff();
	   return true;
}


//just for debugging
Expander.prototype.toString = function(){
  return '__'+this.id+'__';	
}


Expander.prototype.get = function(){
	if(this.__caller__.getAttribute('already_clicked')){
		return false;
	}
	this.loadingStateOn();
	
	var iframe;
	if(/*@cc_on !@*/0){
		Expander.Collection[this.id] = this;
		iframe = document.createElement('<iframe onload="Expander.Collection['+this.id+'].onLoadHandler(this)">');
	}else{
    	iframe = document.createElement('iframe');
		iframe.onload = function(obj){return function(){
							obj.onLoadHandler(iframe);
						}}(this);
	}
	iframe.style.height='1px';
	iframe.style.width='1px';
	iframe.style.display = 'none';
	iframe.src = this.url;
	document.body.appendChild(iframe);
	this.iframe=iframe;
	return true;
}
