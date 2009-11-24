//////////  LJ User Button //////////////
var LJUserCommand=function(){
};
LJUserCommand.prototype.Execute=function(){
}
LJUserCommand.GetState=function() {
    return FCK_TRISTATE_OFF; //we dont want the button to be toggled
}

// Check for allowed lj user characters
LJUserCommand.validUsername = function(str) {
    var pattern = /^\w{1,15}$/i;
    return pattern.test(str);
}

LJUserCommand.Execute=function() {
    var username;
    var selection = '';

    if (FCK.EditorWindow.getSelection) {
        selection = FCK.EditorWindow.getSelection();
        // Create a new div to clone the selection's content into
        var d = FCK.EditorDocument.createElement('DIV');
        for (var i = 0; i < selection.rangeCount; i++) {
            d.appendChild(selection.getRangeAt(i).cloneContents());
        }
        selection = d.innerHTML;
    } else if (FCK.EditorDocument.selection) {
        var range = FCK.EditorDocument.selection.createRange();
        var type = FCKSelection.GetType();
        if (type == 'Control') {
            selection = range.item(0).outerHTML;
        } else if (type == 'None') {
            selection = '';
        } else {
            selection = range.htmlText;
        }
    }

    if (selection != '') {
        username = selection;
    } else {
        username = prompt(window.parent.FCKLang.UserPrompt, '');
    }

    var postData = {
        "username" : username
    };
    if (username == null) return;

    var url = window.parent.Site.siteroot + "/tools/endpoints/ljuser.bml";

    var gotError = function(err) {
        alert(err);
    }

    var gotInfo = function (data) {
        if (data.error) {
            alert(data.error);
            return;
        }
        if (!data.success) return;
		data.ljuser = data.ljuser.replace("<span class='useralias-value'>*</span>", '');
		
        FCK.InsertHtml(data.ljuser + '&nbsp;');
        if (selection != '') FCKSelection.Collapse();
        FCK.Focus();
    }

    var opts = {
        "data": window.parent.HTTPReq.formEncoded(postData),
        "method": "POST",
        "url": url,
        "onError": gotError,
        "onData": gotInfo
    };

    window.parent.HTTPReq.getJSON(opts);
    return false;
}

FCKCommands.RegisterCommand('LJUserLink', LJUserCommand ); //otherwise our command will not be found

// Create the toolbar button.
var oLJUserLink = new FCKToolbarButton('LJUserLink', window.parent.FCKLang.LJUser,
										null, null, false, false,
										[FCKConfig.PluginsPath + 'livejournal/lj_strip.png', 16, 2]
									);

// Register the button to use in the config
FCKToolbarItems.RegisterItem('LJUserLink', oLJUserLink) ;

//////////  LJ Embed Media Button //////////////
var LJEmbedCommand=function(){};
LJEmbedCommand.prototype.Execute=function(){};
LJEmbedCommand.GetState=function() {
    return FCK_TRISTATE_OFF; //we dont want the button to be toggled
}

LJEmbedCommand.Execute=function() {
    var html;
    var selection = '';

    FCKSelection.Save();

    function do_embed (content) {
        if (content != null && content != '') {
            // Make the tag like the editor would
            var html_final = "<div class='ljembed'>" + content + "</div><br/>";

            FCKSelection.Restore();
            FCK.InsertHtml(html_final);
            FCKSelection.Collapse();
            FCK.Focus();
        }
    }

    if (selection != '') {
        html = selection;
        do_embed(html);
    } else {
        var prompt = "Add media from other websites by copying and pasting their embed code here. ";
        top.LJ_IPPU.textPrompt("Insert Embedded Content", prompt, do_embed);
    }

    return;
}

FCKCommands.RegisterCommand('LJEmbedLink', LJEmbedCommand ); //otherwise our command will not be found

// Create embed media button
var oLJEmbedLink = new FCKToolbarButton('LJEmbedLink', 'Embed Media',
										null, null, false, false,
										[FCKConfig.PluginsPath + 'livejournal/lj_strip.png', 16, 3]
									);

// Register the button to use in the config
FCKToolbarItems.RegisterItem('LJEmbedLink', oLJEmbedLink) ;

