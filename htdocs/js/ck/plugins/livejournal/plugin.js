(function(){

	var likeButtons = [
		{
			label: top.CKLang.LJLike_button_google,
			id: 'google',
			abbr: 'go',
			html: '<div class="lj-like-item lj-like-gag">' + top.CKLang.LJLike_button_google + '</div>'
		},
		{
			label: top.CKLang.LJLike_button_facebook,
			id: 'facebook',
			abbr: 'fb',
			html: '<div class="lj-like-item lj-like-gag">' + top.CKLang.LJLike_button_facebook + '</div>'
		},
		{
			label: top.CKLang.LJLike_button_vkontakte,
			id: 'vkontakte',
			abbr: 'vk',
			html: '<div class="lj-like-item lj-like-gag">' + top.CKLang.LJLike_button_vkontakte + '</div>'
		},
		{
			label: top.CKLang.LJLike_button_twitter,
			id: 'twitter',
			abbr: 'tw',
			html: '<div class="lj-like-item lj-like-gag">' + top.CKLang.LJLike_button_twitter + '</div>'
		},
		{
			label: top.CKLang.LJLike_button_give,
			id: 'livejournal',
			abbr: 'lj',
			html: '<div class="lj-like-item lj-like-gag">' + top.CKLang.LJLike_button_give + '</div>'
		}
	];

	var ljUsers = {};

	CKEDITOR.plugins.add('livejournal', {
		init: function(editor){
			editor.dataProcessor.toHtml = function(html, fixForBody){
				html = html
					.replace(/<lj-template name=['"]video['"]>(\S+?)<\/lj-template>/g, '<div class="ljvideo" url="$1"><img src="' + Site
					.statprefix + '/fck/editor/plugins/livejournal/ljvideo.gif" /></div>')
					.replace(/<lj-embed\s*(?:id="(\d*)")?\s*>([\s\S]*?)<\/lj-embed>/gi, '<div class="ljembed" embedid="$1">$2</div>')
					.replace(/<lj-poll .*?>[^b]*?<\/lj-poll>/gm,
					function(ljtags){
						return new Poll(ljtags).outputHTML();
					}).replace(/<lj-template(.*?)><\/lj-template>/g, "<lj-template$1 />");

				html = html.replace(/<lj-cut([^>]*)><\/lj-cut>/g, '<lj-cut$1>\ufeff</lj-cut>')
					.replace(/(<lj-cut[^>]*>)/g, '\ufeff$1').replace(/(<\/lj-cut>)/g, '$1\ufeff');

				// IE custom tags. http://msdn.microsoft.com/en-us/library/ms531076%28VS.85%29.aspx
				if(CKEDITOR.env.ie){
					html = html.replace(/<lj-cut([^>]*)>/g, '<lj:cut$1>').replace(/<\/lj-cut>/g, '</lj:cut>')
						.replace(/<([\/])?lj-raw>/g, '<$1lj:raw>').replace(/<([\/])?lj-wishlist>/g, '<$1lj:wishlist>')
						.replace(/(<lj [^>]*)> /g, '$1> '); // IE merge spaces
				} else {
					// close <lj user> tags
					html = html.replace(/(<lj [^>]*[^\/])>/g, '$1/> ');
				}
				if(!$('event_format').checked){
					html = '<pre>' + html + '</pre>';
				}

				html = html.replace(/<br\s*\/?>/g, '');
				html = CKEDITOR.htmlDataProcessor.prototype.toHtml.call(this, html, fixForBody);

				if(!$('event_format').checked){
					html = html.replace(/<\/?pre>/g, '');
					html = html.replace(/\n/g, '<br\/>');
				}

				return html;
			};

			editor.dataProcessor.toDataFormat = function(html, fixForBody){
				// DOM methods are used for detection of node opening/closing
				/*var document = editor.document.$;
				 var newBody = document.createElement('div'),
				 copyNode = document.body.firstChild;
				 if(copyNode){
				 newBody.appendChild(copyNode.cloneNode(true));
				 while(copyNode = copyNode.nextSibling){
				 newBody.appendChild(copyNode.cloneNode(true));
				 }
				 var divs = newBody.getElementsByTagName('div'),
				 i = divs.length;
				 while(i--){
				 var div = divs[i];
				 switch(div.className){
				 // lj-template any name: <lj-template name="" value="" alt="html code"/>
				 case 'lj-template':
				 var name = div.getAttribute('name'),
				 value = div.getAttribute('value'),
				 alt = div.getAttribute('alt');
				 if(!name || !value || !alt){
				 break;
				 }
				 var ljtag = FCK.EditorDocument.createElement('lj-template');
				 ljtag.setAttribute('name', name);
				 ljtag.setAttribute('value', value);
				 ljtag.setAttribute('alt', alt);
				 div.parentNode.replaceChild(ljtag, div);
				 }

				 }
				 }*/
				html = html.replace(/^<pre>\n*([\s\S]*?)\n*<\/pre>\n*$/, '$1');

				html = CKEDITOR.htmlDataProcessor.prototype.toDataFormat.call(this, html, fixForBody);

				html = html.replace(/\t/g, ' ');
				html = html.replace(/>\n\s*(?!\s)([^<]+)</g, '>$1<');
				// rte fix, http://dev.fckeditor.net/ticket/3023
				// type="_moz" for Safari 4.0.11
				if(!CKEDITOR.env.ie){
					html = html.replace(/<br (type="_moz" )? ?\/>$/, '');
					if(CKEDITOR.env.webkit){
						html = html.replace(/<br type="_moz" \/>/, '');
					}
				}

				html = html.replace(/<form.*?class="ljpoll" data="([^"]*)"[\s\S]*?<\/form>/gi, function(form, data){
					return unescape(data);
				}).replace(/<\/lj>/g, '');

				html = html
					.replace(/<div(?=[^>]*class="ljvideo")[^>]*url="(\S+)"[^>]*><img.+?\/><\/div>/g, '<lj-template name="video">$1</lj-template>')
					.replace(/<div(?=[^>]*class="ljvideo")[^>]*url="\S+"[^>]*>([\s\S]+?)<\/div>/g, '<p>$1</p>')
					.replace(/<div class=['"]ljembed['"](\s*embedid="(\d*)")?\s*>([\s\S]*?)<\/div>/gi, '<lj-embed id="$2">$3</lj-embed>')
					.replace(/<div\s*(embedid="(\d*)")?\s*class=['"]ljembed['"]\s*>([\s\S]*?)<\/div>/gi, '<lj-embed id="$2">$3</lj-embed>')// convert qotd
					.replace(/<div([^>]*)qotdid="(\d+)"([^>]*)>[^\b]*<\/div>(<br \/>)*/g, '<lj-template id="$2"$1$3 /><br />')// div tag and qotdid attrib
					.replace(/(<lj-template id="\d+" )([^>]*)class="ljqotd"?([^>]*\/>)/g, '$1name="qotd" $2$3')// class attrib
					.replace(/(<lj-template id="\d+" name="qotd" )[^>]*(lang="\w+")[^>]*\/>/g, '$1$2 \/>'); // lang attrib

				if(!$('event_format').checked && !top.switchedRteOn){
					html = html.replace(/\n?\s*<br \/>\n?/g, '\n');
				}

				// IE custom tags
				if(CKEDITOR.env.ie){
					html = html.replace(/<lj:cut([^>]*)>/g, '<lj-cut$1>').replace(/<\/lj:cut>/g, '</lj-cut>')
						.replace(/<([\/])?lj:wishlist>/g, '<$1lj-wishlist>').replace(/<([\/])?lj:raw>/g, '<$1lj-raw>');
				}

				html = html.replace(/><\/lj-template>/g, '/>');// remove null pointer.replace(/\ufeff/g, '');

				return html;
			};

			//////////  LJ User Button //////////////
			var url = top.Site.siteroot + '/tools/endpoints/ljuser.bml',
				LJUserNode;

			editor.attachStyleStateChange(new CKEDITOR.style({
				element: 'span'
			}), function(){
				var selectNode = editor.getSelection().getStartElement().getAscendant('span', true);
				var isUserLink = selectNode && selectNode.hasClass('ljuser');
				LJUserNode = isUserLink ? selectNode : null;
				editor.getCommand('LJUserLink').setState(isUserLink ? CKEDITOR.TRISTATE_ON : CKEDITOR.TRISTATE_OFF);
			});

			editor.on('doubleclick', function(evt){
				var command = editor.getCommand('LJUserLink');
				LJUserNode = evt.data.element.getAscendant('span', true);
				if(LJUserNode && LJUserNode.hasClass('ljuser')){
					command.setState(CKEDITOR.TRISTATE_ON);
					command.exec();
					evt.data.dialog = '';
				} else {
					command.setState(CKEDITOR.TRISTATE_OFF);
				}
			});

			editor.addCommand('LJUserLink', {
				exec : function(editor){
					var userName = '',
						selection = editor.getSelection(),
						LJUser = LJUserNode;

					if(this.state == CKEDITOR.TRISTATE_ON && LJUserNode){
						userName = prompt(top.CKLang.UserPrompt, LJUserNode.getElementsByTag('b').getItem(0).getText());
					} else if(selection.getType() == 2){
						userName = selection.getSelectedText();
					}

					if(userName == ''){
						userName = prompt(top.CKLang.UserPrompt, userName);
					}

					if(!userName){
						return;
					}

					parent.HTTPReq.getJSON({
						data: parent.HTTPReq.formEncoded({
							username : userName
						}),
						method: 'POST',
						url: url,
						onData: function(data){
							if(data.error){
								alert(data.error);
								return;
							}
							if(!data.success){
								return;
							}
							data.ljuser = data.ljuser.replace('<span class="useralias-value">*</span>', '');

							if(LJUser){
								LJUser.setHtml(data.ljuser);
								LJUser.insertBeforeMe(LJUser.getFirst());
								LJUser.remove();
							} else {
								editor.insertHtml(data.ljuser);
							}
						}
					});
				}
			});

			editor.ui.addButton('LJUserLink', {
				label: top.CKLang.LJUser,
				command: 'LJUserLink'
			});

			//////////  LJ Image Button //////////////
			editor.addCommand('LJImage', {
				exec : function(editor){
					jQuery('#updateForm')
						.photouploader({
							type: 'upload'
						})
						.photouploader('show')
							.bind('htmlready', function (event, html) {
								editor.insertHtml(html);
							});
				}
			});

			editor.ui.addButton('LJImage', {
				label: 'Add Image',
				command: 'LJImage'
			});

			//////////  LJ Embed Media Button //////////////
			editor.addCommand('LJEmbedLink', {
				exec: function(){
					top.LJ_IPPU.textPrompt(top.CKLang.LJEmbedPromptTitle, top.CKLang.LJEmbedPrompt, doEmbed);
				}
			});

			editor.ui.addButton('LJEmbedLink', {
				label: top.CKLang.LJEmbed,
				command: 'LJEmbedLink'
			});

			editor.addCss('img.lj-embed' + '{' + 'background-image: url(' + CKEDITOR.getUrl(this
				.path + 'images/placeholder_flash.png') + ');' + 'background-position: center center;' + 'background-repeat: no-repeat;' + 'border: 1px solid #a9a9a9;' + 'width: 80px;' + 'height: 80px;' + '}');

			function doEmbed(content){
				if(content && content.length){
					editor.insertHtml('<div class="ljembed">' + content + '</div><br/>');
					editor.focus();
				}
			}

			//////////  LJ Cut Button //////////////
			var ljCutNode;

			editor.attachStyleStateChange(new CKEDITOR.style({
				element: 'lj-cut'
			}), function(state){
				var command = editor.getCommand('LJCut');
				command.setState(state);
				if(state == CKEDITOR.TRISTATE_ON){
					ljCutNode = this.getSelection().getStartElement().getAscendant('lj-cut', true);
				} else {
					ljCutNode = null;
				}
			});

			editor.on('doubleclick', function(evt){
				var command = editor.getCommand('LJCut');
				ljCutNode = evt.data.element.getAscendant('lj-cut', true);
				if(ljCutNode){
					command.setState(CKEDITOR.TRISTATE_ON);
					command.exec();
				} else {
					command.setState(CKEDITOR.TRISTATE_OFF);
				}
			});

			editor.addCommand('LJCut', {
				exec: function(){
					var text;
					if(this.state == CKEDITOR.TRISTATE_ON){
						text = prompt(top.CKLang.CutPrompt, ljCutNode.getAttribute('text') || top.CKLang.ReadMore);
						if(text){
							if(text == top.CKLang.ReadMore){
								ljCutNode.removeAttribute('text');
							} else {
								ljCutNode.setAttribute('text', text);
							}
						}
					} else {
						text = prompt(top.CKLang.CutPrompt, top.CKLang.ReadMore);
						if(text){
							ljCutNode = editor.document.createElement('lj-cut');
							if(text != top.CKLang.ReadMore){
								ljCutNode.setAttribute('text', text);
							}
							editor.getSelection().getRanges()[0].extractContents().appendTo(ljCutNode);
							editor.insertElement(ljCutNode);
						}
					}
				}
			});

			editor.ui.addButton('LJCut', {
				label: top.CKLang.LJCut,
				command: 'LJCut'
			});

			//////////  LJ Poll Button //////////////
			if(top.canmakepoll){
				var currentPollForm, currentPoll;
				var noticeHtml = top.CKLang
					.Poll_PollWizardNotice + '<br /><a href="#" onclick="CKEDITOR.instances.draft.getCommand(\'LJPollLink\').exec(); return false;">' + window
					.parent.CKLang.Poll_PollWizardNoticeLink + '</a>';

				editor.attachStyleStateChange(new CKEDITOR.style({
					element: 'form',
					attributes: {
						'class': 'ljpoll'
					}
				}), function(state){
					var command = editor.getCommand('LJPollLink');
					command.setState(state);
					currentPollForm = this.getSelection().getStartElement().getAscendant('form', true);
					currentPollForm = currentPollForm && currentPollForm.hasClass('ljpoll') ? currentPollForm.$ : null;
					if(state == CKEDITOR.TRISTATE_ON){
						parent.LJ_IPPU.showNote(noticeHtml, editor.container.$).centerOnWidget(editor.container.$);
					}
				});

				editor.on('doubleclick', function(evt){
					var command = editor.getCommand('LJPollLink');
					currentPollForm = evt.data.element.getAscendant('form', true);
					if(currentPollForm && currentPollForm.hasClass('ljpoll')){
						command.setState(CKEDITOR.TRISTATE_ON);
						command.exec();
						evt.data.dialog = '';
					} else {
						command.setState(CKEDITOR.TRISTATE_OFF);
					}
				});

				CKEDITOR.dialog.add('LJPollDialog', function(){
					var isAllFrameLoad = 0, okButtonNode, questionsWindow, setupWindow;

					var onLoadPollPage = function(){
						if(this.removeListener){
							this.removeListener('load', onLoadPollPage);
						}
						if(isAllFrameLoad && okButtonNode){
							currentPoll = new Poll(currentPollForm && unescape(currentPollForm.getAttribute('data')), questionsWindow
								.document, setupWindow.document, questionsWindow.Questions);

							questionsWindow.ready(currentPoll);
							setupWindow.ready(currentPoll);

							okButtonNode.style.display = 'block';
						} else {
							isAllFrameLoad++;
						}
					};

					return {
						title : top.CKLang.Poll_PollWizardTitle,
						width : 420,
						height : 270,
						onShow: function(){
							if(isAllFrameLoad){
								currentPoll = new Poll(currentPollForm && unescape(currentPollForm
									.getAttribute('data')), questionsWindow.document, setupWindow.document, questionsWindow.Questions);

								questionsWindow.ready(currentPoll);
								setupWindow.ready(currentPoll);
							}
						},
						contents : [
							{
								id : 'LJPool_Setup',
								label : 'Setup',
								padding: 0,
								elements :[
									{
										type : 'html',
										html : '<iframe src="/tools/ck_poll_setup.bml" frameborder="0" style="width:100%; height:370px"></iframe>',
										onShow: function(data){
											if(!okButtonNode){
												(okButtonNode = document.getElementById(data.sender.getButton('LJPool_Ok').domId).parentNode)
													.style.display = 'none';
											}
											var iframe = this.getElement('iframe');
											setupWindow = iframe.$.contentWindow;
											if(setupWindow.ready){
												onLoadPollPage();
											} else {
												iframe.on('load', onLoadPollPage);
											}
										}
									}
								]
							},
							{
								id : 'LJPool_Questions',
								label : 'Questions',
								padding: 0,
								elements:[
									{
										type : 'html',
										html : '<iframe src="/tools/ck_poll_questions.bml" frameborder="0" style="width:100%; height:370px"></iframe>',
										onShow: function(){
											var iframe = this.getElement('iframe');
											questionsWindow = iframe.$.contentWindow;
											if(questionsWindow.ready){
												onLoadPollPage();
											} else {
												iframe.on('load', onLoadPollPage);
											}
										}
									}
								]
							}
						],
						buttons : [new CKEDITOR.ui.button({
							type : 'button',
							id : 'LJPool_Ok',
							label : editor.lang.common.ok,
							onClick : function(evt){
								evt.data.dialog.hide();
								var pollSource = new Poll(currentPoll, questionsWindow.document, setupWindow.document, questionsWindow
									.Questions).outputHTML();
								if(pollSource.length > 0){
									if(currentPollForm){
										var node = document.createElement('div');
										node.innerHTML = pollSource;
										currentPollForm.$.parentNode.insertBefore(node.firstChild, currentPollForm.$);
										currentPollForm.remove();
									} else {
										editor.insertHtml(pollSource);
									}
									currentPollForm = null;
								}
							}
						}), CKEDITOR.dialog.cancelButton]
					};
				});

				editor.addCommand('LJPollLink', new CKEDITOR.dialogCommand('LJPollDialog'));
			} else {
				editor.addCommand('LJPollLink', {
					exec: function(editor){
						var notice = top.LJ_IPPU.showNote(top.CKLang.Poll_AccountLevelNotice, editor.container.$);
						notice.centerOnWidget(editor.container.$);
					}
				});

				editor.getCommand('LJPollLink').setState(CKEDITOR.TRISTATE_DISABLED);
			}

			editor.ui.addButton('LJPollLink', {
				label: top.CKLang.Poll,
				command: 'LJPollLink'
			});

			//////////  LJ Like Button //////////////
			var buttonsLength = likeButtons.length;
			var dialogContents = [];
			var currentLjLikeNode;
			likeButtons.defaultButtons = [];

			for(var i = 0; i < buttonsLength; i++){
				var button = likeButtons[i];
				likeButtons[button.id] = likeButtons[button.abbr] = button;
				likeButtons.defaultButtons.push(button.abbr);
				dialogContents.push({
					type: 'checkbox',
					label: button.label,
					id: 'LJLike_' + button.id
				});
			}

			dialogContents.unshift({
				type: 'html',
				html: top.CKLang.LJLike_dialogText
			});

			CKEDITOR.dialog.add('LJLikeDialog', function(){
				return {
					title : top.CKLang.LJLike_name,
					width : 200,
					height : 150,
					resizable: false,
					contents : [
						{
							id: 'LJLike_Options',
							elements: dialogContents
						}
					],
					buttons : [new CKEDITOR.ui.button({
						type : 'button',
						id : 'LJLike_Ok',
						label : editor.lang.common.ok,
						onClick : function(evt){
							var dialog = evt.data.dialog, attr = [];
							var likeNode = currentLjLikeNode || new CKEDITOR.dom.element('div');
							likeNode.setHtml('');

							for(var i = 0; i < buttonsLength; i++){
								var button = likeButtons[i];
								var buttonNode = dialog.getContentElement('LJLike_Options', 'LJLike_' + button.id);
								if(buttonNode.getValue('checked')){
									attr.push(button.abbr);
									likeNode.appendHtml(button.html);
								}
							}

							likeNode.setAttribute('buttons', attr.join(','));

							if(!currentLjLikeNode){
								likeNode.setAttribute('class', 'lj-like');
								editor.insertElement(likeNode);
							}

							dialog.hide();
						}
					}), CKEDITOR.dialog.cancelButton],
					onShow: function(){
						var command = editor.getCommand('LJLikeCommand');
						var i = 0;
						if(command.state == CKEDITOR.TRISTATE_ON){
							var buttons = currentLjLikeNode.getAttribute('buttons').split(',');
							for(var l = buttons.length; i < l; i++){
								this.getContentElement('LJLike_Options', 'LJLike_' + likeButtons[buttons[i]].id)
									.setValue('checked', true);
							}
						} else {
							for(i; i < buttonsLength; i++){
								this.getContentElement('LJLike_Options', 'LJLike_' + likeButtons[i].id).setValue('checked', false);
							}
						}
					}
				}
			});

			editor.attachStyleStateChange(new CKEDITOR.style({
				element: 'div'
			}), function(){
				currentLjLikeNode = editor.getSelection().getStartElement().getAscendant('div', true);
				while(currentLjLikeNode){
					if(currentLjLikeNode.hasClass('lj-like')){
						break;
					}
					currentLjLikeNode = currentLjLikeNode.getParent();
				}
				editor.getCommand('LJLikeCommand').setState(currentLjLikeNode ? CKEDITOR.TRISTATE_ON : CKEDITOR.TRISTATE_OFF);
			});

			editor.on('doubleclick', function(){
				var command = editor.getCommand('LJLikeCommand');
				if(command.state == CKEDITOR.TRISTATE_ON){
					command.exec();
				}
			});

			editor.addCommand('LJLikeCommand', new CKEDITOR.dialogCommand('LJLikeDialog'));

			editor.ui.addButton('LJLike', {
				label: top.CKLang.LJLike_name,
				command: 'LJLikeCommand'
			});
		},
		afterInit : function(editor){
			var flashFilenameRegex = /\.swf(?:$|\?)/i;

			function isFlashEmbed(element){
				var attributes = element.attributes;

				return ( attributes.type == 'application/x-shockwave-flash' || flashFilenameRegex.test(attributes.src || '') );
			}

			function createFakeElement(editor, realElement){
				return editor.createFakeParserElement(realElement, 'lj-embed', 'flash', false);
			}

			var dataProcessor = editor.dataProcessor;

			dataProcessor.dataFilter.addRules({
				elements: {
					'cke:object' : function(element){
						//////////  LJ Embed Media Button //////////////
						var attributes = element.attributes,
							classId = attributes.classid && String(attributes.classid).toLowerCase();

						if(!classId && !isFlashEmbed(element)){
							for(var i = 0; i < element.children.length; i++){
								if(element.children[i].name == 'cke:embed'){
									return isFlashEmbed(element.children[i]) ? createFakeElement(editor, element) : null;
								}
							}
							return null;
						}

						return createFakeElement(editor, element);
					},
					'cke:embed' : function(element){
						return isFlashEmbed(element) ? createFakeElement(editor, element) : null;
					},
					'lj-like': function(element){
						var html = '', attr = [];

						var fakeElement = new CKEDITOR.htmlParser.element('div');
						fakeElement.attributes['class'] = 'lj-like';

						var currentButtons = element.attributes.buttons && element.attributes.buttons.split(',') || likeButtons
							.defaultButtons;

						var length = currentButtons.length;
						for(var i = 0; i < length; i++){
							var buttonName = currentButtons[i].replace(/^\s*([a-z]{2,})\s*$/i, '$1');
							var button = likeButtons[buttonName];
							if(button){
								html += button.html;
								attr.push(buttonName);
							}
						}

						fakeElement.attributes.buttons = attr.join(',');
						fakeElement.add(new CKEDITOR.htmlParser.fragment.fromHtml(html));
						return fakeElement;
					},
					'lj': function(element){
						var ljUserName = element.attributes.user;
						if(!ljUserName || !ljUserName.length){
							return;
						}
						
						var ljUserTitle = element.attributes.title;
						var cacheName = ljUserTitle ? ljUserName + ':' + ljUserTitle : ljUserName;
						
						if(ljUsers.hasOwnProperty(cacheName)){
							return (new CKEDITOR.htmlParser.fragment.fromHtml(ljUsers[cacheName])).children[0];
						} else {
							var onSuccess = function(data){
								ljUsers[cacheName] = data.ljuser;

								if(data.error){
									return alert(data.error + ' "' + username + '"');
								}
								if(!data.success){
									return;
								}

								data.ljuser = data.ljuser.replace("<span class='useralias-value'>*</span>", '');

								var ljTags = editor.document.getElementsByTag('lj');

								for(var i = 0, l = ljTags.count(); i < l; i++){
									var ljTag = ljTags.getItem(i);

									var userName = ljTag.getAttribute('user');
									var userTitle = ljTag.getAttribute('title');
									if(cacheName == userTitle ? userName + ':' + userTitle : userName){
										ljTag.setHtml(ljUsers[cacheName]);
										ljTag.insertBeforeMe(ljTag.getFirst());
										ljTag.remove();
									}
								}
							};

							var onError = function(err){
								alert(err + ' "' + ljUserName + '"');
							};

							var postData = {
								username: ljUserName
							};

							if(ljUserTitle){
								postData.usertitle = ljUserTitle;
							}

							HTTPReq.getJSON({
								data: HTTPReq.formEncoded(postData),
								method: 'POST',
								url: Site.siteroot + '/tools/endpoints/ljuser.bml',
								onError: onError,
								onData: onSuccess
							});
						}
					}
				}
			}, 5);

			dataProcessor.htmlFilter.addRules({
				elements: {
					'div': function(element){
						if(element.attributes['class'] == 'lj-like'){
							var ljLikeNode = new CKEDITOR.htmlParser.element('lj-like');
							if(element.attributes.buttons && element.attributes.buttons.length){
								ljLikeNode.attributes.buttons = element.attributes.buttons;
							}
							ljLikeNode.isEmpty = true;
							ljLikeNode.isOptionalClose = true;
							return ljLikeNode;
						}
					},
					span: function(element){
						var userName = element.attributes['lj:user'];
						if(userName){
							var ljUserNode = new CKEDITOR.htmlParser.element('lj');
							ljUserNode.attributes.user = userName;
							var userTitle = element.children[1].children[0].children[0].value;

							if(userTitle && userTitle != userName){
								ljUserNode.attributes.title = userTitle;
							}

							ljUserNode.isEmpty = true;
							ljUserNode.isOptionalClose = true;
							return ljUserNode;
						}
					}
				}
			});

		},

		requires : [ 'fakeobjects' ]
	});

})();