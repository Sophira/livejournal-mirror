#!/usr/bin/perl
#

use strict;
use vars qw($dbh %maint);
use lib "$ENV{'LJHOME'}/cgi-bin";  # extra XML::Encoding files in cgi-bin/XML/*
use LWP::UserAgent;
use XML::RSS;
require "$ENV{'LJHOME'}/cgi-bin/ljprotocol.pl";

$maint{'synsuck'} = sub
{
    my $dbs = LJ::get_dbs();
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $sth;
    
    my $ua =  LWP::UserAgent->new("timeout" => 10);

    $sth = $dbh->prepare("SELECT u.user, s.userid, s.synurl, s.lastmod, s.etag, s.numreaders ".
                         "FROM useridmap u, syndicated s ".
                         "WHERE u.userid=s.userid AND ".
                         "s.checknext < NOW() ORDER BY s.checknext");
    $sth->execute;
    while (my ($user, $userid, $synurl, $lastmod, $etag, $readers) = $sth->fetchrow_array)
    {
        my $delay = sub {
            my $minutes = shift;
            my $status = shift;
            $dbh->do("UPDATE syndicated SET lastcheck=NOW(), checknext=DATE_ADD(NOW(), ".
                     "INTERVAL ? MINUTE), laststatus=? WHERE userid=?",
                     undef, $minutes, $status, $userid);
        };

        print "Synsuck: $user ($synurl)\n";

        my $req = HTTP::Request->new("GET", $synurl);
        $req->header('If-Modified-Since', LJ::time_to_http($lastmod))
            if $lastmod;
        $req->header('If-None-Match', $etag)
            if $etag;

        my ($content, $too_big);
        my $res = $ua->request($req, sub {
            if (length($content) > 1024*150) { $too_big = 1; return; }
            $content .= $_[0];
        }, 4096);
        if ($too_big) { $delay->(60, "toobig"); next; }

        # check if not modified
        if ($res->status_line() =~ /^304/) {
            print "  not modified.\n";
            $delay->($readers ? 60 : 24*60, "notmodified");
            next;
        }

        # WARNING: blatant XML spec violation ahead... 
        # 
        # Blogger doesn't produce valid XML, since they don't handle encodings
        # correctly.  So if we see they have no encoding (which is UTF-8 implictly)
        # but it's not valid UTF-8, say it's Windows-1252, which won't 
        # cause XML::Parser to barf... but there will probably be some bogus characters.
        # better than nothing I guess.  (personally, I'd prefer to leave it broken
        # and have people bitch at Blogger, but jwz wouldn't stop bugging me)
        # XML::Parser doesn't include Windows-1252, but we put it in cgi-bin/XML/* for it
        # to find.
        my $encoding;
        if ($content =~ /<\?xml.+?>/ && $& =~ /encoding=([\"\'])(.+?)\1/) {
            $encoding = lc($2);
        }
        if (! $encoding && ! LJ::is_utf8($content)) {
            $content =~ s/\?>/ encoding='windows-1252' \?>/;
        }
        
        # WARNING: another hack...
        # People produce what they think is iso-8859-1, but they include
        # Windows-style smart quotes.  Check for invalid iso-8859-1 and correct.
        if ($encoding =~ /^iso-8859-1$/i && $content =~ /[\x80-\x9F]/) {
            # They claimed they were iso-8859-1, but they are lying.
            # Assume it was Windows-1252.
            print "Invalid ISO-8859-1; assuming Windows-1252...\n";
            $content =~ s/encoding=([\"\'])(.+?)\1/encoding='windows-1252'/;
        }

        # parsing time...
        my $rss = new XML::RSS;
        eval {
            $rss->parse($content);
        };
        if ($@) {
            # parse error!
            print "Parse error!\n";
            $delay->(3*60, "parseerror");
            next;
        }

        # another sanity check
        unless (ref $rss->{'items'} eq "ARRAY") { $delay->(3*60, "noitems"); next; }

        my @items = reverse @{$rss->{'items'}};

        # take most recent 20
        splice(@items, 0, @items-20) if @items > 20;

        # delete existing items older than the age which can show on a
        # friends view.
        my $su = LJ::load_userid($dbs, $userid);
        my $udbh = LJ::get_cluster_master($su);
        if ($udbh) {
            my $secs = ($LJ::MAX_FRIENDS_VIEW_AGE || 3600*24*14)+0;  # 2 week default.
            my $sth = $udbh->prepare("SELECT jitemid, anum FROM log2 WHERE journalid=? AND ".
                                     "logtime < DATE_SUB(NOW(), INTERVAL $secs SECOND)");
            $sth->execute($userid);
            die $udbh->errstr if $udbh->err;
            while (my ($jitemid, $anum) = $sth->fetchrow_array) {
                print "DELETE itemid: $jitemid, anum: $anum... \n";
                if (LJ::delete_item2($dbh, $udbh, $userid, $jitemid, 0, $anum)) {
                    print "success.\n"; 
                } else {
                    print "fail.\n";
                }
            }
        } else {
            print "WARNING: syndicated user not on a cluster.  can't delete old stuff.\n";
        }
        
        # determine if link tags are good or not, where good means
        # "likely to be a unique per item".  some feeds have the same
        # <link> element for each item, which isn't good.
        my $good_links = 0;
        {
            my %link_seen;
            foreach my $it (@items) {
                next unless $it->{'link'};
                $link_seen{$it->{'link'}} = 1;
            }
            $good_links = 1 if scalar(keys %link_seen) > 1;
        }

        # if the links are good, load all the URLs for syndicated
        # items we already have on the server.  then, if we have one
        # already later and see it's changed, we'll do an editevent
        # instead of a new post.
        my %existing_item = ();
        if ($good_links && $udbh) {
            LJ::load_props($dbh, "log");
            my $p = LJ::get_prop("log", "syn_link");
            my $sth = $udbh->prepare("SELECT jitemid, value FROM logprop2 WHERE ".
                                     "journalid=? AND propid=? LIMIT 1000");
            $sth->execute($su->{'userid'}, $p->{'id'});
            while (my ($itemid, $link) = $sth->fetchrow_array) {
                $existing_item{$link} = $itemid;
            }
        }

        # post these items
        my $newcount = 0;
        my $errorflag = 0;
        foreach my $it (@items) {
            my $dig = LJ::md5_struct($it)->b64digest;
            next if $dbh->selectrow_array("SELECT COUNT(*) FROM synitem WHERE ".
                                          "userid=$userid AND item=?", undef,
                                          $dig);
            $dbh->do("INSERT INTO synitem (userid, item, dateadd) VALUES (?,?,NOW())",
                     undef, $userid, $dig);

            $newcount++;
            print "$dig - $it->{'title'}\n";
            $it->{'description'} =~ s/^\s+//;
            $it->{'description'} =~ s/\s+$//;
            
            my @now = localtime();
            my $htmllink;
            if (defined $it->{'link'}) {
                $htmllink = "<p class='ljsyndicationlink'>" .
                    "<a href='$it->{'link'}'>$it->{'link'}</a></p>";
            }

            my $command = "postevent";
            my $req = {
                'username' => $user,
                'ver' => 1,
                'subject' => $it->{'title'},
                'event' => "$htmllink$it->{'description'}",
                'year' => $now[5]+1900,
                'mon' => $now[4]+1,
                'day' => $now[3],
                'hour' => $now[2],
                'min' => $now[1],
                'props' => {
                    'syn_link' => $it->{'link'},
                },
            };
            my $flags = {
                'nopassword' => 1,
            };

            # if the post contains html linebreaks, assume it's preformatted.
            if ($it->{'description'} =~ /<(p|br)\b/i) {
                $req->{'props'}->{'opt_preformatted'} = 1;
            }

            # do an editevent if we've seen this item before
            my $old_itemid = $existing_item{$it->{'link'}};
            if ($it->{'link'} && $old_itemid) {
                $newcount--; # cancel increment above
                $command = "editevent";
                $req->{'itemid'} = $old_itemid;
                
                # the editevent requires us to resend the date info, which
                # we have to go fetch first, to see when we first syndicated
                # the item:
                my $origtime = $udbh->selectrow_array("SELECT eventtime FROM log2 WHERE ".
                                                      "journalid=? AND jitemid=?", undef,
                                                      $su->{'userid'}, $old_itemid);
                $origtime =~ /(\d\d\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d)/;
                $req->{'year'} = $1;
                $req->{'mon'} = $2;
                $req->{'day'} = $3;
                $req->{'hour'} = $4;
                $req->{'min'} = $5;
            }

            my $err;
            my $pre_time = time();
            my $res = LJ::Protocol::do_request($dbs, $command, $req, \$err, $flags);
            my $post_time = time();
            if ($res && ! $err) {
                # so 20 items in a row don't get the same logtime 
                # second value, so they sort correctly:
                sleep 1 if $pre_time == $post_time;
            } else {
                print "  Error: $err\n";
                $errorflag = 1;
            }
        }

        # bail out if errors, and try again shortly
        if ($errorflag) {
            $delay->(30, "posterror");
            next;
        }

        # update syndicated account's userinfo if necessary
        LJ::load_user_props($dbs, $su, "url", "urlname");
        {
            my $title = $rss->channel('title');
            if ($title && $title ne $su->{'name'}) {
                $dbh->do("UPDATE user SET name=? WHERE userid=?", undef,
                         $title, $su->{'userid'});
                LJ::set_userprop($dbh, $su, "urlname", $title);
            }

            my $link = $rss->channel('link');
            if ($link && $link ne $su->{'url'}) {
                LJ::set_userprop($dbh, $su, "url", $link);
            }

            my $des = $rss->channel('description');
            if ($des && $udbh) {
                my $bio;
                if ($su->{'has_bio'} eq "Y") {
                    $bio = $udbh->selectrow_array("SELECT bio FROM userbio WHERE userid=?", undef,
                                                  $su->{'userid'});
                }
                if ($bio ne $des && $bio !~ /\[LJ:KEEP\]/) {
                    if ($des) {
                        $udbh->do("REPLACE INTO userbio (userid, bio) VALUES (?,?)", undef,
                                  $su->{'userid'}, $des);
                    } else {
                        $udbh->do("DELETE FROM userbio WHERE userid=?", undef, $su->{'userid'});
                    }
                    $dbh->do("UPDATE user SET has_bio=? WHERE userid=?", undef,
                             ($des ? "Y" : "N"), $su->{'userid'});
                }
            }
        }

        my $r_lastmod = LJ::http_to_time($res->header('Last-Modified'));
        my $r_etag = $res->header('ETag');

        # decide when to poll next (in minutes). 
        # FIXME: this is super lame.  (use hints in RSS file!)
        my $int = $newcount ? 30 : 60;
        my $status = $newcount ? "ok" : "nonew";
        my $updatenew = $newcount ? ", lastnew=NOW()" : "";
        
        # update reader count while we're changing things, but not
        # if feed is stale (minimize DB work for inactive things)
        if ($newcount || ! defined $readers) {
            $readers = $dbh->selectrow_array("SELECT COUNT(*) FROM friends WHERE ".
                                             "friendid=?", undef, $userid);
        }

        # if readers are gone, don't check for a whole day
        $int = 60*24 unless $readers;
 
        $dbh->do("UPDATE syndicated SET checknext=DATE_ADD(NOW(), INTERVAL $int MINUTE), ".
                 "lastcheck=NOW(), lastmod=?, etag=?, laststatus=?, numreaders=? $updatenew ".
                 "WHERE userid=$userid", undef, $r_lastmod, $r_etag, $status, $readers);
    }
};

1;
