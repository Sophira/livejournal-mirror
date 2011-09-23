use strict;
package LJ::S2;

use LJ::DelayedEntry;
use LJ::UserApps;

sub RecentPage
{
    my ($u, $remote, $opts) = @_;

    # specify this so that the Page call will add in openid information.
    # this allows us to put the tags early in the <head>, before we start
    # adding other head_content here.
    $opts->{'addopenid'} = 1;

    # and ditto for RSS feeds, otherwise we show RSS feeds for the journal
    # on other views ... kinda confusing
    $opts->{'addfeeds'} = 1;

    my $p = Page($u, $opts);
    $p->{'_type'} = "RecentPage";
    $p->{'view'} = "recent";
    $p->{'entries'} = [];
    $p->{'head_content'}->set_object_type( $p->{'_type'} );

    my $user = $u->{'user'};
    my $journalbase = LJ::journal_base($user, $opts->{'vhost'});

    my $datalink = sub {
        my ($what, $caption) = @_;
        return Link($p->{'base_url'} . "/data/$what" . ($opts->{tags} ? "?tag=".join(",", map({ LJ::eurl($_) } @{$opts->{tags}})) : ""),
                    $caption,
                    Image("$LJ::IMGPREFIX/data_$what.gif", 32, 15, $caption));
    };

    if ( $opts->{'tagids'} ) {
        $p->{'page_id'} = 'journal-' . $u->username . '-tags-' . $opts->{'tagmode'} . '-' . join( '-', @{ $opts->{'tagids'} } );
    }

    $p->{'data_link'} = {
        'rss' => $datalink->('rss', 'RSS'),
        'atom' => $datalink->('atom', 'Atom'),
    };
    $p->{'data_links_order'} = [ qw(rss atom) ];

    LJ::load_user_props($remote, "opt_nctalklinks", "opt_ljcut_disable_lastn");

    my $get = $opts->{'getargs'};

    if ($opts->{'pathextra'}) {
        $opts->{'badargs'} = 1;
        return 1;
    }
    
    my $itemshow = S2::get_property_value($opts->{'ctx'}, "page_recent_items")+0;
    if ($itemshow < 1) { $itemshow = 20; }
    elsif ($itemshow > 50 && !$LJ::S2_TRUSTED{ $u->{'userid'} } ) { $itemshow = 50; }

    my $skip = $get->{'skip'}+0;
    my $maxskip = $LJ::MAX_SCROLLBACK_LASTN-$itemshow;
    if ($skip < 0) { $skip = 0; }
    if ($skip > $maxskip) { $skip = $maxskip; }

    # do they want to view all entries, regardless of security?
    my $viewall = 0;
    my $viewsome = 0;
    if ($get->{'viewall'} && LJ::check_priv($remote, "canview", "suspended")) {
        LJ::statushistory_add($u->{'userid'}, $remote->{'userid'},
                              "viewall", "lastn: $user, statusvis: $u->{'statusvis'}");
        $viewall = LJ::check_priv($remote, 'canview', '*');
        $viewsome = $viewall || LJ::check_priv($remote, 'canview', 'suspended');
    }

    my $delayed_entries = [];
    my $delayed_entries_count = LJ::DelayedEntry->get_entries_count($u);
    my $usual_skip = $delayed_entries_count ? $skip - $delayed_entries_count : 0;

    if ( $u->has_sticky_entry && !$skip) {
        $delayed_entries = LJ::DelayedEntry->get_entries_by_journal($u, $skip, $itemshow - 1) ;
    } elsif ( $u->has_sticky_entry && $skip) {
        $delayed_entries = LJ::DelayedEntry->get_entries_by_journal($u, $skip - 1, $itemshow + 1);
    } else {
        $delayed_entries = LJ::DelayedEntry->get_entries_by_journal($u, $skip, $itemshow + 1);
    }

    if (!$delayed_entries) {
        $delayed_entries = [];
    }

    if ( $skip && $usual_skip < 0 && $u->has_sticky_entry ) {
        $usual_skip = 1;
    } elsif ( $skip && $usual_skip < 0 ) {
        $usual_skip = 0;
    }

    my $itemshow_usual = $itemshow - scalar(@$delayed_entries);
    if ( $itemshow <= scalar(@$delayed_entries) ) {
            $itemshow_usual -= 1;
    }

    ## load the itemids
    my @itemids;
    my $err;
    my @items = LJ::get_recent_items({
        'clusterid' => $u->{'clusterid'},
        'clustersource' => 'slave',
        'viewall' => $viewall,
        'viewsome' => $viewsome,
        'userid' => $u->{'userid'},
        'remote' => $remote,
        'itemshow' => $itemshow_usual + 1,
        'skip' => $usual_skip,
        'tagids' => $opts->{tagids},
        'tagmode' => $opts->{tagmode},
        'security' => $opts->{'securityfilter'},
        'itemids' => \@itemids,
        'dateformat' => 'S2',
        'order' => ($u->{'journaltype'} eq "C" || $u->{'journaltype'} eq "Y")  # community or syndicated
            ? "logtime" : "",
        'err' => \$err,
        'poster'  => $get->{'poster'} || '',
        'show_sticky_on_top' => !$skip,
    }) if ($itemshow_usual >= 0) ;
    
    my $is_prev_exist = scalar @items + scalar(@$delayed_entries) - $itemshow > 0 ? 1 : 0;
    if ($is_prev_exist) {
        if ( scalar(@$delayed_entries) > $itemshow ) {
            pop @$delayed_entries;
        } elsif ( scalar(@items) + scalar(@$delayed_entries) > $itemshow ) {
            pop @items if scalar(@items);
        }
    }

    die $err if $err;

    ### load the log properties
    my %logprops = ();
    my $logtext;
    LJ::load_log_props2($u->{'userid'}, \@itemids, \%logprops);
    $logtext = LJ::get_logtext2($u, @itemids);

    my $lastdate = "";
    my $itemnum = 0;
    my $lastentry = undef;

    my (%apu, %apu_lite);  # alt poster users; UserLite objects
    foreach (@items) {
        next unless $_->{'posterid'} != $u->{'userid'};
        $apu{$_->{'posterid'}} = undef;
    }
    if (%apu) {
        LJ::load_userids_multiple([map { $_, \$apu{$_} } keys %apu], [$u]);
        $apu_lite{$_} = UserLite($apu{$_}) foreach keys %apu;
    }

    # load tags
    my $idsbyc = { $u->{clusterid} => [ ] };
    push @{$idsbyc->{$u->{clusterid}}}, [ $u->{userid}, $_->{itemid} ]
        foreach @items;
    my $tags = LJ::Tags::get_logtagsmulti($idsbyc);

    my $userlite_journal = UserLite($u);
    my $sticky_appended = !$u->has_sticky_entry() || $skip;

    if ( scalar(@$delayed_entries) > 0 && \
        ( $skip && $u->has_sticky_entry()) || 
         !$u->has_sticky_entry()) {
        __append_delayed( $u, $delayed_entries,  $p->{'entries'} );
    }
    
  ENTRY:
    foreach my $item (@items)
    {
        my ($posterid, $itemid, $security, $allowmask, $alldatepart) =
            map { $item->{$_} } qw(posterid itemid security allowmask alldatepart);

        my $ditemid = $itemid * 256 + $item->{'anum'};
        my $entry_obj = LJ::Entry->new($u, ditemid => $ditemid);
        
        # append delayed entries
        if ( $entry_obj->is_sticky() && $sticky_appended) {
            __append_delayed( $u, $delayed_entries,  $p->{'entries'});
            $sticky_appended = 1;
        }
        
        next ENTRY unless $entry_obj->visible_to($remote, {'viewall' => $viewall, 'viewsome' => $viewsome});

        $entry_obj->handle_prefetched_props($logprops{$itemid});
        my $replycount = $logprops{$itemid}->{'replycount'};
        my $subject = $logtext->{$itemid}->[0];
        my $text = $logtext->{$itemid}->[1];
        if ($get->{'nohtml'}) {
            # quote all non-LJ tags
            $subject =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
            $text    =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
        }

        $itemnum++;

        if ($LJ::UNICODE && $logprops{$itemid}->{'unknown8bit'}) {
            LJ::item_toutf8($u, \$subject, \$text, $logprops{$itemid});
        }

        my $date = substr($alldatepart, 0, 10);
        my $new_day = 0;
        if ($date ne $lastdate) {
            $new_day = 1;
            $lastdate = $date;
            $lastentry->{'end_day'} = 1 if $lastentry;
        }

        LJ::CleanHTML::clean_subject(\$subject) if $subject;

        my $suspend_msg = $entry_obj && $entry_obj->should_show_suspend_msg_to($remote) ? 1 : 0;
        LJ::CleanHTML::clean_event(\$text, { 'preformatted' => $logprops{$itemid}->{'opt_preformatted'},
                                              'cuturl' => $entry_obj->prop('reposted_from') || $entry_obj->url,
                                              'entry_url' => $entry_obj->prop('reposted_from') || $entry_obj->url,
                                              'ljcut_disable' => ($remote) ? $remote->prop("opt_ljcut_disable_lastn") : undef,
                                              'suspend_msg' => $suspend_msg,
                                              'unsuspend_supportid' => $suspend_msg ? $entry_obj->prop("unsuspend_supportid") : 0,
                                              'journalid' => $entry_obj->journalid,
                                              'posterid' => $entry_obj->posterid,
                                           });
        LJ::expand_embedded($u, $ditemid, $remote, \$text);

        $text = LJ::ContentFlag->transform_post(post => $text, journal => $u,
                                                remote => $remote, entry => $entry_obj);

        my @taglist;
        while (my ($kwid, $kw) = each %{$tags->{"$u->{userid} $itemid"} || {}}) {
            push @taglist, Tag($u, $kwid => $kw);
        }
        LJ::run_hooks('augment_s2_tag_list', u => $u, jitemid => $itemid, tag_list => \@taglist);
        @taglist = sort { $a->{name} cmp $b->{name} } @taglist;

        if ($opts->{enable_tags_compatibility} && @taglist) {
            $text .= LJ::S2::get_tags_text($opts->{ctx}, \@taglist);
        }

        my $nc = "";
        $nc .= "nc=$replycount" if $replycount && $remote && $remote->prop('opt_nctalklinks');

        my $permalink = "$journalbase/$ditemid.html";
        my $readurl = $permalink;
        $readurl .= "?$nc" if $nc;
        my $posturl = $permalink . "?mode=reply";

        my $has_screened = ($logprops{$itemid}->{'hasscreened'} && $remote && $remote->can_manage($u)) ? 1 : 0;

        my $comments = CommentInfo({
            'read_url' => $readurl,
            'post_url' => $posturl,
            'count' => $replycount,
            'maxcomments' => ($replycount >= LJ::get_cap($u, 'maxcomments')) ? 1 : 0,
            'enabled' => $entry_obj->comments_shown,
            'locked' => !$entry_obj->posting_comments_allowed,
            'screened' => $has_screened,
            'show_readlink' => $entry_obj->comments_shown && ($replycount || $has_screened),
            'show_postlink' => $entry_obj->posting_comments_allowed,
        });

        my $userlite_poster = $userlite_journal;
        my $pu = $u;
        if ($u->{'userid'} != $posterid) {
            $userlite_poster = $apu_lite{$posterid} or die "No apu_lite for posterid=$posterid";
            $pu = $apu{$posterid};
        }
        my $pickw = LJ::Entry->userpic_kw_from_props($logprops{$itemid});
        my $userpic = Image_userpic($pu, 0, $pickw);

        if ($security eq "public" && !$LJ::REQ_GLOBAL{'text_of_first_public_post'}) {
            $LJ::REQ_GLOBAL{'text_of_first_public_post'} = $text;

            if (@taglist) {
                $LJ::REQ_GLOBAL{'tags_of_first_public_post'} = [map { $_->{name} } @taglist];
            }
        }

        my $entry = $lastentry = Entry($u, {
            'subject' => $subject,
            'text' => $text,
            'dateparts' => $alldatepart,
            'system_dateparts' => $item->{system_alldatepart},
            'security' => $security,
            'allowmask' => $allowmask,
            'props' => $logprops{$itemid},
            'itemid' => $ditemid,
            'journal' => $userlite_journal,
            'poster' => $userlite_poster,
            'comments' => $comments,
            'new_day' => $new_day,
            'end_day' => 0,   # if true, set later
            'tags' => \@taglist,
            'userpic' => $userpic,
            'permalink_url' => $permalink,
        });
        
        push @{$p->{'entries'}}, $entry;
        LJ::run_hook('notify_event_displayed', $entry_obj);

        # append delayed entries
        if ( !$sticky_appended) {
            __append_delayed( $u, $delayed_entries,  $p->{'entries'});
            $sticky_appended = 1;
        }
        
    } # end huge while loop

    # mark last entry as closing.
    $p->{'entries'}->[-1]->{'end_day'} = 1 if @{$p->{'entries'} || []};

    #### make the skip links
    my $nav = {
        '_type' => 'RecentNav',
        'version' => 1,
        'skip' => $skip,
        'count' => $itemnum,
    };
 
    # if we've skipped down, then we can skip back up
    if ($skip) {
        my $newskip = $skip - $itemshow;
        $newskip = 0 if $newskip <= 0;
        $nav->{'forward_skip'} = $newskip;
        $nav->{'forward_url'} = LJ::make_link("$p->{base_url}/", { 
            skip     => ($newskip                   || ""),
            tag      => (LJ::eurl($get->{tag})      || ""),
            security => (LJ::eurl($get->{security}) || ""),
            mode     => (LJ::eurl($get->{mode})     || ""), 
            poster   => (LJ::eurl($get->{'poster'}) || ""),
        });
        $nav->{'forward_count'} = $itemshow;
    }

    # unless we didn't even load as many as we were expecting on this
    # page, then there are more (unless there are exactly the number shown
    # on the page, but who cares about that)
    unless (scalar(@items) + scalar(@$delayed_entries) != $itemshow) {
        $nav->{'backward_count'} = $itemshow;
        if ($skip == $maxskip) {
            my $date_slashes = $lastdate;  # "yyyy mm dd";
            $date_slashes =~ s! !/!g;
            $nav->{'backward_url'} = "$p->{'base_url'}/$date_slashes";
        } elsif ($is_prev_exist) {
            my $newskip = $skip + $itemshow;
            $nav->{'backward_url'} = LJ::make_link("$p->{'base_url'}/", { 
                skip     => ($newskip                   || ""),
                tag      => (LJ::eurl($get->{tag})      || ""),
                security => (LJ::eurl($get->{security}) || ""),
                mode     => (LJ::eurl($get->{mode})     || ""), 
                poster   => (LJ::eurl($get->{'poster'}) || ""),
            });
            $nav->{'backward_skip'} = $newskip;
        }
    }

    $p->{'nav'} = $nav;
    return $p;
}