//////////  LJ Cut Button //////////////
var LJCutCommand=function(){
};
LJCutCommand.prototype.GetState=function() {
	// Disabled if not WYSIWYG.
	if (FCK.EditMode != FCK_EDITMODE_WYSIWYG || ! FCK.EditorWindow)
		return FCK_TRISTATE_DISABLED ;
	
	var path = new FCKElementPath(FCKSelection.GetBoundaryParentElement(true));
	
	// See if the first block has a ljcut parent.
	for (var i = 0; i < path.Elements.length; i++) {
		if (path.Elements[i].nodeName.IEquals('lj-cut') || path.Elements[i].nodeName.IEquals('cut'))
			return FCK_TRISTATE_ON;
	}
	return FCK_TRISTATE_OFF;
}

LJCutCommand.prototype.Execute=function()
{
	if (this.GetState() == FCK_TRISTATE_ON) {
		FCKUndo.SaveUndoStep();
		
		var path = new FCKElementPath(FCKSelection.GetBoundaryParentElement(true));
		
		// See if the first block has a ljcut parent.
		for ( var i = 0 ; i < path.Elements.length ; i++ ) {
			if (path.Elements[i].nodeName.IEquals('lj-cut') || path.Elements[i].nodeName.IEquals('cut')) {
				var cut_node = path.Elements[i];
				break;
			}
		}
		var text = prompt(window.parent.FCKLang.CutPrompt, path.Elements[i].getAttribute('text') || window.parent.FCKLang.ReadMore);
		
		text && text != window.parent.FCKLang.ReadMore ?
			cut_node.setAttribute('text', text) :
			cut_node.removeAttribute('text');
	} else {
		var text = prompt(window.parent.FCKLang.CutPrompt, window.parent.FCKLang.ReadMore),
			range = new FCKDomRange(FCK.EditorWindow);
		
		range.MoveToSelection();
		
		var bookmark = range.CreateBookmark(),
			cut_node = FCK.EditorDocument.createElement('lj-cut');
		
		if (text && text != window.parent.FCKLang.ReadMore) {
			cut_node.setAttribute('text', text);
		}
		
		range.ExtractContents().AppendTo(cut_node);
		range.InsertNode(cut_node);
		
		range.MoveToBookmark(bookmark);
		range.Select();
		
		FCK.Focus();
		FCK.Events.FireEvent('OnSelectionChange');
	}
}

FCKCommands.RegisterCommand('LJCutLink', new LJCutCommand()); //otherwise our command will not be found

// Create the toolbar button.
var oLJCutLink = new FCKToolbarButton('LJCutLink', window.parent.FCKLang.LJCut,
										null, null, false, true,
										[FCKConfig.PluginsPath + 'livejournal/lj_strip.png', 16, 1]
									);

// Register the button to use in the config
FCKToolbarItems.RegisterItem('LJCutLink', oLJCutLink) ;

//////////  LJ Poll Button //////////////
var LJPollCommand=function(){
};
LJPollCommand.prototype.Execute=function(){
}
LJPollCommand.GetState=function() {
    return FCK_TRISTATE_OFF; //we dont want the button to be toggled
}

LJPollCommand.Add=function(pollsource, index) {
    var poll = pollsource;

    if (poll != null && poll != '') {
        // Make the tag like the editor would
        var html = "<div id=\"poll"+index+"\">"+poll+"</div>";

        // IE and Safari handle Selections differently and InsertHtml
        // will not overwrite the enclosing DIVs in those browsers,
        // so just replace the selected polls innerHTML
        if (FCK.Selection.Element) {
            FCK.Selection.Element.innerHTML = poll;
        } else {
            FCK.InsertHtml(html);
        }

    }

    return;
}

LJPollCommand.setKeyPressHandler=function() {
    var editor = FCK.EditorWindow.document;
    if (editor) {
        if (editor.addEventListener) {
            editor.addEventListener('keypress', LJPollCommand.ippu, false);
            editor.addEventListener('click', LJPollCommand.ippu, false);
        } else if (editor.attachEvent) {
            editor.attachEvent('onkeypress', function() { LJPollCommand.ippu(FCK.EditorWindow.event); } );
            editor.attachEvent('onclick', function() { LJPollCommand.ippu(FCK.EditorWindow.event); } );
        } else {
            editor.onkeypress = LJPollCommand.ippu;
        }
    }
}

