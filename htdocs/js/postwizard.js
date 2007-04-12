// -*- javascript -*- 
//
// Post-to-journal Wizard Javascript
// $Id: postwizard.js 692 2004-08-23 21:55:17Z deveiant $
// 
// Michael Granger <ged@danga.com>
// 

// Globals
var postingWizard;

// Text icon
var txtimgsrc = "/img/txt.png";

// Column width of pic-sizes
var colwidths = { t:1, s:2, f:4 };

// Multiplier of caption orientations
var capmults = {
	a: 1,
	r: 2,
	b: 1,
	l: 2,
	0: 0
};


// Utility/debugging functions
function htmlEncode( str ) {
	str.replace( /&/, "&amp;" );
	str.replace( /</, "&lt;" );
	str.replace( />/, "&gt;" );

	return str;
}

function dumpObj( e ) {
	var s="";
	var a=[["Functions","",""],["Variables","",""],["Unreachables","",""]];
	
	for ( i in e ) {
		var proto = ((e.__proto__) && (i in e.__proto__)) ? 2 : 1;
		var type = 1;
		
		try{
			if( (typeof e[i]) == "function" ) type = 0;
		} catch(er) {
			type = 2;
		}

		a[type][proto] += (a[type][proto] ? ", " : "" ) + i;
	}

	for ( i=0; i<a.length; ++i ) {
		if ( a[i][1] ) s += a[i][0] + ":\n" + a[i][1] + "\n\n";
		if ( a[i][2] ) s += a[i][0] + " of prototype:\n" + a[i][2] + "\n\n";
	}

	return htmlEncode( s );
}


function checkObject( obj, desc, etype ) {
	if ( typeof obj != "object" )
		throw "checkObject: " + desc + ": Expected an object, got: '" + obj + "'";
	if ( obj.tagName.toLowerCase != etype.toLowerCase )
		throw "checkObject: " + desc + ": Expected a " + etype + ", got: '" +
			obj.tagName + "'.";

	return true;
}

// Given a collection of select options, look for and return the first element
// therein that has a value equal to the specified value.
function getSelectItemByValue( coll, value ) {
	var i;

	xbDEBUG.dump( "Searching for value '" + value + "' in " +
				  coll );
	for ( i = 0; i < coll.length; i++ ) {
		xbDEBUG.dump( "Looking at item " + i + ": " + coll.item(i).value );
		if ( coll.item(i).value == value ) {
			xbDEBUG.dump( "Found desired value." );
			return coll.item(i);
		}
	}

	xbDEBUG.dump( "Couldn't find desired value." );
	return null;
}


// === Classes ==================================================

// --- Preview Widget class -------------------------------------
function PostingWizard() {
    this.div = xbGetElementById( 'preview-page' );
	checkObject( this.div, "Preview div", "div" );
 
	// Get the two tables the wizard interacts with: the preview widget and the
	// one containing the list of pictures to be posted.
	this.table = xbGetElementById( 'page-layout-table' );
	checkObject( this.table, "Page layout table", "table" );
	this.pictable = xbGetElementById( 'pic-table' );
	checkObject( this.pictable, "Picture table", "table" );

	// Get the three form controls that the preview cares about
	this.columnSelector = xbGetElementById( 'wizard-columns' );
	checkObject( this.columnSelector, "Column selector", "select" );
	this.sizeSelector = xbGetElementById( 'wizard-picsize' );
	checkObject( this.sizeSelector, "Size selector", "select" );
	this.caporientSelector = xbGetElementById( 'wizard-caporient' );
	checkObject( this.caporientSelector, "Caption orientation selector", "select" );
	this.borderSelector = xbGetElementById( 'wizard-border' );
	checkObject( this.borderSelector, "Border selector", "input" );

	// Get the status message display thingie
	this.statusLabel = xbGetElementById( 'wizard-status' );
	checkObject( this.statusLabel, "Status label", "td" );

	// Draw the preview
	this.paint();
}


// Put a message in the status box.
PostingWizard.prototype.status = function( msg ) {
	tnode = this.statusLabel.firstChild;
	tnode.replaceData( 0, tnode.length, msg );

	return true;
}

// Put a message in the status box for the given number of seconds, then clear
// it.
PostingWizard.prototype.timedStatus = function( seconds, msg ) {
	this.status( msg );

	// Lame: this shouldn't refer to the instance, but any other way horribly
	// complicates things (e.g., central registry of instances in the prototype?
	// Global array of instances + each instance knows its index?)
	window.setTimeout( "postingWizard.status('Ready.')", seconds * 1000 );
	return true;
}

