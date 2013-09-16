//= require js/hourglass.js
//= require js/relations/relations.js

//= require_preprocessed_template Widgets/contextualhover.jqtmpl

/*global ContextualPopup, Hourglass */

/**
 * Contextual popup is displayed on mouse hover near
 * every userpic and userhead
 */

/**
 * Widget shows the dialog to edit current user note.
 */
LJWidgetIPPU_AddAlias = new Class(LJWidgetIPPU, {
    init: function (opts, params) {
        opts.widgetClass = "IPPU::AddAlias";
        this.width = opts.width; // Use for resizing later
        this.height = opts.height; // Use for resizing later
        this.alias = opts.alias;
        LJWidgetIPPU_AddAlias.superClass.init.apply(this, arguments);
    },

    changeAlias: function (evt, form) {
        this.doPost({
            alias: form['Widget[IPPU_AddAlias]_alias'].value + '',
            foruser: form['Widget[IPPU_AddAlias]_foruser'].value + ''
        });

        evt.preventDefault();
    },

    onData: function (data) {
        if (!data.res || !data.res.success) {
            return;
        }

        this.close();

        //Changing button. Only on profile page
        var edit_node = jQuery('.profile_addalias');
        if (edit_node.length) {
            if (data.res.alias) {
                edit_node[0].style.display = 'none';
                edit_node[1].style.display = 'block';
                edit_node[1].firstChild.alias = data.res.alias;
            } else {
                edit_node[0].style.display = 'block';
                edit_node[1].style.display = 'none';
            }
        }

        var username = data.res.username,
            alias = data.res.alias;
        if (ContextualPopup.cachedResults[username]) {
            ContextualPopup.cachedResults[username].alias_title = alias ? 'Edit Note' : 'Add Note';
            ContextualPopup.cachedResults[username].alias = alias;
        }

        if (ContextualPopup.currentId === username) {
            ContextualPopup.renderPopup(ContextualPopup.currentId);
        }
    },

    onError: function (msg) {
        LJ_IPPU.showErrorNote('Error: ' + msg);
    },

    onRefresh: function () {
        var form = jQuery('#addalias_form').get(0),
            input = jQuery(form['Widget[IPPU_AddAlias]_alias']),
            delete_btn = jQuery(form['Widget[IPPU_AddAlias]_aliasdelete']),
            widget = this;
        input.focus();

        if (delete_btn.length) {
            delete_btn.click(function(){
                input.val('');
            });
            input.input(function() {
                // save button disabled
                form['Widget[IPPU_AddAlias]_aliaschange'].disabled = !this.value;
            });
        }

        jQuery(form).submit(function(e) { widget.changeAlias(e, form); });
    },

    cancel: function () {
        this.close();
    }
});


//this object contains only authToken
Aliases = {};
function addAlias(target, ptitle, ljusername, oldalias, callback) {
    var widget;

    if ( !ptitle ) { return true; }

    widget = new LJWidgetIPPU_AddAlias({
        title: ptitle,
        width: 440,
        height: 180,
        authToken: Aliases.authToken,
        callback: callback
    }, {
        alias: target.alias||oldalias,
        foruser: ljusername
    });

    return false;
}