LJPollCommand.ippu=function(evt) {
    evt = evt || window.event;
    var node = FCKSelection.GetAncestorNode( 'DIV' );
    if (evt && node && node.id.match(/poll\d+/)) {
        var ele = top.document.getElementById("draft___Frame");
        var href = "href='javascript:Poll.callRichTextEditor()'";
        var notice = parent.LJ_IPPU.showNote("Polls must be edited inside the Poll Wizard<br /><a "+href+">Go to poll wizard</a>", ele);
        notice.centerOnWidget(ele);
        if (parent.Event.stop) parent.Event.stop(evt);
    }
}

// For handling when polls are not available to a user
var LJNoPoll=function(){
};
LJNoPoll.prototype.Execute=function(){
}
LJNoPoll.GetState=function() {
        return FCK_TRISTATE_OFF; //we dont want the button to be toggled
}
LJNoPoll.Execute=function() {
    var ele = top.document.getElementById("draft___Frame");
    var notice = top.LJ_IPPU.showNote("You may only create and post polls if you have a Plus or Paid Account or if you are posting the poll to a Plus or Paid community that you maintain.", ele);
    notice.centerOnWidget(ele);
    return;
}

if (top.canmakepoll == false) {
    FCKCommands.RegisterCommand('LJPollLink', LJNoPoll);
} else {
    FCKCommands.RegisterCommand('LJPollLink',
            new FCKDialogCommand( 'LJPollCommand', 'Poll Wizard',
            '/tools/fck_poll.bml', 420, 370 ));
}

// Create the toolbar button.
var oLJPollLink = new FCKToolbarButton('LJPollLink', 'LiveJournal Poll',
										null, null, false, false,
										[FCKConfig.PluginsPath + 'livejournal/lj_strip.png', 16, 4]
										);

// Register the button to use in the config
FCKToolbarItems.RegisterItem('LJPollLink', oLJPollLink) ;