// Get an Array of the images in the 'pictable' table, which contains the
// pictures to be published.
PostingWizard.prototype.getPictures = function () {
	xbDEBUG.dump( "Fetching picture list from pictable" );

	var icoll = this.pictable.getElementsByTagName( 'img' );
	var ary = new Array();
	var i;

	for ( i = 0; i < icoll.length; i++ )
		ary.push( icoll.item(i) );

	return ary;
}


// Get an Array of TR elements from the widget
PostingWizard.prototype.getRows = function () {
	var i;
	var ra = new Array();

	nl = this.table.rows;
	for ( i=0; i < nl.length; i++ )
		ra.push( nl.item(i) );

	xbDEBUG.dump( "Rows is: " + ra + "." );
	return ra;
}

// Get the number of columns the widget currently has.
PostingWizard.prototype.getColWidth = function () {
	return this.table.rows.item(0).cells.length;
}

// Set the number of columns in the preview widget
PostingWizard.prototype.setColumns = function (count) {
	var orient = this.caporientSelector;
	var size = this.sizeSelector;

	if ( size.value == "f" ) {
		if ( this.columnSelector.selectedIndex != 0 ) {
			this.timedStatus( 3, "Large picture type can only be 1-column." );
			this.columnSelector.selectedIndex = 0;
			count = 1;
		}
	} else if ( size.value == "s" && count > 2 ) {
		this.timedStatus( 3, "Medium picture type can have no more than 2 columns." );
		this.columnSelector.selectedIndex = 1;
		count = 2;
	}

	// Reset caption orientation for odd-numbered columns
	if ( count % 2 ) {
		getSelectItemByValue( orient.options, "r" ).disabled = true; // Right
		getSelectItemByValue( orient.options, "l" ).disabled = true; // Left

		if ( orient.value == "r" || orient.value == "l" ) {
			this.timedStatus( 3, "Caption position reset for " + count + "-column layout." );
			orient.selectedIndex = 0;
		}
	}		

	else {
		getSelectItemByValue( orient.options, "r" ).disabled = false; // Right
		getSelectItemByValue( orient.options, "l" ).disabled = false; // Left
	}

	xbDEBUG.dump( "Setting the widget's columns to " + count + "." );
	this.paint();
}


// Set the size of the posted pictures
PostingWizard.prototype.setPicsize = function (size) {
	xbDEBUG.dump( "Setting the widget's picsize to " + size + "." );
	var orient = this.caporientSelector;
	var cols = this.columnSelector;

	// Fullsize images
	if ( size == "f" ) {

		// No left- or right-attached captions
		if (orient.value == "l" || orient.value == "r")
			orient.selectedIndex = 0;

		// Disable right and left caporients
		getSelectItemByValue( orient.options, "r" ).disabled = true; // Right
		getSelectItemByValue( orient.options, "l" ).disabled = true; // Left

		// Force columns to 1
		cols.selectedIndex = 0;
		cols.options.item(1).disabled = true;
		cols.options.item(2).disabled = true;
		cols.options.item(3).disabled = true;
	}

	// Small (Medium) images
	else if ( size == "s" ) {

		// Clamp columns at 1-2
		if ( cols.selectedIndex > 1 ) cols.selectedIndex = 1;
		cols.options.item(0).disabled = false;
		cols.options.item(1).disabled = false;
		cols.options.item(2).disabled = true;
		cols.options.item(3).disabled = true;

		// No left- or right-attached captions unless there's at least 2
		// columns.
		if ( cols.selectedIndex != 1 && (orient.value == "l" || orient.value == "r") )
			orient.selectedIndex = 0;
	}

	else {

		// Enable all column settings
		cols.options.item(1).disabled = false;
		cols.options.item(2).disabled = false;
		cols.options.item(3).disabled = false;

		// Enable all caption orientations that are still valid given the
		// selected number of columns
		if ( cols.selectedIndex >= 1 ) {
			getSelectItemByValue( orient.options, "r" ).disabled = false; // Right
			getSelectItemByValue( orient.options, "l" ).disabled = false; // Left
		}
	}

	this.paint();
}


