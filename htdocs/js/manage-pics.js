// -*-perl-*-

var lastPicClicked = null;
var colorPicClick;

function managePicsInit(selcolor)
{
    lastPicClicked = null;
    colorPicClick = selcolor;

    changeAllState(null);
    return true;
}

function actionText (txt)
{
    var d = xbGetElementById('actiondes');
    d.replaceChild(document.createTextNode(txt), d.firstChild);
    return true;
}

function changeAllState (newstate)
{
    changeAllState_h (newstate, false);
}

function invertSel ()
{
    changeAllState_h (null, true);
}

// returns true (number of pics selected)
// or false (no pics selected)
function countSelected ()
{
    var table = xbGetElementById("table_pics");
    if (! table) return 0;  // empty gallery
    var count = 0;
    var rows = table.rows;
    for (i=0; i<rows.length; i++) {
        var cells = rows[i].cells;
        for (j=0; j<cells.length; j++) {
            var id = trailNum(cells[j].id);
            var chk = xbGetElementById("pic_check_"+id);
            if (chk.checked) count++;
        }
    }
    if (count < 1) {
        alert("No pictures were selected.");
        return false;
    } else {
        return count;
    }
}

function changeAllState_h (newstate, invert)
{
    var table = xbGetElementById("table_pics");
    if (! table) return true;  // empty gallery
    var rows = table.rows;
    for (i=0; i<rows.length; i++) {
        var cells = rows[i].cells;
        for (j=0; j<cells.length; j++) {
            var id = trailNum(cells[j].id);
            var chk = xbGetElementById("pic_check_"+id);
            if (! invert) {
                if (newstate != null) chk.checked = newstate;
            
                // init
                    if (newstate == null) {
                        var img = xbGetElementById("pic_img_"+id);
                        img.onclick = picClicked;
                    }
            } else {
                chk.checked = ! chk.checked;
            }
            checkClicked(chk);
        }
    }
    return true;
}

// updates the hidden position values associated with two cells
function swapCellPos (c1, c2)
{
    var n1 = trailNum(c1.id);
    var n2 = trailNum(c2.id);
    var pos1 = xbGetElementById("pic_pos_"+n1).value;
    var pos2 = xbGetElementById("pic_pos_"+n2).value;
    xbGetElementById("pic_pos_"+n1).value = pos2;
    xbGetElementById("pic_pos_"+n2).value = pos1;

    IE_workaround(c1);
    IE_workaround(c2);
}

// In IE 6 (and others?) the checkboxes go unchecked when moving 
// the nodes around.
function IE_workaround (cell)
{
    var n = trailNum(cell.id);
    var bga = cell.getAttributeNode("bgcolor");
    var chk = xbGetElementById("pic_check_"+n);
    if (chk.checked == false && 
        bga.value != '') chk.checked = true;
}

function moveMe(b, delta) {
    var cell = b.parentNode;
    var row = cell.parentNode;
    var rows = row.parentNode.rows;  // parent is tablesection

    // normal case: sliding left in cells
    if (cell.cellIndex > 0 && delta == -1) {
        var cellleft = row.cells[cell.cellIndex-1];
        row.insertBefore(cell, cellleft)
        swapCellPos(cell, cellleft);
        b.focus();
        return true;
    }

    // normal case: sliding right in cells
    if (cell.cellIndex < row.cells.length-1 && delta == 1) {
        var cellright = row.cells[cell.cellIndex+1];
        row.insertBefore(cellright, cell);
        swapCellPos(cell, cellright)
        b.focus();
        return true;
    }

    // wrapping from left side up
    if (cell.cellIndex == 0 && delta == -1) {
        if (row.rowIndex == 0) return true; // earliest
        var prevrow = rows[row.rowIndex-1];
        var prevcells = prevrow.cells;
        var prevcell = prevcells[prevcells.length-1];
        prevrow.replaceChild(cell, prevcell);
        row.insertBefore(prevcell, row.cells[0]);
        swapCellPos(prevcell, cell);
        b.focus();
        return true;
    }

    // wrapping from right side down
    if (cell.cellIndex == row.cells.length-1 && delta == 1) {
        if (row.rowIndex == rows.length-1) return true; // latest
        var nextrow = rows[row.rowIndex+1];
        var nextcells = nextrow.cells;
        var nextcell = nextcells[0];
        nextrow.replaceChild(cell, nextcell);
        row.appendChild(nextcell);
        swapCellPos(nextcell, cell);
        b.focus();
        return true;
    }

    return true;
}

function picClicked (evt)
{
    var e = document.all ? event : evt; // IE is dumb
    var pic = document.all ? e.srcElement : e.target;  
    var modShift = e.shiftKey;
    var picid = trailNum(pic.id);
    var chk = xbGetElementById("pic_check_"+picid);
    chk.checked = ! chk.checked;
    checkClicked(chk);

    if (chk.checked && modShift && lastPicClicked) {
        selectRange(lastPicClicked, picid);
    } 
    lastPicClicked = chk.checked ? picid : null;
    return true;
}

function selectRange (ida, idb)
{
    var pos_a = xbGetElementById('pic_pos_'+ida).value;
    var pos_b = xbGetElementById('pic_pos_'+idb).value;
    var id_f = pos_a < pos_b ? ida : idb;
    var id_l = pos_a < pos_b ? idb : ida;
    
    var cell_f = xbGetElementById('pic_cell_'+id_f);
    var ri_f = cell_f.parentNode.rowIndex;
    var width = cell_f.parentNode.cells.length;
    var ci_f = cell_f.cellIndex;
    
    var cell_l = xbGetElementById('pic_cell_'+id_l);
    var ri_l = cell_l.parentNode.rowIndex;
    var ci_l = cell_l.cellIndex;

    var table = xbGetElementById("table_pics");

    var done = false;
    var ri = ri_f;
    var ci = ci_f;

    while (! done) {
        var c = table.rows[ri].cells[ci];
        var num = trailNum(c.id);
        var chk = xbGetElementById("pic_check_"+num);
        if (! chk.checked) {
            chk.checked = true;
            checkClicked(chk);            
        }

        if (ri==ri_l && ci==ci_l) done = true;
        else if (++ci >= width) { ci = 0; ri++; }
    }
    
    return true;
}

function trailNum (str)
{
    var li = str.lastIndexOf("_");
    if (li == -1) return 0;
    return str.substr(li+1);
}

function checkClicked (chk)
{
    
    var picid = trailNum(chk.id);
    var row = xbGetElementById("pic_cell_"+picid);
    var bga = row.getAttributeNode("bgcolor");
    bga.value = (chk.checked ? colorPicClick : '');
    return true;
}