// Custom Converter for pasting from Word
// Original source taken from fck_paste.html
FCK.CustomCleanWord = function( oNode, bIgnoreFont, bRemoveStyles ) {
	var html = oNode.innerHTML ;

	html = html.replace(/<o:p>\s*<\/o:p>/g, '') ;
	html = html.replace(/<o:p>[\s\S]*?<\/o:p>/g, '&nbsp;') ;

	// Remove mso-xxx styles.
	html = html.replace( /\s*mso-[^:]+:[^;"]+;?/gi, '' ) ;

	// Remove margin styles.
	html = html.replace( /\s*MARGIN: 0(?:cm|in) 0(?:cm|in) 0pt\s*;/gi, '' ) ;
	html = html.replace( /\s*MARGIN: 0(?:cm|in) 0(?:cm|in) 0pt\s*"/gi, "\"" ) ;

	html = html.replace( /\s*TEXT-INDENT: 0(?:cm|in)\s*;/gi, '' ) ;
	html = html.replace( /\s*TEXT-INDENT: 0(?:cm|in)\s*"/gi, "\"" ) ;

	html = html.replace( /\s*TEXT-ALIGN: [^\s;]+;?"/gi, "\"" ) ;

	html = html.replace( /\s*PAGE-BREAK-BEFORE: [^\s;]+;?"/gi, "\"" ) ;

	html = html.replace( /\s*FONT-VARIANT: [^\s;]+;?"/gi, "\"" ) ;

	html = html.replace( /\s*tab-stops:[^;"]*;?/gi, '' ) ;
	html = html.replace( /\s*tab-stops:[^"]*/gi, '' ) ;

	// Remove FONT face attributes.
	if ( bIgnoreFont )
	{
		html = html.replace( /\s*face="[^"]*"/gi, '' ) ;
		html = html.replace( /\s*face=[^ >]*/gi, '' ) ;

		html = html.replace( /\s*FONT-FAMILY:[^;"]*;?/gi, '' ) ;
	}

	// Remove Class attributes
	html = html.replace(/<(\w[^>]*) class=([^ |>]*)([^>]*)/gi, "<$1$3") ;

	// Remove styles.
	if ( bRemoveStyles )
		html = html.replace( /<(\w[^>]*) style="([^\"]*)"([^>]*)/gi, "<$1$3" ) ;

	// Remove style, meta and link tags
	html = html.replace( /<STYLE[^>]*>[\s\S]*?<\/STYLE[^>]*>/gi, '' ) ;
	html = html.replace( /<(?:META|LINK)[^>]*>\s*/gi, '' ) ;

	// Remove empty styles.
	html =  html.replace( /\s*style="\s*"/gi, '' ) ;

	html = html.replace( /<SPAN\s*[^>]*>\s*&nbsp;\s*<\/SPAN>/gi, '&nbsp;' ) ;

	html = html.replace( /<SPAN\s*[^>]*><\/SPAN>/gi, '' ) ;

	// Remove Lang attributes
	html = html.replace(/<(\w[^>]*) lang=([^ |>]*)([^>]*)/gi, "<$1$3") ;

	html = html.replace( /<SPAN\s*>([\s\S]*?)<\/SPAN>/gi, '$1' ) ;

	html = html.replace( /<FONT\s*>([\s\S]*?)<\/FONT>/gi, '$1' ) ;

	// Remove XML elements and declarations
	html = html.replace(/<\\?\?xml[^>]*>/gi, '' ) ;

	// Remove w: tags with contents.
	html = html.replace( /<w:[^>]*>[\s\S]*?<\/w:[^>]*>/gi, '' ) ;

	// Remove Tags with XML namespace declarations: <o:p><\/o:p>
	// LJ SPECIFIC: exclude "lj:" tags for IE
	html = html.replace(/<\/?(?!lj:)\w+:[^>]*>/gi, '') ;

	// Remove comments [SF BUG-1481861].
	html = html.replace(/<\!--[\s\S]*?-->/g, '' ) ;

	html = html.replace( /<(U|I|STRIKE)>&nbsp;<\/\1>/g, '&nbsp;' ) ;

	html = html.replace( /<H\d>\s*<\/H\d>/gi, '' ) ;

	// Remove "display:none" tags.
	html = html.replace( /<(\w+)[^>]*\sstyle="[^"]*DISPLAY\s?:\s?none[\s\S]*?<\/\1>/ig, '' ) ;

	// Remove language tags
	html = html.replace( /<(\w[^>]*) language=([^ |>]*)([^>]*)/gi, "<$1$3") ;

	// Remove onmouseover and onmouseout events (from MS Word comments effect)
	html = html.replace( /<(\w[^>]*) onmouseover="([^\"]*)"([^>]*)/gi, "<$1$3") ;
	html = html.replace( /<(\w[^>]*) onmouseout="([^\"]*)"([^>]*)/gi, "<$1$3") ;

	if ( FCKConfig.CleanWordKeepsStructure )
	{
		// The original <Hn> tag send from Word is something like this: <Hn style="margin-top:0px;margin-bottom:0px">
		html = html.replace( /<H(\d)([^>]*)>/gi, '<h$1>' ) ;

		// Word likes to insert extra <font> tags, when using MSIE. (Wierd).
		html = html.replace( /<(H\d)><FONT[^>]*>([\s\S]*?)<\/FONT><\/\1>/gi, '<$1>$2<\/$1>' );
		html = html.replace( /<(H\d)><EM>([\s\S]*?)<\/EM><\/\1>/gi, '<$1>$2<\/$1>' );
	}
	else
	{
		html = html.replace( /<H1([^>]*)>/gi, '<div$1><b><font size="6">' ) ;
		html = html.replace( /<H2([^>]*)>/gi, '<div$1><b><font size="5">' ) ;
		html = html.replace( /<H3([^>]*)>/gi, '<div$1><b><font size="4">' ) ;
		html = html.replace( /<H4([^>]*)>/gi, '<div$1><b><font size="3">' ) ;
		html = html.replace( /<H5([^>]*)>/gi, '<div$1><b><font size="2">' ) ;
		html = html.replace( /<H6([^>]*)>/gi, '<div$1><b><font size="1">' ) ;

		html = html.replace( /<\/H\d>/gi, '<\/font><\/b><\/div>' ) ;

		// Transform <P> to <DIV>
		var re = new RegExp( '(<P)([^>]*>[\\s\\S]*?)(<\/P>)', 'gi' ) ;	// Different because of a IE 5.0 error
		html = html.replace( re, '<div$2<\/div>' ) ;

		// Remove empty tags (three times, just to be sure).
		// This also removes any empty anchor
		html = html.replace( /<([^\s>]+)(\s[^>]*)?>\s*<\/\1>/g, '' ) ;
		html = html.replace( /<([^\s>]+)(\s[^>]*)?>\s*<\/\1>/g, '' ) ;
		html = html.replace( /<([^\s>]+)(\s[^>]*)?>\s*<\/\1>/g, '' ) ;
	}

	return html ;
}

// LJ tags Data Processor implementation.
FCK.DataProcessor.ConvertToHtml = function(data)
{
	data = top.convertToHTMLTags(data); // call from rte.js
	if (!top.$('event_format').checked) {
		data = data.replace(/\n/g, '<br />');
	}
	
	// IE custom tags. http://msdn.microsoft.com/en-us/library/ms531076%28VS.85%29.aspx
	if (FCKBrowserInfo.IsIE) {
		data = data
			.replace(/<lj-cut([^>]*)>/g, '<lj:cut$1>')
			.replace(/<\/lj-cut>/g, '</lj:cut>')
			.replace(/<([\/])?lj-raw>/g, '<$1lj:raw>')
			.replace(/(<lj [^>]*)> /g, '$1> '); // IE merge spaces
	}
	else
	{
		// close <lj user> tags
		data = data.replace(/(<lj [^>]*[^\/])>/g, '$1/> ');
	}
	data = FCKDataProcessor.prototype.ConvertToHtml.call(this, data);
	
	return data;
}

FCK.DataProcessor.ConvertToDataFormat = function(body)
{
	// DOM methods are used for detection of node opening/closing
	var new_body = FCK.EditorDocument.createElement('div'),
		copy_node = body.firstChild;
	if (copy_node) {
		new_body.appendChild(copy_node.cloneNode(true));
		while (copy_node = copy_node.nextSibling) {
			new_body.appendChild(copy_node.cloneNode(true));
		}
		var divs = new_body.getElementsByTagName('div'),
			i = divs.length;
		while (i--) {
			var div = divs[i];
			switch (div.className) {
				// lj-template any name: <lj-template name="" value="" alt="html code"/>
				case 'lj-template':
					var name = div.getAttribute('name'),
						value = div.getAttribute('value'),
						alt = div.getAttribute('alt');
					if (!name || !value || !alt) {
						break;
					}
					var ljtag = FCK.EditorDocument.createElement('lj-template');
					ljtag.setAttribute('name', name);
					ljtag.setAttribute('value', value);
					ljtag.setAttribute('alt', alt);
					div.parentNode.replaceChild(ljtag, div);
			}
		}
	}
	
	arguments[0] = new_body;
	var html = FCKDataProcessor.prototype.ConvertToDataFormat.apply(this, arguments);
	// rte fix, http://dev.fckeditor.net/ticket/3023
	// type="_moz" for Safari 4.0.11
	if (!FCKBrowserInfo.IsIE) {
		html = html.replace(/<br (type="_moz" )?\/>$/, '');
	}
	
	html = top.convertToLJTags(html); // call from rte.js
	if (!top.$('event_format').checked) {
		html = html
			.replace(/<br \/>/g, '\n')
			.replace(/<p>(.*?)<\/p>/g, '$1\n')
			.replace(/&nbsp;/g, ' ');
	}
	
	// IE custom tags
	if (FCKBrowserInfo.IsIE) {
		html = html
			.replace(/<lj:cut([^>]*)>/g, '<lj-cut$1>')
			.replace(/<\/lj:cut>/g, '</lj-cut>')
			.replace(/<([\/])?lj:raw>/g, '<$1lj-raw>');
	}
	
	html = html
		.replace(/><\/lj-template>/g, '/>');
	
	return html;
}

// set cursor to end document
FCK.Focus = function(to_end) {
	FCK.EditingArea.Focus();
	if (to_end && FCK.EditingArea.Document.body.firstChild) {
		var range = new FCKDomRange(FCK.EditingArea.Window);
		
		range.MoveToPosition(FCK.EditingArea.Document.body, 2);
		range.Select();
	}
}

// not realize in editor, need in rte.js
FCKEvents.prototype.DetachEvent = function(eventName, functionPointer) {
	var aTargets = this._RegisteredEvents[eventName];
	
	if (aTargets) {
		aTargets.splice(aTargets.IndexOf(functionPointer), 1);
	}
}
