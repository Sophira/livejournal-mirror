#!/usr/bin/perl

package LJ::Feed;
use strict;

BEGIN {
    $LJ::OPTMOD_XMLATOM = eval q{
        use XML::Atom::Feed;
        use XML::Atom::Entry;
        use XML::Atom::Link;
        XML::Atom->VERSION < 0.09 ? 0 : 1;
    };
};

my %feedtypes = (
    rss  => \&create_view_rss,
    atom => \&create_view_atom,
    foaf => \&create_view_foaf,
);

sub make_feed
{
    my ($r, $u, $remote, $opts) = @_;

    $opts->{pathextra} =~ s!^/(\w+)!!;
    my $feedtype = $1;
    my $viewfunc = $feedtypes{$feedtype};

    unless ($viewfunc) {
        $opts->{'handler_return'} = 404;
        return undef;
    }

    $opts->{noitems} = 1 if $feedtype eq 'foaf';

    $r->notes('codepath' => "feed.$feedtype") if $r;

    my $dbr = LJ::get_db_reader();

    my $user = $u->{'user'};

    LJ::load_user_props($u, qw/ journaltitle journalsubtitle opt_synlevel /);

    LJ::text_out(\$u->{$_})
        foreach ("name", "url", "urlname");

    # opt_synlevel will default to 'full'
    $u->{'opt_synlevel'} = 'full'
        unless $u->{'opt_synlevel'} =~ /^(?:full|summary|title)$/;

    # some data used throughout the channel
    my $journalinfo = {
        u         => $u,
        link      => LJ::journal_base($u) . "/",
        title     => $u->{journaltitle} || $u->{name} || $u->{user},
        subtitle  => $u->{journalsubtitle} || $u->{name},
        builddate => LJ::time_to_http(time()),
    };

    # if we do not want items for this view, just call out
    return $viewfunc->($journalinfo, $u, $opts)
        if ($opts->{'noitems'});

    # for syndicated accounts, redirect to the syndication URL
    # However, we only want to do this if the data we're returning
    # is similar. (Not FOAF, for example)
    if ($u->{'journaltype'} eq 'Y') {
        my $synurl = $dbr->selectrow_array("SELECT synurl FROM syndicated WHERE userid=$u->{'userid'}");
        unless ($synurl) {
            return 'No syndication URL available.';
        }
        $opts->{'redir'} = $synurl;
        return undef;
    }

    ## load the itemids
    my @itemids;
    my @items = LJ::get_recent_items({
        'clusterid' => $u->{'clusterid'},
        'clustersource' => 'slave',
        'remote' => $remote,
        'userid' => $u->{'userid'},
        'itemshow' => 25,
        'order' => "logtime",
        'itemids' => \@itemids,
        'friendsview' => 1,           # this returns rlogtimes
        'dateformat' => "S2",         # S2 format time format is easier
    });

    $opts->{'contenttype'} = 'text/xml; charset='.$opts->{'saycharset'};

    ### load the log properties
    my %logprops = ();
    my $logtext;
    my $logdb = LJ::get_cluster_reader($u);
    LJ::load_log_props2($logdb, $u->{'userid'}, \@itemids, \%logprops);
    $logtext = LJ::get_logtext2($u, @itemids);

    # set last-modified header, then let apache figure out
    # whether we actually need to send the feed.
    my $lastmod = 0;
    foreach my $item (@items) {
        # revtime of the item.
        my $revtime = $logprops{$item->{itemid}}->{revtime};
        $lastmod = $revtime if $revtime > $lastmod;

        # if we don't have a revtime, use the logtime of the item.
        unless ($revtime) {
            my $itime = $LJ::EndOfTime - $item->{rlogtime};
            $lastmod = $itime if $itime > $lastmod;
        }
    }
    $r->set_last_modified($lastmod) if $lastmod;

    # use this $lastmod as the feed's last-modified time
    # we would've liked to use something like
    # LJ::get_timeupdate_multi instead, but that only changes
    # with new updates and doesn't change on edits.
    $journalinfo->{'modtime'} = $lastmod;

    # regarding $r->set_etag:
    # http://perl.apache.org/docs/general/correct_headers/correct_headers.html#Entity_Tags
    # It is strongly recommended that you do not use this method unless you
    # know what you are doing. set_etag() is expecting to be used in
    # conjunction with a static request for a file on disk that has been
    # stat()ed in the course of the current request. It is inappropriate and
    # "dangerous" to use it for dynamic content.
    if ((my $status = $r->meets_conditions) != Apache::Constants::OK()) {
        $opts->{handler_return} = $status;
        return undef;
    }

    # email address of journal owner, but respect their privacy settings
    if ($u->{'allow_contactshow'} eq "Y" && $u->{'opt_whatemailshow'} ne "N" && $u->{'opt_mangleemail'} ne "Y") {
        my $cemail;

        # default to their actual email
        $cemail = $u->{'email'};

        # use their livejournal email if they have one
        if ($LJ::USER_EMAIL && $u->{'opt_whatemailshow'} eq "L" &&
            LJ::get_cap($u, "useremail") && ! $u->{'no_mail_alias'}) {

            $cemail = "$u->{'user'}\@$LJ::USER_DOMAIN";
        }

        # clean it up since we know we have one now
        $journalinfo->{email} = $cemail;
    }

    # load tags now that we have no chance of jumping out early
    my $logtags = LJ::Tags::get_logtags($u, \@itemids);

    my %posteru = ();  # map posterids to u objects
    LJ::load_userids_multiple([map { $_->{'posterid'}, \$posteru{$_->{'posterid'}} } @items], [$u]);

    my @cleanitems;
  ENTRY:
    foreach my $it (@items)
    {
        # load required data
        my $itemid  = $it->{'itemid'};
        my $ditemid = $itemid*256 + $it->{'anum'};

        next ENTRY if $posteru{$it->{'posterid'}} && $posteru{$it->{'posterid'}}->{'statusvis'} eq 'S';

        if ($LJ::UNICODE && $logprops{$itemid}->{'unknown8bit'}) {
            LJ::item_toutf8($u, \$logtext->{$itemid}->[0],
                            \$logtext->{$itemid}->[1], $logprops{$itemid});
        }

        # see if we have a subject and clean it
        my $subject = $logtext->{$itemid}->[0];
        if ($subject) {
            $subject =~ s/[\r\n]/ /g;
            LJ::CleanHTML::clean_subject_all(\$subject);
        }

        # an HTML link to the entry. used if we truncate or summarize
        my $readmore = "<b>(<a href=\"$journalinfo->{link}$ditemid.html\">Read more ...</a>)</b>";

        # empty string so we don't waste time cleaning an entry that won't be used
        my $event = $u->{'opt_synlevel'} eq 'title' ? '' : $logtext->{$itemid}->[1];

        # clean the event, if non-empty
        my $ppid = 0;
        if ($event) {

            # users without 'full_rss' get their logtext bodies truncated
            # do this now so that the html cleaner will hopefully fix html we break
            unless (LJ::get_cap($u, 'full_rss')) {
                my $trunc = LJ::text_trim($event, 0, 80);
                $event = "$trunc $readmore" if $trunc ne $event;
            }

            LJ::CleanHTML::clean_event(\$event,
                                       { 'preformatted' => $logprops{$itemid}->{'opt_preformatted'} });

            # do this after clean so we don't have to about know whether or not
            # the event is preformatted
            if ($u->{'opt_synlevel'} eq 'summary') {

                # assume the first paragraph is terminated by two <br> or a </p>
                # valid XML tags should be handled, even though it makes an uglier regex
                if ($event =~ m!((<br\s*/?\>(</br\s*>)?\s*){2})|(</p\s*>)!i) {
                    # everything before the matched tag + the tag itself
                    # + a link to read more
                    $event = $` . $& . $readmore;
                }
            }

            if ($event =~ /<lj-poll-(\d+)>/) {
                my $pollid = $1;
                my $name = $dbr->selectrow_array("SELECT name FROM poll WHERE pollid=?",
                                                 undef, $pollid);

                if ($name) {
                    LJ::Poll::clean_poll(\$name);
                } else {
                    $name = "#$pollid";
                }

                $event =~ s!<lj-poll-$pollid>!<div><a href="$LJ::SITEROOT/poll/?id=$pollid">View Poll: $name</a></div>!g;
            }

            $ppid = $1
                if $event =~ m!<lj-phonepost journalid=['"]\d+['"] dpid=['"](\d+)['"] />!;
        }

        my $mood;
        if ($logprops{$itemid}->{'current_mood'}) {
            $mood = $logprops{$itemid}->{'current_mood'};
        } elsif ($logprops{$itemid}->{'current_moodid'}) {
            $mood = LJ::mood_name($logprops{$itemid}->{'current_moodid'}+0);
        }

        my $createtime = $LJ::EndOfTime - $it->{rlogtime};
        my $cleanitem = {
            itemid     => $itemid,
            ditemid    => $ditemid,
            subject    => $subject,
            event      => $event,
            createtime => $createtime,
            eventtime  => $it->{alldatepart},  # ugly: this is of a different format than the other two times.
            modtime    => $logprops{$itemid}->{revtime} || $createtime,
            comments   => ($logprops{$itemid}->{'opt_nocomments'} == 0),
            music      => $logprops{$itemid}->{'current_music'},
            mood       => $mood,
            ppid       => $ppid,
            tags       => [ values %{$logtags->{$itemid} || {}} ],
        };
        push @cleanitems, $cleanitem;
    }

    # fix up the build date to use entry-time
    $journalinfo->{'builddate'} = LJ::time_to_http($LJ::EndOfTime - $items[0]->{'rlogtime'}),

    return $viewfunc->($journalinfo, $u, $opts, \@cleanitems);
}

# the creator for the RSS XML syndication view
sub create_view_rss
{
    my ($journalinfo, $u, $opts, $cleanitems) = @_;

    my $ret;

    # header
    $ret .= "<?xml version='1.0' encoding='$opts->{'saycharset'}' ?>\n";
    $ret .= LJ::run_hook("bot_director", "<!-- ", " -->") . "\n";
    $ret .= "<rss version='2.0' xmlns:lj='http://www.livejournal.org/rss/lj/1.0/'>\n";

    # channel attributes
    $ret .= "<channel>\n";
    $ret .= "  <title>" . LJ::exml($journalinfo->{title}) . "</title>\n";
    $ret .= "  <link>$journalinfo->{link}</link>\n";
    $ret .= "  <description>" . LJ::exml("$journalinfo->{title} - $LJ::SITENAME") . "</description>\n";
    $ret .= "  <managingEditor>" . LJ::exml($journalinfo->{email}) . "</managingEditor>\n" if $journalinfo->{email};
    $ret .= "  <lastBuildDate>$journalinfo->{builddate}</lastBuildDate>\n";
    $ret .= "  <generator>LiveJournal / $LJ::SITENAME</generator>\n";
    # TODO: add 'language' field when user.lang has more useful information

    ### image block, returns info for their current userpic
    if ($u->{'defaultpicid'}) {
        my $pic = {};
        LJ::load_userpics($pic, [ $u, $u->{'defaultpicid'} ]);
        $pic = $pic->{$u->{'defaultpicid'}}; # flatten

        $ret .= "  <image>\n";
        $ret .= "    <url>$LJ::USERPIC_ROOT/$u->{'defaultpicid'}/$u->{'userid'}</url>\n";
        $ret .= "    <title>" . LJ::exml($journalinfo->{title}) . "</title>\n";
        $ret .= "    <link>$journalinfo->{link}</link>\n";
        $ret .= "    <width>$pic->{'width'}</width>\n";
        $ret .= "    <height>$pic->{'height'}</height>\n";
        $ret .= "  </image>\n\n";
    }

    my %posteru = ();  # map posterids to u objects
    LJ::load_userids_multiple([map { $_->{'posterid'}, \$posteru{$_->{'posterid'}} } @$cleanitems], [$u]);

    # output individual item blocks

    foreach my $it (@$cleanitems)
    {
        my $itemid = $it->{itemid};
        my $ditemid = $it->{ditemid};
        $ret .= "<item>\n";
        $ret .= "  <guid isPermaLink='true'>$journalinfo->{link}$ditemid.html</guid>\n";
        $ret .= "  <pubDate>" . LJ::time_to_http($it->{createtime}) . "</pubDate>\n";
        $ret .= "  <title>" . LJ::exml($it->{subject}) . "</title>\n" if $it->{subject};
        $ret .= "  <author>" . LJ::exml($journalinfo->{email}) . "</author>" if $journalinfo->{email};
        $ret .= "  <link>$journalinfo->{link}$ditemid.html</link>\n";
        # omit the description tag if we're only syndicating titles
        #   note: the $event was also emptied earlier, in make_feed
        unless ($u->{'opt_synlevel'} eq 'title') {
            $ret .= "  <description>" . LJ::exml($it->{event}) . "</description>\n";
        }
        if ($it->{comments}) {
            $ret .= "  <comments>$journalinfo->{link}$ditemid.html</comments>\n";
        }
        $ret .= "  <category>$_</category>\n" foreach map { LJ::exml($_) } @{$it->{tags} || []};
        # support 'podcasting' enclosures
        $ret .= LJ::run_hook( "pp_rss_enclosure",
                { userid => $u->{userid}, ppid => $it->{ppid} }) if $it->{ppid};
        # TODO: add author field with posterid's email address, respect communities
        $ret .= "  <lj:music>" . LJ::exml($it->{music}) . "</lj:music>\n" if $it->{music};
        $ret .= "  <lj:mood>" . LJ::exml($it->{mood}) . "</lj:mood>\n" if $it->{mood};
        $ret .= "</item>\n";
    }

    $ret .= "</channel>\n";
    $ret .= "</rss>\n";

    return $ret;
}


# the creator for the Atom view
# keys of $opts:
# single_entry - only output an <entry>..</entry> block. off by default
# apilinks - output AtomAPI links for posting a new entry or
#            getting/editing/deleting an existing one. off by default
# TODO: define and use an 'lj:' namespace
#
# TODO: Remove lines marked with 'COMPAT' - they are only present
# to allow backwards compatibility with atom parsers that are pre 0.6-draft.
# We create tags valid for 1.1-draft, but we want to be nice during
# atom's (and atom users) continuing transition.  1.0 parsers, according
# to spec, should NOT barf on unknown tags.
# * Where we can't be compatible, we use Atom 1.0. *
# http://www.ietf.org/internet-drafts/draft-ietf-atompub-format-11.txt
#
# TODO: When COMPAT lines are removed, change namespace to
# http://www.w3.org/2005/Atom  (this requires an XML::Atom update)
sub create_view_atom
{
    my ( $j, $u, $opts, $cleanitems ) = @_;
    my ( $feed, $xml );

    # AtomAPI interface path
    my $api = $opts->{'apilinks'} ? "$LJ::SITEROOT/interface/atom" :
                                    "$LJ::SITEROOT/users/$u->{user}/data/atom";

    my $make_link = sub {
        my ( $rel, $type, $href, $title ) = @_;
        my $link = XML::Atom::Link->new;
        $link->rel($rel);
        $link->type($type);
        $link->href($href);
        $link->title( LJ::exml($title) ) if $title;
        return $link;
    };

    my $author = XML::Atom::Person->new();
    $author->email( LJ::exml( $u->{'email'} ) ) if $u->{'email'};
    $author->name(  LJ::exml( $u->{'name'} ) );

    # feed information
    unless ($opts->{'single_entry'}) {
        $feed = XML::Atom::Feed->new();
        $xml  = $feed->{doc};

        $xml->insertBefore( $xml->createComment( LJ::run_hook("bot_director") ), $xml->documentElement());

        # attributes
        $feed->id( "urn:lj:$LJ::DOMAIN:atom1:$u->{user}" );
        $feed->title( LJ::exml( $j->{'title'} ) );
        if ( $j->{'subtitle'} ) {
            $feed->subtitle( LJ::exml( $j->{'subtitle'} ) );
            $feed->tagline(  LJ::exml( $j->{'subtitle'} ) ); # COMPAT
        }

        $feed->author( $author );
        $feed->add_link( $make_link->( 'alternate', 'text/html', $j->{'link'} ) );
        $feed->add_link(
            $make_link->(
                'self',
                $opts->{'apilinks'}
                ? ( 'application/x.atom+xml', "$api/feed" )
                : ( 'text/xml', $api )
            )
        );
        $feed->updated( LJ::time_to_w3c($j->{'modtime'}, 'Z') );
        $feed->modified( LJ::time_to_w3c($j->{'modtime'}, 'Z') );  # COMPAT

        # link to the AtomAPI version of this feed
        $feed->add_link(
            $make_link->(
                'service.feed',
                'application/x.atom+xml',
                ( $opts->{'apilinks'} ? "$api/feed" : $api ),
                $j->{'title'}
            )
        );

        $feed->add_link(
            $make_link->(
                'service.post',
                'application/x.atom+xml',
                "$api/post",
                'Create a new entry'
            )
        ) if $opts->{'apilinks'};
    }

    # output individual item blocks
    foreach my $it (@$cleanitems)
    {
        my $itemid = $it->{itemid};
        my $ditemid = $it->{ditemid};

        my $entry = XML::Atom::Entry->new();
        my $entry_xml = $entry->{doc};

        $entry->title( LJ::exml( $it->{'subject'} ) );
        $entry->id("urn:lj:$LJ::DOMAIN:atom1:$u->{user}:$ditemid");

        # author isn't required if it is in the main <feed>
        # only add author if we are in a single entry view, or
        # the journal entry isn't owned by the journal owner. (communities)
        if ( $opts->{'single_entry'} or $j->{'u'}->{'email'} ne $u->{'email'} ) {
            my $author = XML::Atom::Person->new();
            $author->email( LJ::exml( $j->{'u'}->{'email'} ) ) if $j->{'u'}->{'email'};
            $author->name(  LJ::exml( $j->{'u'}->{'name'} ) );
            $entry->author($author);
        }

        $entry->add_link(
            $make_link->( 'alternate', 'text/html', "$j->{'link'}$ditemid.html" )
        );

        $entry->add_link(
            $make_link->(
                'service.edit',      'application/x.atom+xml',
                "$api/edit/$itemid", 'Edit this post'
            )
          ) if $opts->{'apilinks'};

        my ($year, $mon, $mday, $hour, $min, $sec) = split(/ /, $it->{eventtime});
        my $event_date = sprintf "%04d-%02d-%02dT%02d:%02d:%02d",
                                 $year, $mon, $mday, $hour, $min, $sec;

        $entry->published( $event_date );
        $entry->issued(    $event_date );   # COMPAT

        $entry->updated(  LJ::time_to_w3c($it->{modtime}, 'Z') );
        $entry->modified( LJ::time_to_w3c($it->{modtime}, 'Z') );  # COMPAT

        # XML::Atom 0.9 doesn't support categories.   Maybe later?
        foreach my $tag ( @{$it->{tags} || []} ) {
            $tag = LJ::exml( $tag );
            my $category = $entry_xml->createElement( 'category' );
            $category->setAttribute( 'term', $tag );
            $entry_xml->getDocumentElement->appendChild( $category );
        }

        # if syndicating the complete entry
        #   -print a content tag
        # elsif syndicating summaries
        #   -print a summary tag
         # else (code omitted), we're syndicating title only
        #   -print neither (the title has already been printed)
        #   note: the $event was also emptied earlier, in make_feed
        #
        # a lack of a content element is allowed,  as long
        # as we maintain a proper 'alternate' link (above)
        if ($u->{'opt_synlevel'} eq 'full') {
            # Do this manually for now, until XML::Atom supports new
            # content type classifications.
            my $content = $entry_xml->createElement( 'content' );
            $content->setAttribute( 'type', 'html' );
            $content->appendTextNode( LJ::exml( $it->{'event'} ) );
            $entry_xml->getDocumentElement->appendChild( $content );
        } elsif ($u->{'opt_synlevel'} eq 'summary') {
            my $summary = $entry_xml->createElement( 'summary' );
            $summary->setAttribute( 'type', 'html' );
            $summary->appendTextNode( LJ::exml( $it->{'event'} ) );
            $entry_xml->getDocumentElement->appendChild( $summary );
        }

        if ( $opts->{'single_entry'} ) {
            return $entry->as_xml();
        }
        else {
            $feed->add_entry( $entry );
        }
    }

    return $feed->as_xml();
}

# create a FOAF page for a user
sub create_view_foaf {
    my ($journalinfo, $u, $opts) = @_;
    my $comm = ($u->{journaltype} eq 'C');

    my $ret;

    # return nothing if we're not a user
    unless ($u->{journaltype} eq 'P' || $comm) {
        $opts->{handler_return} = 404;
        return undef;
    }

    # set our content type
    $opts->{contenttype} = 'application/rdf+xml; charset=' . $opts->{saycharset};

    # setup userprops we will need
    LJ::load_user_props($u, qw{
        aolim icq yahoo jabber msn url urlname external_foaf_url
    });

    # create bare foaf document, for now
    $ret = "<?xml version='1.0'?>\n";
    $ret .= LJ::run_hook("bot_director", "<!-- ", " -->");
    $ret .= "<rdf:RDF\n";
    $ret .= "   xml:lang=\"en\"\n";
    $ret .= "   xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"\n";
    $ret .= "   xmlns:rdfs=\"http://www.w3.org/2000/01/rdf-schema#\"\n";
    $ret .= "   xmlns:foaf=\"http://xmlns.com/foaf/0.1/\"\n";
    $ret .= "   xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n";

    # precompute some values
    my $digest = Digest::SHA1::sha1_hex('mailto:' . $u->{email});

    # channel attributes
    $ret .= ($comm ? "  <foaf:Group>\n" : "  <foaf:Person>\n");
    $ret .= "    <foaf:nick>$u->{user}</foaf:nick>\n";
    if ($u->{bdate} && $u->{bdate} ne "0000-00-00" && !$comm && $u->{allow_infoshow} eq 'Y') {
        my $bdate = $u->{bdate};
        $bdate =~ s/^0000-//;
        $ret .= "    <foaf:dateOfBirth>$bdate</foaf:dateOfBirth>\n";
    }
    $ret .= "    <foaf:mbox_sha1sum>$digest</foaf:mbox_sha1sum>\n";
    $ret .= "    <foaf:page>\n";
    $ret .= "      <foaf:Document rdf:about=\"$LJ::SITEROOT/userinfo.bml?user=$u->{user}\">\n";
    $ret .= "        <dc:title>$LJ::SITENAME Profile</dc:title>\n";
    $ret .= "        <dc:description>Full $LJ::SITENAME profile, including information such as interests and bio.</dc:description>\n";
    $ret .= "      </foaf:Document>\n";
    $ret .= "    </foaf:page>\n";

    # we want to bail out if they have an external foaf file, because
    # we want them to be able to provide their own information.
    if ($u->{external_foaf_url}) {
        $ret .= "    <rdfs:seeAlso rdf:resource=\"" . LJ::eurl($u->{external_foaf_url}) . "\" />\n";
        $ret .= ($comm ? "  </foaf:Group>\n" : "  </foaf:Person>\n");
        $ret .= "</rdf:RDF>\n";
        return $ret;
    }

    # contact type information
    my %types = (
        aolim => 'aimChatID',
        icq => 'icqChatID',
        yahoo => 'yahooChatID',
        msn => 'msnChatID',
        jabber => 'jabberID',
    );
    if ($u->{allow_contactshow} eq 'Y') {
        foreach my $type (keys %types) {
            next unless $u->{$type};
            $ret .= "    <foaf:$types{$type}>" . LJ::exml($u->{$type}) . "</foaf:$types{$type}>\n";
        }
    }

    # include a user's journal page and web site info
    $ret .= "    <foaf:weblog rdf:resource=\"" . LJ::journal_base($u) . "/\"/>\n";
    if ($u->{url}) {
        $ret .= "    <foaf:homepage rdf:resource=\"" . LJ::eurl($u->{url});
        $ret .= "\" dc:title=\"" . LJ::exml($u->{urlname}) . "\" />\n";
    }

    # interests, please!
    # arrayref of interests rows: [ intid, intname, intcount ]
    my $intu = LJ::get_interests($u);
    foreach my $int (@$intu) {
        LJ::text_out(\$int->[1]); # 1==interest
        $ret .= "    <foaf:interest dc:title=\"". LJ::exml($int->[1]) . "\" " .
                "rdf:resource=\"$LJ::SITEROOT/interests.bml?int=" . LJ::eurl($int->[1]) . "\" />\n";
    }

    # check if the user has a "FOAF-knows" group
    my $groups = LJ::get_friend_group($u->{userid}, { name => 'FOAF-knows' });
    my $mask = $groups ? 1 << $groups->{groupnum} : 0;

    # now information on who you know, limited to a certain maximum number of users
    my $friends = LJ::get_friends($u->{userid}, $mask);
    my @ids = keys %$friends;
    @ids = splice(@ids, 0, $LJ::MAX_FOAF_FRIENDS) if @ids > $LJ::MAX_FOAF_FRIENDS;

    # now load
    my %users;
    LJ::load_userids_multiple([ map { $_, \$users{$_} } @ids ], [$u]);

    # iterate to create data structure
    foreach my $friendid (@ids) {
        next if $friendid == $u->{userid};
        my $fu = $users{$friendid};
        next if $fu->{statusvis} =~ /[DXS]/ || $fu->{journaltype} ne 'P';
        $ret .= $comm ? "    <foaf:member>\n" : "    <foaf:knows>\n";
        $ret .= "      <foaf:Person>\n";
        $ret .= "        <foaf:nick>$fu->{'user'}</foaf:nick>\n";
        $ret .= "        <rdfs:seeAlso rdf:resource=\"" . LJ::journal_base($fu) ."/data/foaf\" />\n";
        $ret .= "        <foaf:weblog rdf:resource=\"" . LJ::journal_base($fu) . "/\"/>\n";
        $ret .= "      </foaf:Person>\n";
        $ret .= $comm ? "    </foaf:member>\n" : "    </foaf:knows>\n";
    }

    # finish off the document
    $ret .= $comm ? "    </foaf:Group>\n" : "  </foaf:Person>\n";
    $ret .= "</rdf:RDF>\n";

    return $ret;
}

1;