// Set the caption orientation of posted pictures
PostingWizard.prototype.setCapOrient = function (orient) {
	xbDEBUG.dump( "Changing the widget's caption orientation to " + orient + "." );
	var cols = this.columnSelector;

	// Prevent right- or left-attached captions for fullsize images
	if ( this.sizeSelector.value == "f" && (orient == "r" || orient == "l") ) {
		this.sizeSelector.selectedIndex = 1;
	}

	// Right- or left-attached captions require an even number of columns, so
	// disable the odd-numbered ones.
	if ( orient == "r" || orient == "l" ) {
		var si = cols.selectedIndex;

		cols.options.item(0).disabled = true;
		cols.options.item(2).disabled = true;

		// If there's an odd number of columns (indexed by zero), add one
		if ( si % 2 != 1 )
			cols.selectedIndex = si + 1;
	}

	// Re-enable the odd-numbered columns for any other caption orientation
	else {
		cols.options.item(0).disabled = false;
		cols.options.item(1).disabled = false;
	}

	this.paint();
}

// Toggle the table border
PostingWizard.prototype.setBorder = function (val) {
	var r, c, row, cell, bstyle;
	var widget = this.table;

	var setting = this.borderSelector.checked;
	xbDEBUG.dump( "Setting border to " + setting );

	// Pick a style based on whether borders are turned on or off
	if ( setting ) {
		bstyle = "1px solid #333";
		if ( val ) this.timedStatus( 3, "Border on." );
	} else {
		bstyle = "none";
		if ( val ) this.timedStatus( 3, "Border off." );
	}

	// Set styles on all the cells
	for ( r = 0; r < widget.rows.length; r++ ) {
		row = widget.rows.item( r );

		for ( c = 0; c < row.cells.length; c++ ) {
			cell = row.cells.item( c );
			cell.style.border = bstyle;
		}
	}

	return true;
}


// Calculate the aspect-adjusted size for a picture of the given height and
// width of the specified 'size' type.
PostingWizard.prototype.getAspectSize = function (height, width, sizefactor) {
	var optdim = 10 + (10 * sizefactor);
	var ratio, nh, nw; 

	if ( height > width ) {
		ratio = optdim / height;
	} else {
		ratio = optdim / width;
	}

	nh = height * ratio;
	nw = width * ratio;

	return { h: nh, w: nw };
}


// Make new table cells for the preview widget according to the wizard's current
// settings.
PostingWizard.prototype.makeNewPreviewCells = function () {
	var pics		= this.getPictures();
	var picsize		= this.sizeSelector.value;
	var colwidth	= colwidths[ picsize ];
	var cols		= this.columnSelector.value;
	var caporient	= this.caporientSelector.value;
	var capmult		= capmults[ caporient ];

	var rows		= new Array();
	var thisrow		= document.createElement( "tr" );
	var nextrow		= (caporient == "a" || caporient == "b") ? document.createElement("tr") : null;
	var i, img, imgcell, dim;

	// Create a caption node that can be cloned over and over
	var capnode		= document.createElement( "td" );
	img = document.createElement("img");
	img.src = txtimgsrc;
	img.height = 10 + (10 * colwidth);
	img.width = 10 + (10 * colwidth);
	capnode.appendChild( img );

	xbDEBUG.dump( "== Building new rows =====" );
	xbDEBUG.dump( "colwidth = " + colwidth + ", capmult = " + capmult );

	// Add cells/rows for each pic
	for ( i = 0; i < pics.length; i++ ) {
		xbDEBUG.dump( "Working on picture " + i );
		
		// Create the image cell
		img = document.createElement( "img" );
		img.src = pics[ i ].src;
		dim = this.getAspectSize( pics[i].height, pics[i].width, colwidth );
		img.width = dim.w;
		img.height = dim.h;
		img.alt = pics[ i ].alt;

		imgcell = document.createElement( "td" );
		imgcell.appendChild( img );

		// Done with a row, push it onto the return value. Done-ness is
		// determined by the number of cells * picsize * caption multiplier
		if ( thisrow.cells.length >= cols ) {
			xbDEBUG.dump( "- Done with row " + i + ", width is " +
						  (thisrow.cells.length * colwidth) +
						  ", cols is " + cols );


			xbDEBUG.dump( "-- thisrow has " + thisrow.cells + " cell/s." );
			rows.push( thisrow );
			thisrow = document.createElement( "tr" );
			if ( nextrow ) {
				xbDEBUG.dump( "-- nextrow has " + nextrow.cells + " cell/s." );
				rows.push( nextrow );
				nextrow = document.createElement( "tr" );
			}
		}

		// -- Logic is all controlled by where the caption is --

		// Caption above -- thisrow is the caption row, so append a caption cell
		// and the pic cell goes on the next row.
		if ( caporient == "a" ) {
			xbDEBUG.dump( "--- Caption goes in thisrow, as it's above the pic." );
			thisrow.appendChild( capnode.cloneNode(true) );
			nextrow.appendChild( imgcell );
		}

		// Caption below is, of course, the opposite
		else if ( caporient == "b" ) {
			xbDEBUG.dump( "--- Caption goes in nextrow, as it's below the pic." );
			thisrow.appendChild( imgcell );
			nextrow.appendChild( capnode.cloneNode(true) );
		}

		// Left, right, or no caption
		else {
			if ( caporient == "l" ) {
				xbDEBUG.dump( "--- Caption goes in thisrow, as it's leftish of the pic." );
				thisrow.appendChild( capnode.cloneNode(true) );
			}

			thisrow.appendChild( imgcell );

			if ( caporient == "r" ) {
				xbDEBUG.dump( "--- Caption goes in thisrow, as it's rightish of the pic." );
				thisrow.appendChild( capnode.cloneNode(true) );
			}
		}
	}

	// Finish the rows if they're not yet full
	while ( thisrow.cells.length < cols ) {
		var cell = document.createElement("td");
		cell.appendChild( document.createTextNode(" ") );
		thisrow.appendChild( cell );
		if ( nextrow ) {
			cell = document.createElement("td");
			cell.appendChild( document.createTextNode(" ") );
			nextrow.appendChild( cell );
		}
	}

	// Append the final row/s
	rows.push( thisrow );
	if ( nextrow ) rows.push( nextrow );

	xbDEBUG.dump( "===========================" );
	return rows;
}

