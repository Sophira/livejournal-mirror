#!/usr/bin/perl
#

use strict;
package LJ::S2;

sub FriendsPage
{
    my ($u, $remote, $opts) = @_;

    my $p = Page($u, $opts);
    $p->{'_type'} = "FriendsPage";
    $p->{'view'} = "friends";
    $p->{'entries'} = [];
    $p->{'friends'} = {};
    $p->{'friends_title'} = LJ::ehtml($u->{'friendspagetitle'});

    my $dbs = LJ::get_dbs();
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $sth;
    my $user = $u->{'user'};

    # see how often the remote user can reload this page.  
    # "friendsviewupdate" time determines what granularity time
    # increments by for checking for new updates
    my $nowtime = time();

    # update delay specified by "friendsviewupdate"
    my $newinterval = LJ::get_cap_min($remote, "friendsviewupdate") || 1;

    # when are we going to say page was last modified?  back up to the 
    # most recent time in the past where $time % $interval == 0
    my $lastmod = $nowtime;
    $lastmod -= $lastmod % $newinterval;

    # see if they have a previously cached copy of this page they
    # might be able to still use.
    if ($opts->{'header'}->{'If-Modified-Since'}) {
        my $theirtime = LJ::http_to_time($opts->{'header'}->{'If-Modified-Since'});

        # send back a 304 Not Modified if they say they've reloaded this 
        # document in the last $newinterval seconds:
        unless ($theirtime < $lastmod) {
            $opts->{'status'} = "304 Not Modified";
            $opts->{'nocontent'} = 1;
            return 1;
        }
    }
    $opts->{'headers'}->{'Last-Modified'} = LJ::time_to_http($lastmod);

    my %FORM = ();
    LJ::decode_url_string($opts->{'args'}, \%FORM);

    my $ret;

    if ($FORM{'mode'} eq "live") {
        $ret .= "<html><head><title>${user}'s friends: live!</title></head>\n";
        $ret .= "<frameset rows=\"100%,0%\" border=0>\n";
        $ret .= "  <frame name=livetop src=\"friends?mode=framed\">\n";
        $ret .= "  <frame name=livebottom src=\"friends?mode=livecond&amp;lastitemid=0\">\n";
        $ret .= "</frameset></html>\n";
        return $ret;
    }

    if ($u->{'journaltype'} eq "R" && $u->{'renamedto'} ne "") {
        $opts->{'redir'} = LJ::journal_base($u->{'renamedto'}, $opts->{'vhost'}) . "/friends";
        return 1;
    }

    LJ::load_user_props($dbs, $remote, "opt_nctalklinks");

    ## never have spiders index friends pages (change too much, and some 
    ## people might not want to be indexed)
    $p->{'head_content'} .= LJ::robot_meta_tags();

    my $itemshow = S2::get_property_value($opts->{'ctx'}, "page_friends_items")+0;
    if ($itemshow < 1) { $itemshow = 20; }
    elsif ($itemshow > 50) { $itemshow = 50; }
    
    my $skip = $FORM{'skip'}+0;
    my $maxskip = ($LJ::MAX_SCROLLBACK_FRIENDS || 1000) - $itemshow;
    if ($skip > $maxskip) { $skip = $maxskip; }
    if ($skip < 0) { $skip = 0; }
    my $itemload = $itemshow+$skip;

    my %owners;
    my $filter;
    my $group;
    my $common_filter = 1;

    if (defined $FORM{'filter'} && $remote && $remote->{'user'} eq $user) {
        $filter = $FORM{'filter'}; 
        $common_filter = 0;
    } else {
        if ($opts->{'pathextra'}) {
            $group = $opts->{'pathextra'};
            $group =~ s!^/!!;
            $group =~ s!/$!!;
            if ($group) { $group = LJ::durl($group); $common_filter = 0; }
        }
        my $qgroup = $dbr->quote($group || "Default View");
        my ($bit, $public) = $dbr->selectrow_array("SELECT groupnum, is_public " .
            "FROM friendgroup WHERE userid=$u->{'userid'} AND groupname=$qgroup");
        if ($bit && ($public || ($remote && $remote->{'user'} eq $user))) { 
            $filter = (1 << $bit); 
        }
    }

    if ($FORM{'mode'} eq "livecond") 
    {
        ## load the itemids
        my @items = LJ::get_friend_items($dbs, {
            'u' => $u,
            'userid' => $u->{'userid'},
            'remote' => $remote,
            'itemshow' => 1,
            'skip' => 0,
            'filter' => $filter,
            'common_filter' => $common_filter,
        });
        my $first = @items ? $items[0]->{'itemid'} : 0;

        $ret .= "time = " . scalar(time()) . "<br />";
        $opts->{'headers'}->{'Refresh'} = "30;URL=$LJ::SITEROOT/users/$user/friends?mode=livecond&lastitemid=$first";
        if ($FORM{'lastitemid'} == $first) {
            $ret .= "nothing new!";
        } else {
            if ($FORM{'lastitemid'}) {
                $ret .= "<b>New stuff!</b>\n";
                $ret .= "<script language=\"JavaScript\">\n";
                $ret .= "window.parent.livetop.location.reload(true);\n";	    
                $ret .= "</script>\n";
                $opts->{'trusted_html'} = 1;
            } else {
                $ret .= "Friends Live! started.";
            }
        }
        return $ret;
    }
    
    ## load the itemids 
    my %idsbycluster;
    my @items = LJ::get_friend_items($dbs, {
        'u' => $u,
        'userid' => $u->{'userid'},
        'remote' => $remote,
        'itemshow' => $itemshow,
        'skip' => $skip,
        'filter' => $filter,
        'common_filter' => $common_filter,
        'owners' => \%owners,
        'idsbycluster' => \%idsbycluster,
        'showtypes' => $FORM{'show'},
        'friendsoffriends' => $opts->{'view'} eq "friendsfriends",
        'dateformat' => 'S2',
    });

    my $ownersin = join(",", keys %owners);

    my %friends = ();
    unless ($opts->{'view'} eq "friendsfriends") {
        $sth = $dbr->prepare("SELECT u.user, u.userid, u.clusterid, f.fgcolor, f.bgcolor, u.name, u.defaultpicid, u.opt_showtalklinks, u.moodthemeid, u.statusvis, u.oldenc, u.journaltype FROM friends f, user u WHERE u.userid=f.friendid AND f.userid=$u->{'userid'} AND f.friendid IN ($ownersin)");
    } else {
        $sth = $dbr->prepare("SELECT u.user, u.userid, u.clusterid, u.name, u.defaultpicid, u.opt_showtalklinks, u.moodthemeid, u.statusvis, u.oldenc, u.journaltype FROM user u WHERE u.userid IN ($ownersin)");
    }
    

    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
        next unless ($_->{'statusvis'} eq "V");  # ignore suspended/deleted users.
        $_->{'fgcolor'} = LJ::color_fromdb($_->{'fgcolor'}) || "#000000";
        $_->{'bgcolor'} = LJ::color_fromdb($_->{'bgcolor'}) || "#ffffff";
        $friends{$_->{'userid'}} = $_;
    }

    return $p unless %friends;

    ### load the log properties
    my %logprops = ();  # key is "$owneridOrZero $[j]itemid"
    LJ::load_props($dbs, "log");
    LJ::load_log_props2multi($dbs, \%idsbycluster, \%logprops);
    LJ::load_moods($dbs);

    # load the text of the entries
    my $logtext = LJ::get_logtext2multi($dbs, \%idsbycluster);
  
    my %posters;
    {
        my @posterids;
        foreach my $item (@items) {
            next if $friends{$item->{'posterid'}};
            push @posterids, $item->{'posterid'};
        }
        LJ::load_userids_multiple($dbs, [ map { $_ => \$posters{$_} } @posterids ])
            if @posterids;
    }

    my %objs_of_picid;
    
    my %lite;   # posterid -> s2_UserLite
    my $get_lite = sub {
        my $id = shift;
        return $lite{$id} if $lite{$id};
        return $lite{$id} = UserLite($posters{$id} || $friends{$id});
    };
    
    my $eventnum = 0;
  ENTRY:
    foreach my $item (@items) 
    {
        my ($friendid, $posterid, $itemid, $security, $alldatepart, $replycount) = 
            map { $item->{$_} } qw(ownerid posterid itemid security alldatepart replycount);

        my $fr = $friends{$friendid};
        $p->{'friends'}->{$fr->{'user'}} ||= Friend($fr);

        my $clusterid = $item->{'clusterid'}+0;
        my $datakey = "$friendid $itemid";
            
        my $subject = $logtext->{$datakey}->[0];
        my $text = $logtext->{$datakey}->[1];
        if ($FORM{'nohtml'}) {
            # quote all non-LJ tags
            $subject =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
            $text    =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
        }

        if ($LJ::UNICODE && $logprops{$datakey}->{'unknown8bit'}) {
            LJ::item_toutf8($dbs, $friends{$friendid}, \$subject, \$text, $logprops{$datakey});
        }

        my ($friend, $poster);
        $friend = $poster = $friends{$friendid}->{'user'};

        $eventnum++;
        LJ::CleanHTML::clean_subject(\$subject) if $subject;

        my $ditemid = $itemid * 256 + $item->{'anum'};

        LJ::CleanHTML::clean_event(\$text, { 'preformatted' => $logprops{$datakey}->{'opt_preformatted'},
                                               'cuturl' => LJ::item_link($friends{$friendid}, $itemid, $item->{'anum'}), });
        LJ::expand_embedded($dbs, $ditemid, $remote, \$text);

        my $userlite_poster = $get_lite->($posterid);
        my $userlite_journal = $get_lite->($friendid);

        # get the poster user
        my $po = $posters{$posterid} || $friends{$posterid};  

        # don't allow posts from suspended users
        next ENTRY if $po->{'statusvis'} eq 'S';

        # do the picture
        my $picid = 0;
        {
            $picid = $friends{$friendid}->{'defaultpicid'};  # this could be the shared journal pic
            if ($friendid != $posterid && ! $u->{'opt_usesharedpic'}) {
                $picid = $po->{'defaultpicid'};
            }
            if ($logprops{$datakey}->{'picture_keyword'} && 
                (! $u->{'opt_usesharedpic'} || $posterid == $friendid))
            {
                my $sth = $dbr->prepare("SELECT m.picid FROM userpicmap m, keywords k ".
                                        "WHERE m.userid=$posterid AND m.kwid=k.kwid AND k.keyword=?");
                $sth->execute($logprops{$datakey}->{'picture_keyword'});
                $picid = $sth->fetchrow_array;
            }
        }

        my $nc = "";
        $nc .= "nc=$replycount" if $replycount && $remote && $remote->{'opt_nctalklinks'};

        my $journalbase = LJ::journal_base($friends{$friendid});
        my $permalink = "$journalbase/$ditemid.html";
        my $readurl = $permalink;
        $readurl .= "?$nc" if $nc;
        my $posturl = $permalink . "?mode=reply";

        my $comments = CommentInfo({
            'read_url' => $readurl,
            'post_url' => $posturl,
            'count' => $replycount,
            'enabled' => ($friends{$friendid}->{'opt_showtalklinks'} eq "Y" && ! $logprops{$datakey}->{'opt_nocomments'}) ? 1 : 0,
            'screened' => ($logprops{$itemid}->{'hasscreened'} && ($remote->{'user'} eq $u->{'user'}|| LJ::check_rel($dbs, $u, $remote, 'A'))) ? 1 : 0,
        });

        my $moodthemeid = $u->{'opt_forcemoodtheme'} eq 'Y' ?
            $u->{'moodthemeid'} : $friends{$friendid}->{'moodthemeid'};

        my $entry = Entry($u, {
            'subject' => $subject,
            'text' => $text,
            'dateparts' => $alldatepart,
            'security' => $security,
            'props' => $logprops{$datakey},
            'itemid' => $ditemid,
            'journal' => $userlite_journal,
            'poster' => $userlite_poster,
            'comments' => $comments,
            'new_day' => 0,  # TODO: implement? is ugly on friends pages when timezones bounce around
            'end_day' => 0,  # TODO: implement? is ugly on friends pages when timezones bounce around
            'userpic' => undef,
            'permalink_url' => $permalink,
            'moodthemeid' => $moodthemeid,
        });

        if ($picid) { 
            push @{$objs_of_picid{$picid}}, \$entry->{'userpic'};
        }

        push @{$p->{'entries'}}, $entry;
        
    } # end while

    # load the pictures that were referenced, then retroactively populate
    # the userpic fields of the Entries above
    my %userpics;
    LJ::load_userpics($dbs, \%userpics, [ keys %objs_of_picid ]);
    foreach my $picid (keys %userpics) {
        my $up = Image("$LJ::USERPIC_ROOT/$picid/$userpics{$picid}->{'userid'}",
                       $userpics{$picid}->{'width'},
                       $userpics{$picid}->{'height'});
        foreach (@{$objs_of_picid{$picid}}) { $$_ = $up; }
    }

    # make the skip links
    my $nav = {
        '_type' => 'RecentNav',
        'version' => 1,
        'skip' => $skip,
    };

    my $base = "$u->{'_journalbase'}/$opts->{'view'}";
    if ($group) {
        $base .= "/" . LJ::eurl($group);
    }

    # $linkfilter is distinct from $filter: if user has a default view,
    # $filter is now set according to it but we don't want it to show in the links.
    # $incfilter may be true even if $filter is 0: user may use filter=0 to turn
    # off the default group
    my $linkfilter = $FORM{'filter'} + 0;
    my $incfilter = defined $FORM{'filter'};

    # if we've skipped down, then we can skip back up
    if ($skip) {
        my %linkvars;
        $linkvars{'filter'} = $linkfilter if $incfilter;
        $linkvars{'show'} = $FORM{'show'} if $FORM{'show'} =~ /^\w+$/;
        my $newskip = $skip - $itemshow;
        if ($newskip > 0) { $linkvars{'skip'} = $newskip; }
        else { $newskip = 0; }
        $nav->{'forward_url'} = LJ::make_link($base, \%linkvars);
        $nav->{'forward_skip'} = $newskip;
        $nav->{'forward_count'} = $itemshow;
    }

    ## unless we didn't even load as many as we were expecting on this
    ## page, then there are more (unless there are exactly the number shown 
    ## on the page, but who cares about that)
    unless ($eventnum != $itemshow || $skip == $maxskip) {
        my %linkvars;
        $linkvars{'filter'} = $linkfilter if $incfilter;
        $linkvars{'show'} = $FORM{'show'} if $FORM{'show'} =~ /^\w+$/;
        my $newskip = $skip + $itemshow;
        $linkvars{'skip'} = $newskip;
        $nav->{'backward_url'} = LJ::make_link($base, \%linkvars);
        $nav->{'backward_skip'} = $newskip;
        $nav->{'backward_count'} = $itemshow;
    }

    $p->{'nav'} = $nav;

    if ($FORM{'mode'} eq "framed") {
        $p->{'head_content'} .= "<base target='_top' />";
    }

    return $p;
}

1;