(function($) {
    'use strict';

    var rex_userpic = /(userpic\..+\/\d+\/\d+)|(\/userpic\/\d+\/\d+)/;

    /**
     * Object contains methods to build and display user popup.
     */
    var popup = {
        popupDelay: 500,
        popupTimer: null,
        adriverImages : {
            anonymous: 'http://ad.adriver.ru/cgi-bin/rle.cgi?sid=1&ad=186396&bt=21&pid=482107&bid=893162&bn=893162&rnd={random}',
            guest: 'http://ad.adriver.ru/cgi-bin/rle.cgi?sid=1&ad=186396&bt=21&pid=482107&bid=893165&bn=893165&rnd={random}',
            self: 'http://ad.adriver.ru/cgi-bin/rle.cgi?sid=1&ad=186396&bt=21&pid=482107&bid=893167&bn=893167&rnd={random}'
        },

        classNames: {
            popup: 'b-popup-contextual'
        },
        selectors: {
            wrapper: '.b-contextualhover',
            bubble: '.b-popup',
            popup: '.contextualPopup'
        },
        templates: {
            wrapper: '<div class="b-contextualhover"></div>',
            content: 'templates-Widgets-contextualhover',
            loading: 'Loading...'
        },

        init: function() {
            var wrapper = jQuery(this.templates.wrapper),
                self = this;

            this._visible = false;

            this.element = jQuery(wrapper).bubble({
                alwaysShowUnderTarget: true,
                closeControl: false,
                show: function() {
                    ContextualPopup._visible = true;
                },
                hide: function() {
                    ContextualPopup.hideHourglass();
                    ContextualPopup._visible = false;
                },
                classNames: {
                    containerAddClass: this.classNames.popup
                }
            });

            this.bindShowHideEvents(this.element.closest(this.selectors.bubble));
        },

        bindShowHideEvents: function(el) {
            var self = this;
            el = jQuery(el);

            el.bind('mouseenter', function(ev) { self.show(); });
            el.bind('mouseleave', function(ev) { self.hide(); });
        },

        show: function(force) {
            this.setVisibile(true, force);
        },

        hide: function(force) {
            this.setVisibile(false, force);
        },

        setVisibile: function(isVisible, force) {
            var action = isVisible ? 'show' : 'hide',
                self = this;

            force = force || false;
            clearTimeout(this.popupTimer);

            if (force) {
                this.element.bubble(action);
            } else {
                this.popupTimer = setTimeout(function() {
                    self.element.bubble(action);
                }, this.popupDelay);
            }
        },

        /**
         * Constructs object, passes it to the template,
         * inserts it in the bubble and binds events.
         *
         * @param {Object} data Object returned from the endpoint.
         * @param {String} ctxPopupId The id of the user.
         */
        render: function(data, ctxPopupId) {
            if (!data) {
                this.element.empty().append(this.templates.loading);
                return;
            } else if (!data.username || !data.success || data.noshow) {
                this.hide(true);
                return;
            }

            var buildObject = {
                headLinks: [],
                linkGroups: []
            };

            if (data.url_userpic && data.url_userpic !== ctxPopupId) {
                buildObject.userpic = {
                    allpics: data.url_allpics,
                    pic: data.url_userpic
                };
            }

            buildObject.title = {
                title: data.ctxpopup_status
            };

            // aliases
            if (!data.is_requester && data.is_logged_in) {
                if (data.alias_enable) {
                    if (data.alias) {
                        buildObject.headLinks.push('<i>' + data.alias.encodeHTML() + '</i>');
                    }

                    buildObject.headLinks.push({
                        url: Site.siteroot + '/manage/notes.bml',
                        click: function(e)
                        {
                            e.preventDefault();
                            addAlias(this, data.alias_title, data.username, data.alias || '');
                        },
                        text: data.alias_title
                    });
                } else {
                    buildObject.headLinks.push(
                        '<span class="alias-unavailable">'+
                            '<a href="'+Site.siteroot+'/manage/account">'+
                                '<img src="'+Site.statprefix+'/horizon/upgrade-paid-icon.gif?v=2621" width="13" height="16" alt=""/>'+
                            '</a> '+
                            '<a href="'+Site.siteroot+'/support/faq/295.html">'+data.alias_title+'</a>'+
                        '</span>');
                }
            }

            if (data.is_logged_in && !data.is_requester) {

                // add/remove friend link
                (function () {

                    // do not show 'add friend / watch community' links. Only subscribe link should be
                    if ( LJ.Flags.isEnabled('friendsAndSubscriptions') ) {
                        if (!data.is_person && !data.is_identity) {
                            return;
                        }
                    }

                    buildObject.headLinks.push({
                        selector: 'a[href="{url}"]:first',
                        url: data.url_addfriend,
                        click: function (e) {
                            e.preventDefault();
                            e.stopPropagation();
                            ContextualPopup.changeRelation(data, ctxPopupId, data.is_friend ? 'removeFriend' : 'addFriend', e);
                        },
                        text: (function() {
                            if (data.is_comm) {
                                return data.is_friend ? data.ml_stop_community : data.ml_watch_community;
                            } else if (data.is_syndicated) {
                                return data.is_friend ? data.ml_unsubscribe_feed : data.ml_subscribe_feed;
                            } else {
                                return data.is_friend ? data.ml_remove_friend : data.ml_add_friend;
                            }
                        }())
                    });
                }());

                // subscribe/unsubscribe
                if ( LJ.Flags.isEnabled('friendsAndSubscriptions') ) {
                    buildObject.headLinks.push({
                        selector: 'a[href=#subscription]',
                        url: '#subscription',
                        click: function (e) {
                            ContextualPopup.changeRelation(
                                data,
                                ctxPopupId,
                                data.is_subscribedon ? 'unsubscribe' : 'subscribe',
                                e
                            );
                            e.preventDefault();
                            e.stopPropagation();
                        },
                        text: data.is_subscribedon ? data.ml_unsubscribe : data.ml_subscribe
                    });
                }

                if (data.is_friend && !data.is_identity) {
                    buildObject.headLinks.push({
                        url: data.url_addfriend,
                        text: data.ml_edit_friend_tags
                    });
                }
            }

            var linkGroup = [];

            // community member
            if (data.is_logged_in && data.is_comm) {
                linkGroup.push({
                    selector: 'a[href="{url}"]',
                    url: data.is_member ? data.url_leavecomm : data.url_joincomm,
                    text: data.is_member ? data.ml_leave : data.ml_join_community,
                    click: function(e)
                    {
                        e.preventDefault();
                        ContextualPopup.changeRelation(data, ctxPopupId, data.is_member ? 'leave' : 'join', e);
                    }
                });
            }

            //filter community
            if( ( !data.is_comm && Site.current_journal && ( 'is_comm' in Site.current_journal ) &&
                        Site.current_journal.is_comm === '1' ) || data.posted_in ) {
                linkGroup.push({
                    url: ( ( data.posted_in ) ? data.posted_in : Site.current_journal.url_journal ) + '/?poster=' + data.username,
                    text: ( Site.remoteUser === data.username && !data.posted_in ) ?
                            ( data.ml_filter_by_poster_me || 'Filter community by me' ) :
                            ( data.ml_filter_by_poster || 'Filter community by poster' )
                });
            }

            buildObject.linkGroups.push(linkGroup);
            linkGroup = [];

            // send message
            if (data.is_logged_in && data.is_person && ! data.is_requester && data.url_message) {
                linkGroup.push({
                    url: data.url_message,
                    text: data.ml_send_message
                });
            }

            // vgift
            if ((data.is_person || data.is_comm) && !data.is_requester && data.can_receive_vgifts) {
                linkGroup.push({
                    url: Site.siteroot + '/shop/vgift.bml?to=' + data.username,
                    text: data.ml_send_gift
                });
            }

            // wishlist
            // commented according to task LJSUP-11396
            //if ((data.is_person || data.is_comm) && !data.is_requester && data.wishlist_url) {
            //  linkGroup.push({
            //      url: data.wishlist_url,
            //      text: data.ml_view_wishlist
            //  });
            //}

            // buy the same userhead
            if (data.is_logged_in && data.is_person && ! data.is_requester && data.is_custom_userhead) {
                linkGroup.push((data.is_app_userhead) ?
                        { url: data.url_userhead_install, text: data.ml_userhead_install } :
                        { url: data.url_buy_userhead, text: data.ml_buy_same_userhead }
                );
            }

            // identity
            if (data.is_identity && data.is_requester) {
                linkGroup.push({
                    url: Site.siteroot + '/identity/convert.bml',
                    text: data.ml_upgrade_account
                });
            }

            // add site-specific content here
            var extraContent = this.extraInfo(data);
            if (extraContent) {
                linkGroup.push(extraContent);
            }

            buildObject.linkGroups.push(linkGroup);

            if (data.is_logged_in && !data.is_requester && !data.is_comm && !data.is_syndicated) {
                buildObject.showBanOptions = true;
                buildObject.banUsersLink = {
                    url: Site.siteroot + '/manage/banusers.bml',
                    text: data.ml_ban
                };

                // ban/unban
                buildObject.banCheckboxes = [];
                buildObject.banCheckboxes.push({
                    selector: '.ban_user',
                    className: 'ban_user',
                    label: data.ml_ban_in_my,
                    checked: data.is_banned,
                    change: function(e)
                    {
                        e.preventDefault();
                        ContextualPopup.changeRelation(data, ctxPopupId, data.is_banned ? 'setUnban' : 'setBan', e);
                    }
                });

                // report a bot
                if (!Site.remote_is_suspended) {
                    buildObject.reportBot = {
                        url: Site.siteroot + '/abuse/bots.bml?user=' + data.username,
                        text: data.ml_report
                    };
                }

                // ban user from all maintained communities
                if (!data.is_requester && !data.is_comm && !data.is_syndicated && data.have_communities) {
                    buildObject.banCheckboxes.push({
                        selector: '.ban_everywhere',
                        className: 'ban_everywhere',
                        label: data.ban_everywhere_title,
                        checked: data.is_banned_everywhere,
                        change: function(e)
                        {
                            e.preventDefault();
                            var action = data.is_banned_everywhere ? 'unbanEverywhere' : 'banEverywhere';
                            ContextualPopup.changeRelation(data, ctxPopupId, action, e);
                        }
                    });
                }
            }

            var userType = 'guest';
            if (!data.is_logged_in) { //  anonymous
                userType = 'anonymous';
            } else if (data.is_requester) { // self
                userType = 'self';
            }

            new Image().src = this.adriverImages[userType].supplant({ random: Math.random()});


            buildObject.socialCap = {
                first: !!data.first
            };

            buildObject.partner = !!data.partner;

            if (data.value) { buildObject.socialCap.value = data.value; }

            this.element
                .empty()
                .append(LJ.UI.template(this.templates.content, buildObject));

            if (this.element.is(':visible')) {
                //show method forces bubble to reposition with respect to the new content
                this.element.bubble('updatePosition');
            }

            this.setPopupEvents(buildObject);
        },

        extraInfo: function(userdata) {
            var content = '';
            if (userdata.is_person) {
                if (userdata.is_online !== null) {
                    content = '<a href="' + Site.siteroot + '/chat/">' + userdata.ml_ljtalk + '</a>';
                    if (userdata.is_online) {
                        content += " " + userdata.ml_online;
                    } else if (userdata.is_online == '0') {
                        content += " " + userdata.ml_offline;
                    }
                }
            }

            return content;
        },

        /**
         * Go through all build objects and find all callbacks that should be bound
         * to the node events.
         *
         * @param {Object} buildObject Template object.
         */
        setPopupEvents: function(buildObject) {
            var element = this.element;
            element.undelegate();

            function walkObject(obj) {
                $.each(obj, function(key, value) {
                    var selector;

                    if (value.click) {
                        //default handler is by url
                        selector = value.selector || '[href="' + value.url + '"]';
                        selector = selector.supplant(value);
                        element.delegate(selector, 'click', value.click);
                    }

                    if (value.change) {
                        //for checkboxes selector should present anyway
                        selector = value.selector;
                        selector = selector.supplant(value);
                        element.delegate(selector, 'change', value.change);
                    }

                    //maybe this object has children with events to be set
                    if (typeof value === 'object') {
                        walkObject(value);
                    }
                });
            }

            walkObject(buildObject);
        }
    };

    window.ContextualPopup = {
        cachedResults  : {},
        currentRequests: {},
        currentId      : null,
        currentElement : null,
        hourglass      : null,

        /*
         * Init live handler for contextual popups
         */
        setupLive: function() {
            popup.init();

            $(document.body)
                // remove standart listeners from setup
                .off('mouseover', ContextualPopup.mouseover)
                .off('click', ContextualPopup.touchStart)

                // use live listener
                .on('mouseover ' + (LJ.Support.touch ? 'click' : ''), '.ljuser, img', function(event) {

                    // handle <img> with link to userpic
                    if (this.tagName.toLowerCase() === 'img' && !$(this).attr('src').match(rex_userpic)) {
                        return;
                    }

                    ContextualPopup.activate(event, true);
                });
        },

        setup: function() {
            /* this method is no longed needed, because of ContextualPopup.setupLive */
            return this;
        },

        /**
         * Search child nodes and bind hover events on them if needed.
         */
        searchAndAdd: function(node) {
            if (!Site.ctx_popup) { return; }

            // attach to all ljuser head icons
            var rex_userid = /\?userid=(\d+)/,
                class_nopopup = 'noctxpopup',
                ljusers = jQuery('span.ljuser:not(.' + class_nopopup + ')>a>img', node),
                i = -1, userid, ljuser, parent;

            // use while for speed
            while (ljusers[++i]) {
                ljuser = ljusers[i];
                parent = ljuser.parentNode;
                userid = parent.href.match(rex_userid);

                if (parent.href && userid) {
                    ljuser.userid = userid[1];
                } else if (parent.parentNode.getAttribute('lj:user')) {
                    ljuser.username = parent.parentNode.getAttribute('lj:user');
                } else {
                    continue;
                }

                ljuser.posted_in = parent.parentNode.getAttribute('data-journal');
                ljuser.className += ' ContextualPopup';
            }

            ljusers = node.getElementsByTagName('img');
            i = -1;
            while (ljusers[++i]) {
                ljuser = ljusers[i];
                if (ljuser.src.match(rex_userpic) && ljuser.className.indexOf(class_nopopup) < 0) {
                    ljuser.up_url = ljuser.src;
                    if (ljuser.parentNode.getAttribute('data-journal')) {
                        ljuser.posted_in = ljuser.parentNode.getAttribute('data-journal');
                    }
                    ljuser.className += ' ContextualPopup';
                }
            }
        },

        activate: function(e, useLive) {
            if (useLive && !(e.target.username || e.target.userid || e.target.up_url)) {
                ContextualPopup.searchAndAdd($(e.currentTarget).parent().get(0));
            }

            var target = e.target,
                ctxPopupId = target.username || target.userid || target.up_url,
                t = ContextualPopup;

            if (target.tagName === 'IMG' && ctxPopupId) {
                // if we don't have cached data background request it
                if (!t.cachedResults[ctxPopupId]) {
                    t.getInfo(target, ctxPopupId);
                }

                // doesn't display alt as tooltip
                if (jQuery.browser.msie && target.title !== undefined) {
                    target.title = '';
                }

                // show other popup
                if (t.currentElement !== target) {
                    t.showPopup(ctxPopupId, target);
                } else {
                    popup.show();
                }

                return true;
            }

            return false;
        },

        mouseOver: function(e) {
            ContextualPopup.activate(e);
        },

        touchStart: function(e) {
            var current = ContextualPopup.currentElement;

            //if popup is activated then currentElement property is rewriten somewhere inside the activate
            //function and this condition works;
            if (ContextualPopup.activate(e) && (!ContextualPopup._visible || current !== ContextualPopup.currentElement)) {
                e.preventDefault();
                e.stopPropagation();
            }
        },

        showPopup: function(ctxPopupId, ele) {
            var showNow = popup.element.is(':visible');
            jQuery(this.currentElement)
                .unbind('mouseenter mouseleave');

            this.currentId = ctxPopupId;
            var data = this.cachedResults[ctxPopupId];

            if (data && data.noshow) { return; }
            if (this.currentElement && this.currentElement !== ele) {
                popup.hide(true);
            }

            if (data && data.error) {
                popup.hide(true);
                ContextualPopup.showNote(data.error, ele);
                return;
            }

            popup.render(data, ctxPopupId);
            popup.element.bubble('option', 'target', jQuery(ele));
            popup.bindShowHideEvents(ele);
            popup.show(showNow);
            this.currentElement = ele;
        },

        /**
         * Hide currently opened popup
         */
        hide: function () {
            popup.hide(true);
            return this;
        },

        renderPopup: function(ctxPopupId) {
            popup.render(this.cachedResults[ctxPopupId], ctxPopupId);
        },

        // ajax request to change relation
        changeRelation: function (info, ctxPopupId, action, e) {
            function changedRelation(data) {
                if (data.error) {
                    return ContextualPopup.showNote(data.error.message);
                }

                if (ContextualPopup.cachedResults[ctxPopupId]) {
                    jQuery.extend(ContextualPopup.cachedResults[ctxPopupId], data);
                }

                // if the popup is up, reload it
                ContextualPopup.renderPopup(ctxPopupId);
            }

            LJ.Api.call(
                'change_relation.' + action.toLowerCase(),
                { target: info.username },
                function (data) {
                    ContextualPopup.hourglass.hide();
                    ContextualPopup.hourglass = null;
                    changedRelation(data);
                }
            );

            ContextualPopup.hideHourglass();
            ContextualPopup.hourglass = jQuery(e).hourglass()[0];

            //entering mouse on the hourglass should no close popup
            jQuery(ContextualPopup.hourglass.ele).bind('mouseenter', function(ev) {
                popup.element.trigger('mouseenter');
            });

            // so mousing over hourglass doesn't make ctxpopup think mouse is outside
            ContextualPopup.hourglass.element.addClass('lj_hourglass');

            return false;
        },

        // create a little popup to notify the user of something
        showNote: function (note, ele) {
            ele = ele || popup.element[0];
            LJ_IPPU.showNote(note, ele);
        },

        cleanCache: function(keys) {
            var self = this;

            keys = keys || [];
            if (typeof keys === 'string') {
                keys = [ keys ];
            }

            keys.forEach(function(key) {
                if (self.cachedResults[key]) {
                    delete self.cachedResults[key];
                }
            });
        },

        // do ajax request of user info
        getInfo: function(target, popup_id) {
            var t = this;
            if (t.currentRequests[popup_id]) {
                return;
            }
            t.currentRequests[popup_id] = 1;

            var reqParams = {
                user: target.username || ''
            };

            jQuery.ajax({
                url: LiveJournal.getAjaxUrl('ctxpopup'),
                data: Object.extend( reqParams, {
                    userid: target.userid || 0,
                    userpic_url: target.up_url || '',
                    mode: 'getinfo'
                }),
                dataType: 'json',
                success: function(data)
                {
                    if (data.error) {
                        data.username = reqParams.user;
                        t.cachedResults[data.username] = data;
                        popup.hide(true);
                        t.showNote(data.error, target);
                        return;
                    }

                    if( target.posted_in ) {
                        data.posted_in = target.posted_in;
                    }

                    t.cachedResults[String(data.userid)] =
                    t.cachedResults[data.username] =
                    t.cachedResults[data.url_userpic] = data;

                    // non default userpic
                    if (target.up_url) {
                        t.cachedResults[target.up_url] = data;
                    }

                    t.currentRequests[popup_id] = null;

                    if (t.currentId === popup_id) {
                        t.renderPopup(popup_id);
                    }
                },
                error: function()
                {
                    t.currentRequests[popup_id] = null;
                }
            });
        },

        hideHourglass: function () {
            if (this.hourglass) {
                this.hourglass.hide();
                this.hourglass = null;
            }
        }
    };

    // Update changing relations functionality to work through relations manager
    // that is declared in `js/relations.js`
    if ( LJ.Flags.isEnabled('friendsAndSubscriptions') ) {

        // redeclare `changeRelation` method to interact with relations manager
        ContextualPopup.changeRelation = function (info, ctxPopupId, action, e) {
            LiveJournal.run_hook('relations.change', {
                action: action,
                username: info.username
            });

            // hide existed hourglass and add another one
            ContextualPopup.hideHourglass();

            ContextualPopup.hourglass = new Hourglass()
                .setEvent(e)
                .show();

            ContextualPopup.hourglass.element
                // entering mouse on the hourglass should not close popup
                .on('mouseenter', function () {
                    popup.element.trigger('mouseenter');
                })
                // so mousing over hourglass doesn't make ctxpopup think mouse is outside
                .addClass('lj_hourglass');

            return false;
        };

        // subscribe to change relation events
        (function () {
            LiveJournal.register_hook('relations.changed', function (eventData) {
                var data = eventData.data,
                    username = eventData.username;

                ContextualPopup.hideHourglass();

                if (data.error) {
                    ContextualPopup.showNote(data.error.message);
                    return;
                }

                if ( ContextualPopup.cachedResults[username] ) {
                    $.extend(ContextualPopup.cachedResults[username], data);
                }

                // if the popup is up, reload it
                ContextualPopup.renderPopup(username);
            });
        }());
    }

}(jQuery));