sub __append_delayed {
    my ( $u, $delayed, $entries) = @_;
    
    foreach my $delayedid  (@$delayed) {
        my $delayed_entry = LJ::DelayedEntry->get_entry_by_id(  $u, 
                                                                $delayedid, 
                                                                { dateformat => 'S2' } );
        my $permalink = $delayed_entry->url;
        my $readurl = $permalink;
        my $posturl = $permalink;
        
        my $comments = CommentInfo({
            'read_url' => $readurl,
            'post_url' => $posturl,
            'count' => 0,
            'maxcomments' => 0,
            'enabled' => $delayed_entry->comments_shown,
            'locked' => !$delayed_entry->posting_comments_allowed,
            'screened' => 0,
            'show_readlink' => 0,
            'show_postlink' => 0,
        });
        
        my $entry_tags =  $delayed_entry->get_tags;
        $entry_tags = $entry_tags->{$delayed_entry->delayedid} if $entry_tags;
        
        my @tags = (); 
        if ($entry_tags) {
            my @keys = keys %$entry_tags;
            foreach my $key (@keys) {
                push @tags, Tag($delayed_entry->journal, $key => $entry_tags->{$key});
            }
        }
        
        my $entry = Entry($delayed_entry->journal, {
            'subject' => $delayed_entry->subject,
            'text' =>  $delayed_entry->event,
            'dateparts' => $delayed_entry->alldatepart,
            'system_dateparts' => $delayed_entry->system_alldatepart,
            'security' => $delayed_entry->security || 0,
            'allowmask' => $delayed_entry->allowmask || 0,
            'journal' => UserLite($delayed_entry->journal),
            'poster' => UserLite($delayed_entry->poster),
            'comments' => $comments,
            'new_day' => 1,
            'end_day' => 0,   # if true, set later
            'tags' => \@tags,
            'userpic' => $delayed_entry->userpic,
            'permalink_url' => "d$delayedid.html",
            'sticky' => $delayed_entry->is_sticky,
            'delayedid' => $delayed_entry->delayedid,
        });
        
        push @$entries, $entry;
    }
}


1;

