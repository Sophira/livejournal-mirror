#!/usr/bin/perl
#

use strict;
package LJ::S2;

sub MonthPage
{
    my ($u, $remote, $opts) = @_;

    my $p = Page($u, $opts);
    $p->{'_type'} = "MonthPage";
    $p->{'view'} = "month";
    $p->{'days'} = [];

    my $ctx = $opts->{'ctx'};

    my $dbr = LJ::get_db_reader();
    my $dbcr = LJ::get_cluster_reader($u);

    my $user = $u->{'user'};
    my $journalbase = LJ::journal_base($user, $opts->{'vhost'});

    if ($u->{'journaltype'} eq "R" && $u->{'renamedto'} ne "") {
        $opts->{'redir'} = LJ::journal_base($u->{'renamedto'}, $opts->{'vhost'}) .
            "/" . $opts->{'pathextra'};
        return 1;
    }

    if ($u->{'opt_blockrobots'}) {
        $p->{'head_content'} .= LJ::robot_meta_tags();
    }

    my ($year, $month);
    if ($opts->{'pathextra'} =~ m!^/(\d\d\d\d)/(\d\d)\b!) {
        ($year, $month) = ($1, $2);
    }
    
    $opts->{'errors'} = [];
    if ($month < 1 || $month > 12) { push @{$opts->{'errors'}}, "Invalid month: $month"; }
    if ($year < 1970 || $year > 2038) { push @{$opts->{'errors'}}, "Invalid year: $year"; }
    unless ($dbcr) { push @{$opts->{'errors'}}, "Database temporarily unavailable"; }
    return if @{$opts->{'errors'}};

    $p->{'date'} = Date($year, $month, 0);

    # load the log items
    my $dateformat = "%Y %m %d %H %i %s %w"; # yyyy mm dd hh mm ss day_of_week
    my $sth;

    my $secwhere = "AND l.security='public'";
    if ($remote) {
        if ($remote->{'userid'} == $u->{'userid'}) {
            $secwhere = "";   # see everything
        } elsif ($remote->{'journaltype'} eq 'P') {
            my $gmask = $dbr->selectrow_array("SELECT groupmask FROM friends WHERE userid=$u->{'userid'} ".
                                              "AND friendid=$remote->{'userid'}");
            $secwhere = "AND (l.security='public' OR (l.security='usemask' AND l.allowmask & $gmask))"
                if $gmask;
        }
    }
    
    $sth = $dbcr->prepare("SELECT l.jitemid, l.posterid, l.anum, l.day, lt.subject, ".
                          "       DATE_FORMAT(l.eventtime, '$dateformat') AS 'alldatepart', ".
                          "       l.replycount, l.security ".
                          "FROM log2 l, logtext2 lt ".
                          "WHERE l.journalid=$u->{'userid'} AND lt.journalid=$u->{'userid'} ".
                          "AND l.year=$year AND l.month=$month AND l.jitemid=lt.jitemid ".
                          "$secwhere LIMIT 2000");
    $sth->execute;

    my @items;
    push @items, $_ while $_ = $sth->fetchrow_hashref;
    @items = sort { $a->{'alldatepart'} cmp $b->{'alldatepart'} } @items;

    my @itemids = map { $_->{'jitemid'} } @items;

    # load the log properties
    my %logprops = ();
    LJ::load_log_props2($dbcr, $u->{'userid'}, \@itemids, \%logprops);

    my (%pu, %pu_lite);  # poster users; UserLite objects
    foreach (@items) {
        $pu{$_->{'posterid'}} = undef;
    }
    LJ::load_userids_multiple($dbr, [map { $_, \$pu{$_} } keys %pu], [$u]);
    $pu_lite{$_} = UserLite($pu{$_}) foreach keys %pu;

    my %day_entries;  # <day> -> [ Entry+ ]

    my $opt_text_subjects = S2::get_property_value($ctx, "page_month_textsubjects");
    my $userlite_journal = UserLite($u);
    
  ENTRY:
    foreach my $item (@items)
    {
        my ($posterid, $itemid, $security, $alldatepart, $replycount, $anum) = 
            map { $item->{$_} } qw(posterid jitemid security alldatepart replycount anum);
        my $subject = $item->{'subject'};
        my $day = $item->{'day'};

        # don't show posts from suspended users
        next unless $pu{$posterid};
        next ENTRY if $pu{$posterid}->{'statusvis'} eq 'S';

	if ($LJ::UNICODE && $logprops{$itemid}->{'unknown8bit'}) {
            my $text;
	    LJ::item_toutf8($u, \$subject, \$text, $logprops{$itemid});
	}

        if ($opt_text_subjects) {
            LJ::CleanHTML::clean_subject_all(\$subject);
        } else {
            LJ::CleanHTML::clean_subject(\$subject);
        }

        my $ditemid = $itemid*256 + $anum;
        my $nc = "";
        $nc .= "nc=$replycount" if $replycount && $remote && $remote->{'opt_nctalklinks'};
        my $permalink = "$journalbase/$ditemid.html";
        my $readurl = $permalink;
        $readurl .= "?$nc" if $nc;
        my $posturl = $permalink . "?mode=reply";

        my $comments = CommentInfo({
            'read_url' => $readurl,
            'post_url' => $posturl,
            'count' => $replycount,
            'enabled' => ($u->{'opt_showtalklinks'} eq "Y" && ! $logprops{$itemid}->{'opt_nocomments'}) ? 1 : 0,
            'screened' => ($logprops{$itemid}->{'hasscreened'} && ($remote->{'user'} eq $u->{'user'}|| LJ::check_rel($dbr, $u, $remote, 'A'))) ? 1 : 0,
        });
        
        my $userlite_poster = $userlite_journal;
        my $userpic = $p->{'journal'}->{'default_pic'};
        if ($u->{'userid'} != $posterid) {
            $userlite_poster = $pu_lite{$posterid};
            $userpic = Image_userpic($pu{$posterid}, 0, $logprops{$itemid}->{'picture_keyword'});
        }

        my $entry = Entry($u, {
            'subject' => $subject,
            'text' => "",
            'dateparts' => $alldatepart,
            'security' => $security,
            'props' => $logprops{$itemid},
            'itemid' => $ditemid,
            'journal' => $userlite_journal,
            'poster' => $userlite_poster,
            'comments' => $comments,
            'userpic' => $userpic,
            'permalink_url' => $permalink,
        });

        push @{$day_entries{$day}}, $entry;
    }
   
    my $days_month = LJ::days_in_month($month, $year);
    for my $day (1..$days_month) {
        my $entries = $day_entries{$day} || [];
        my $month_day = {
            '_type' => 'MonthDay',
            'date' => Date($year, $month, $day),
            'day' => $day,
            'has_entries' => scalar @$entries > 0,
            'num_entries' => scalar @$entries,
            'url' => $journalbase . sprintf("/%04d/%02d/%02d/", $year, $month, $day),
            'entries' => $entries,
        };
        push @{$p->{'days'}}, $month_day;
    }

    # populate redirector
    my $vhost = $opts->{'vhost'};
    $vhost =~ s/:.*//;
    $p->{'redir'} = {
        '_type' => "Redirector",
        'user' => $u->{'user'},
        'vhost' => $vhost,
        'type' => 'monthview',
        'url' => "$LJ::SITEROOT/go.bml",
    };
    
    # figure out what months have been posted into
    my $nowval = $year*12 + $month;

    $p->{'months'} = [];
    $sth = $dbcr->prepare("SELECT DISTINCT year, month FROM log2 ".
                          "WHERE journalid=? ORDER BY year, month");
    $sth->execute($u->{'userid'});
    while (my ($oy, $om) = $sth->fetchrow_array) {
        my $date = Date($oy, $om, 0);
        my $url = $journalbase . sprintf("/%04d/%02d/", $oy, $om);
        push @{$p->{'months'}}, {
            '_type' => "MonthEntryInfo",
            'date' => $date,
            'url' => $url,
            'redir_key' => sprintf("%04d%02d", $oy, $om),
        };

        my $val = $oy*12+$om;
        if ($val < $nowval) {
            $p->{'prev_url'} = $url;
            $p->{'prev_date'} = $date;
        }
        if ($val > $nowval && ! $p->{'next_date'}) {
            $p->{'next_url'} = $url;
            $p->{'next_date'} = $date;
        }
    }

    return $p;
}

1;