// Draw the preview widget
PostingWizard.prototype.paint = function () {
	xbDEBUG.dump( "Painting with " + this.columnSelector.value + " columns, " +
				  "picsize = " + this.sizeSelector.value + ", and caption orientation = " +
				  this.caporientSelector.value );

    this.div.style.display = "block";

	var newRows = this.makeNewPreviewCells();
	xbDEBUG.dump( "Got " + newRows.length + " new rows." );

	// Remove all old rows
	var tbody = this.table.tBodies.item( 0 );
	xbDEBUG.dump( "Deleting " + tbody.rows.length + " old rows." );
	while ( tbody.rows.length != 0 ) tbody.deleteRow(0);

	// Now append all the new rows
	for ( row in newRows ) {
		xbDEBUG.dump( "Appending " + newRows[row] );
		tbody.appendChild( newRows[row] );
	}

    // Reset the border, as changing cells apparently restores borders in
    // Mozilla.
    this.setBorder( 0 );

	return true;
}


// === Event handlers ==================================================

function wizard_init( ev ) {
	xbDEBUG.dump( "Initializing a new preview widget." );
	postingWizard = new PostingWizard();
    postingWizard.status( "Loading..." );

    // Hook controls up to event handlers
	postingWizard.status( "Activating controls" );
	postingWizard.columnSelector.onchange = wizard_columns_change;
	postingWizard.sizeSelector.onchange = wizard_picsize_change;
	postingWizard.caporientSelector.onchange = wizard_caporient_change;
    
    // Work around Webkit (Safari) bug
    if ( window.navigator.userAgent.toLowerCase().indexOf('applewebkit') != 0 ) {
        xbDEBUG.dump( "Border selector = onclick" );
        postingWizard.borderSelector.onclick = wizard_border_change;
    } else {
        xbDEBUG.dump( "Border selector = onchange" );
        postingWizard.borderSelector.onchange = wizard_border_change;
    }

	postingWizard.status( "" );

	if ( xbDEBUG.debugwindow )
		xbDEBUG.debugwindow.moveTo( 0, 0 );

	xbDEBUG.dump( "Preview widget: " + dumpObj(postingWizard) );
}

// User changed the number of columns dropdown
function wizard_columns_change( ev ) {
	xbDEBUG.dump( "Changed columns: " + ev + " (" + ev.target.value + ")" );
	return postingWizard.setColumns( ev.target.value );
}

// User changed the picture size
function wizard_picsize_change( ev ) {
	xbDEBUG.dump( "Changed picsize: " + ev + " (" + ev.target.value + ")" );
	return postingWizard.setPicsize( ev.target.value );
}

// User changed the caption orientation
function wizard_caporient_change( ev ) {
	xbDEBUG.dump( "Changed caporient: " + ev + " (" + ev.target.value + ")" );
	return postingWizard.setCapOrient( ev.target.value );
}

// onChange handler for the border selector
function wizard_border_change( ev ) {
	xbDEBUG.dump( "Changed border: " + ev + " (" + ev.target.value + ")" );
	return postingWizard.setBorder( ev.target.value );
}
