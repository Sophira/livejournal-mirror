#!/usr/bin/perl
#

package LJ::Poll;

use strict;
use HTML::TokeParser ();

require "$ENV{'LJHOME'}/cgi-bin/cleanhtml.pl";

sub clean_poll
{
    my $ref = shift;

    my $poll_eat = [qw[head title style layer iframe applet object]];
    my $poll_allow = [qw[a b i u img]];
    my $poll_remove = [qw[bgsound embed object caption link font]];
    
    LJ::CleanHTML::clean($ref, {
        'wordlength' => 40,
        'addbreaks' => 0,
        'eat' => $poll_eat,
        'mode' => 'deny',
        'allow' => $poll_allow,
        'remove' => $poll_remove,
    });
    LJ::text_out($ref);
}


sub contains_new_poll
{
    my $postref = shift;
    return ($$postref =~ /<lj-poll\b/i);
}

sub parse
{
    my $dbs = shift;
    my $postref = shift;
    my $error = shift;
    my $iteminfo = shift; 

    $iteminfo->{'posterid'} += 0;
    $iteminfo->{'journalid'} += 0;

    my $newdata;

    my $popen = 0;
    my %popts;

    my $qopen = 0;
    my %qopts;
    
    my $iopen = 0;
    my %iopts;

    my @polls;  # completed parsed polls

    my $p = HTML::TokeParser->new($postref);

    while (my $token = $p->get_token)    
    {
        my $type = $token->[0];
        my $append;
        
        if ($type eq "S")     # start tag
        {
            my $tag = $token->[1];
            my $opts = $token->[2];
    
            ######## Begin poll tag
            
            if ($tag eq "lj-poll") {
                if ($popen) {
                    $$error = "You cannot nest lj-poll tags.  Did you forget to close one?";
                    return 0;
                }

                $popen = 1;
                %popts = ();
                $popts{'questions'} = [];

                $popts{'name'} = $opts->{'name'};
                $popts{'whovote'} = lc($opts->{'whovote'}) || "all";
                $popts{'whoview'} = lc($opts->{'whoview'}) || "all";

                if ($popts{'whovote'} ne "all" && 
                    $popts{'whovote'} ne "friends")
                {
                    $$error = "whovote must be 'all' or 'friends'";
                    return 0;
                }
                if ($popts{'whoview'} ne "all" && 
                    $popts{'whoview'} ne "friends" &&
                    $popts{'whoview'} ne "none")
                {
                    $$error = "whoview must be 'all', 'friends', or 'none'";
                    return 0;
                }
            }

            ######## Begin poll question tag
            
            elsif ($tag eq "lj-pq") 
            {
                if ($qopen) {
                    $$error = "You cannot nest lj-pq tags.  Did you forget to close one?";
                    return 0;
                }
                if (! $popen) {
                    $$error = "All lj-pq tags must be nested inside an enclosing lj-poll tag.";
                    return 0;
                }
                $qopen = 1;
                %qopts = ();
                $qopts{'items'} = [];

                $qopts{'type'} = $opts->{'type'};
                if ($qopts{'type'} eq "text") {
                    my $size = 35;
                    my $max = 255;
                    if (defined $opts->{'size'}) {
                        if ($opts->{'size'} > 0 &&
                            $opts->{'size'} <= 100)
                        {
                            $size = $opts->{'size'}+0;
                        } else {
                            $$error = "Size attribute on lj-pq text tags must be an integer from 1-100";
                            return 0;
                        }
                    }
                    if (defined $opts->{'maxlength'}) {
                        if ($opts->{'maxlength'} > 0 &&
                            $opts->{'maxlength'} <= 255)
                        {
                            $max = $opts->{'maxlength'}+0;
                        } else {
                            $$error = "Maxlength attribute on lj-pq text tags must be an integer from 1-255";
                            return 0;
                        }
                    }

                    $qopts{'opts'} = "$size/$max";
                }
                if ($qopts{'type'} eq "scale") 
                {
                    my $from = 1;
                    my $to = 10;
                    my $by = 1;

                    if (defined $opts->{'from'}) {
                        $from = int($opts->{'from'});
                    }
                    if (defined $opts->{'to'}) {
                        $to = int($opts->{'to'});
                    }
                    if (defined $opts->{'by'}) {
                        $by = int($opts->{'by'});
                    }
                    if ($by < 1) {
                        $$error = "Scale increment must be at least 1.";
                        return 0;
                    }
                    if ($from >= $to) {
                        $$error = "Scale 'from' value must be less than 'to' value.";
                        return 0;
                    }
                    if ((($to-$from)/$by) > 20) {
                        $$error = "Your scale exceeds the limit of 20 selections (to-from)/by > 20";
                        return 0;
                    }
                    $qopts{'opts'} = "$from/$to/$by";
                }

                $qopts{'type'} = lc($opts->{'type'}) || "text";

                if ($qopts{'type'} ne "radio" &&
                    $qopts{'type'} ne "check" &&
                    $qopts{'type'} ne "drop" &&
                    $qopts{'type'} ne "scale" &&
                    $qopts{'type'} ne "text")
                {
                    $$error = "Unknown type on lj-pq tag";
                    return 0;
                }
                
                
            }

            ######## Begin poll item tag

            elsif ($tag eq "lj-pi")
            {
                if ($iopen) {
                    $$error = "You cannot nest lj-pi tags.  Did you forget to close one?";
                    return 0;
                }
                if (! $qopen) {
                    $$error = "All lj-pi tags must be nested inside an enclosing lj-pq tag.";
                    return 0;
                }
                if ($qopts{'type'} eq "text")
                {
                    $$error = "lj-pq tags of type 'text' cannot have poll items in them";
                    return 0;
                }
                
                $iopen = 1;
                %iopts = ();
            }   

            #### not a special tag.  dump it right back out.

            else 
            {
                $append .= "<$tag";
                foreach (keys %$opts) {
                    $append .= " $_=\"$opts->{$_}\"";
                }
                $append .= ">";
            }
        }
        elsif ($type eq "E") 
        {
            my $tag = $token->[1];

            ##### end POLL

            if ($tag eq "lj-poll") {
                unless ($popen) {
                    $$error = "Cannot close an lj-poll tag that's not open";
                    return 0;
                }
                $popen = 0;

                unless (@{$popts{'questions'}}) {
                    $$error = "You must have at least one question in a poll.";
                    return 0;
                }
                
                $popts{'journalid'} = $iteminfo->{'journalid'};
                $popts{'posterid'} = $iteminfo->{'posterid'};
                
                push @polls, { %popts };

                $append .= "<lj-poll-placeholder>";
            } 

            ##### end QUESTION

            elsif ($tag eq "lj-pq") {
                unless ($qopen) {
                    $$error = "Cannot close an lj-pq tag that's not open";
                    return 0;
                }

                unless ($qopts{'type'} eq "scale" || 
                        $qopts{'type'} eq "text" || 
                        @{$qopts{'items'}}) 
                {
                    $$error = "You must have at least one item in a non-text poll question.";
                    return 0;
                }

                $qopts{'qtext'} =~ s/^\s+//;
                $qopts{'qtext'} =~ s/\s+$//;
                my $len = length($qopts{'qtext'});
                if (! $len)
                {
                    $$error .= "Need text inside an lj-pq tag to say what the question is about.";
                    return 0;
                }

                push @{$popts{'questions'}}, { %qopts };
                $qopen = 0;
                
            }

            ##### end ITEM

            elsif ($tag eq "lj-pi") {
                unless ($iopen) {
                    $$error = "Cannot close an lj-pi tag that's not open";
                    return 0;
                }

                $iopts{'item'} =~ s/^\s+//;
                $iopts{'item'} =~ s/\s+$//;
                my $len = length($iopts{'item'});
                if ($len > 255 || $len < 1)
                {
                    $$error .= "Text inside an lj-pi tag must be between 1 and 255 characters.  Your's is $len";
                    return 0;
                }

                push @{$qopts{'items'}}, { %iopts };
                $iopen = 0;
            }
            
            ###### not a special tag.
            
            else
            {
                $append .= "</$tag>";
            }
        }
        elsif ($type eq "T" || $type eq "D") 
        {
            $append = $token->[1];
        } 
        elsif ($type eq "C") {
            # ignore comments
        }
        elsif ($type eq "PI") {
            $newdata .= "<?$token->[1]>";
        }
        else {
            $newdata .= "<!-- OTHER: " . $type . "-->\n";
        }

        ##### append stuff to the right place
        if (length($append))
        {
            if ($iopen) {
                $iopts{'item'} .= $append;
            }
            elsif ($qopen) {
                $qopts{'qtext'} .= $append;
            }
            elsif ($popen) {
                0;       # do nothing.
            } else {
                $newdata .= $append;
            }
        }

    } 

    if ($popen) { $$error = "Unlocked lj-poll tag."; return 0; }
    if ($qopen) { $$error = "Unlocked lj-pq tag."; return 0; }
    if ($iopen) { $$error = "Unlocked lj-pi tag."; return 0; }

    $$postref = $newdata;
    return @polls;
}

# note: $itemid is a $ditemid (display itemid, *256 + anum)
sub register
{
    my $dbs = shift;
    my $dbh = $dbs->{'dbh'};
    my $post = shift;
    my $error = shift;
    my $itemid = shift;
    my @polls = @_;
    
    foreach my $po (@polls)
    {
        my %popts = %$po;
        $popts{'itemid'} = $itemid+0;

        #### CREATE THE POLL!
        
        my ($sth, $sql);
        my $qwhovote = $dbh->quote($popts{'whovote'});
        my $qwhoview = $dbh->quote($popts{'whoview'});
        my $qname = $dbh->quote($popts{'name'});

        $sql = "INSERT INTO poll (itemid, journalid, posterid, whovote, whoview, name) VALUES ".
            "($itemid, $popts{'journalid'}, $popts{'posterid'}, $qwhovote, $qwhoview, $qname)";

        $sth = $dbh->prepare($sql);				     
        $sth->execute;
        if ($dbh->err) {
            $$error = "Database error: " . $dbh->errstr;
            return 0;
        }
        my $pollid = $dbh->{'mysql_insertid'};

        $$post =~ s/<lj-poll-placeholder>/<lj-poll-$pollid>/;  # NOT global replace!
        
        ## start inserting poll questions
        my $qnum = 0;
        foreach my $q (@{$popts{'questions'}})
        {
            $qnum++;
            my $qtype = $dbh->quote($q->{'type'});
            my $qopts = $dbh->quote($q->{'opts'});
            my $qqtext = $dbh->quote($q->{'qtext'});
            $sql = "INSERT INTO pollquestion (pollid, pollqid, sortorder, type, opts, qtext) VALUES ($pollid, $qnum, $qnum, $qtype, $qopts, $qqtext)";
            $sth = $dbh->prepare($sql);
            $sth->execute;
            if ($dbh->err) {
                $$error = "Database error inserting questions: " . $dbh->errstr;
                return 0;
            }
            
            my $pollqid = $dbh->{'mysql_insertid'};
            
            ## start inserting poll items
            my $inum = 0;
            foreach my $it (@{$q->{'items'}}) {
                $inum++;
                my $qitem = $dbh->quote($it->{'item'});
                $sql = "INSERT INTO pollitem (pollid, pollqid, pollitid, sortorder, item) VALUES ($pollid, $qnum, $inum, $inum, $qitem)";
                $dbh->do($sql);
                if ($dbh->err) {
                    $$error = "Database error inserting items: " . $dbh->errstr;
                    return 0;
                }
            }
            ## end inserting poll items
            
        }
        ## end inserting poll questions
        
    }  ### end while over all poles

}

sub show_polls
{
    my $dbs = shift;
    my $itemid = shift;
    my $remote = shift;
    my $postref = shift;

    $$postref =~ s/<lj-poll-(\d+)>/&show_poll($dbs, $itemid, $remote, $1)/eg;
}

sub show_poll
{
    my $dbs = shift;
    my $dbr = $dbs->{'reader'};
    my $itemid = shift;
    my $remote = shift;
    my $pollid = shift;
    my $opts = shift;  # hashref.  {"mode" => results/enter}
    my $sth;

    my $mode = $opts->{'mode'};
    $pollid += 0;
    
    $sth = $dbr->prepare("SELECT itemid, whovote, journalid, posterid, whoview, whovote, name FROM poll WHERE pollid=$pollid");
    $sth->execute;
    my $po = $sth->fetchrow_hashref;
    unless ($po) {
        return "<b>[Error: poll #$pollid not found]</b>"
    }
    
    if ($itemid && $po->{'itemid'} != $itemid) {
        return "<b>[Error: this poll is not attached to this journal entry]</b>"	
    }
    my ($can_vote, $can_view) = find_security($dbs, $po, $remote);

    ### prepare our output buffer
    my $ret;

    ### view answers to a particular question in a poll
    if ($mode eq "ans") 
    {
        unless ($can_view) {
            return "<b>[Error: you don't have access to view these poll results]</b>";
        }

        my $qid = $opts->{'qid'}+0;
        $sth = $dbr->prepare("SELECT type, qtext FROM pollquestion WHERE pollid=$pollid AND pollqid=$qid");
        $sth->execute;
        my $q = $sth->fetchrow_hashref;
        unless ($q) {
            return "<b>[Error: this poll question doesn't exist.]</b>";
        }

        my %it;
        $sth = $dbr->prepare("SELECT pollitid, item FROM pollitem WHERE pollid=$pollid AND pollqid=$qid");
        $sth->execute;
        while (my ($itid, $item) = $sth->fetchrow_array) {
            $it{$itid} = $item;
        }

        clean_poll(\$q->{'qtext'});
        $ret .= $q->{'qtext'};
        $ret .= "<p>";

        $sth = $dbr->prepare("SELECT u.user, pr.value FROM user u, pollresult pr, pollsubmission ps WHERE u.userid=pr.userid AND pr.pollid=$pollid AND pollqid=$qid AND ps.pollid=$pollid AND ps.userid=pr.userid ORDER BY ps.datesubmit");
        $sth->execute;

        while (my ($user, $value) = $sth->fetchrow_array) 
        {
            clean_poll(\$value);

            ## some question types need translation; type 'text' doesn't.
            if ($q->{'type'} eq "radio" || $q->{'type'} eq "drop") {
                $value = $it{$value};
            }
            elsif ($q->{'type'} eq "check") {
                $value = join(", ", map { $it{$_} } split(/,/, $value));
            }

            $ret .= "<p>" . LJ::ljuser($user) . " -- $value";
        }
        
        return $ret;
    }

    ### show a poll form, or the result to it.

    unless ($mode) 
    {
        # need to choose a mode
        #
        
        if ($remote)
        {
            $sth = $dbr->prepare("SELECT pollid FROM pollsubmission WHERE pollid=$pollid AND userid=$remote->{'userid'}");
            $sth->execute;
            my ($cast) = $sth->fetchrow_array;
            if ($cast) { $mode = "results"; }
            else {
                if ($can_vote) { $mode = "enter"; }
                else { $mode = "results"; }
            }
        } else {
            $mode = "results";
        }
    }

    my $do_form = ($mode eq "enter" && $can_vote);
    my %preval;
    if ($do_form) {
        $sth = $dbr->prepare("SELECT pollqid, value FROM pollresult WHERE pollid=$pollid AND userid=$remote->{'userid'}");
        $sth->execute;
        while (my ($qid, $value) = $sth->fetchrow_array) {
            $preval{$qid} = $value;
        }
    }

    if ($do_form)
    {
        # this id= is only for people bookmarking it.  
        # it does nothing, since POST is being used
        $ret .= "<form action=\"$LJ::SITEROOT/poll/?id=$pollid\" method='post'>";
        $ret .= "<input type='hidden' name='pollid' value='$pollid'>";
    }
    $ret .= "<b><a href=\"$LJ::SITEROOT/poll/?id=$pollid\">Poll \#$pollid:</a></b> ";
    if ($po->{'name'}) {
        clean_poll(\$po->{'name'});
        $ret .= "<i>$po->{'name'}</i>";
    }
    $ret .= "<br>Open to: <b>$po->{'whovote'}</b>, results viewable to: <b>$po->{'whoview'}</b>";

    ### load all the questions
    my @qs;
    $sth = $dbr->prepare("SELECT pollqid, type, opts, qtext FROM pollquestion WHERE pollid=$pollid ORDER BY sortorder");
    $sth->execute;
    push @qs, $_ while ($_ = $sth->fetchrow_hashref);
    $sth->finish;

    ### load all the items
    my %its;
    $sth = $dbr->prepare("SELECT pollqid, pollitid, item FROM pollitem WHERE pollid=$pollid ORDER BY sortorder");
    $sth->execute;
    while (my ($qid, $itid, $item) = $sth->fetchrow_array) {
        push @{$its{$qid}}, [ $itid, $item ];
    }
    $sth->finish;

    ## go through all questions, adding to buffer to return
    foreach my $q (@qs)
    {
        my $qid = $q->{'pollqid'};
        clean_poll(\$q->{'qtext'});
        $ret .= "<p>$q->{'qtext'}<blockquote>";
        
        ### get statistics, for scale questions
        my ($valcount, $valmean, $valstddev, $valmedian);
        if ($q->{'type'} eq "scale") 
        {
            ## manually add all the possible values, since they aren't in the database
            ## (which was the whole point of making a "scale" type):
            my ($from, $to, $by) = split(m!/!, $q->{'opts'});
            $by = 1 unless ($by > 0 and int($by) == $by);
            for (my $at=$from; $at<=$to; $at+=$by) {
                push @{$its{$qid}}, [ $at, $at ];  # note: fake itemid, doesn't matter, but needed to be unique
            }

            $sth = $dbr->prepare("SELECT COUNT(*), AVG(value), STDDEV(value) FROM pollresult WHERE pollid=$pollid AND pollqid=$qid");
            $sth->execute;
            ($valcount, $valmean, $valstddev) = $sth->fetchrow_array;
            
            # find median:
            $valmedian = 0;
            if ($valcount == 1) { 
                $valmedian = $valmean;
            } elsif ($valcount > 1) {
                my ($mid, $fetch);
                # fetch two mids and average if even count, else grab absolute middle
                $fetch = ($valcount % 2) ? 1 : 2;
                $mid = int(($valcount+1)/2);
                my $skip = $mid-1;
                my $sql = "SELECT value FROM pollresult WHERE pollid=$pollid AND pollqid=$qid ORDER BY value+0 LIMIT $skip,$fetch";
                $sth = $dbr->prepare($sql);
                $sth->execute;
                while (my ($v) = $sth->fetchrow_array) {
                    $valmedian += $v;
                }
                $valmedian /= $fetch;
            }
        }

        my $usersvoted = 0;
        my %itvotes;
        my $maxitvotes = 1;

        if ($mode eq "results") 
        {
            ### to see individual's answers
            $ret .= "<a href=\"$LJ::SITEROOT/poll/?id=$pollid&amp;qid=$qid&amp;mode=ans\">View Answers</a><br>";

            ### but, if this is a non-text item, and we're showing results, need to load the answers:
            $sth = $dbr->prepare("SELECT COUNT(DISTINCT(userid)) FROM pollresult WHERE pollid=$pollid AND pollqid=$qid");
            $sth->execute;
            ($usersvoted) = $sth->fetchrow_array;

            $sth = $dbr->prepare("SELECT value, COUNT(*) FROM pollresult WHERE pollid=$pollid AND pollqid=$qid GROUP BY value");
            $sth->execute;
            while (my ($val, $count) = $sth->fetchrow_array) {
                if ($q->{'type'} eq "check") {
                    foreach (split(/,/,$val)) {
                        $itvotes{$_} += $count;
                    }
                } else {
                    $itvotes{$val} += $count;
                }
            }

            foreach (values %itvotes) {
                $maxitvotes = $_ if ($_ > $maxitvotes);
            }
            
        }

        #### text questions are the easy case

        if ($q->{'type'} eq "text") {
            my ($size, $max) = split(m!/!, $q->{'opts'});
            if ($mode eq "enter") {
                if ($do_form) {
                    my $pval = LJ::eall($preval{$qid});
                    $ret .= "<input type=text size=$size maxlength=$max name=\"pollq-$qid\" value=\"$pval\">";
                } else {
                    $ret .= "[" . ("&nbsp;"x$size) . "]";
                }
            }
        }

        ##### scales (from 1-10) questions

        elsif ($q->{'type'} eq "scale" && $mode ne "results") {
            my ($from, $to, $by) = split(m!/!, $q->{'opts'});
            $by ||= 1;
            my $count = int(($to-$from)/$by) + 1;
            my $do_radios = ($count <= 11);

            if ($do_radios) {
                $ret .= "<table><tr valign=top align=center>";
            } else {
                if ($do_form) { 
                    $ret .= "<select name=\"pollq-$qid\"><option value=\"\">";		    
                }
            }

            for (my $at=$from; $at<=$to; $at+=$by) {
                if ($do_radios) {
                    if ($do_form) {
                        my $sel = ($at == $preval{$qid}) ? " CHECKED" : "";
                        $ret .= "<td><input type=radio value=$at name=\"pollq-$qid\"$sel><br>$at</td>";
                    } else {
                        $ret .= "<td>(&nbsp;&nbsp;)<br>$at</td>";
                    }
                } else {
                    if ($do_form) {
                        my $sel = ($at == $preval{$qid}) ? " SELECTED" : "";
                        $ret .= "<option value=\"$at\">$at";
                    } 
                }
            }

            if ($do_radios) {
                $ret .= "</tr></table>";
            } else {
                if ($do_form) { 
                    $ret .= "</select>";
                }
            }
            }

        #### now, questions with items

        else
        {
            if ($do_form && $q->{'type'} eq "drop") {
                $ret .= "<select name=\"pollq-$qid\"><option value=\"\">";	
            }

            my $do_table = 0;

            if ($q->{'type'} eq "scale") {
                my $stddev = sprintf("%.2f", $valstddev);
                my $mean = sprintf("%.2f", $valmean);
                $ret .= "<b>Mean:</b> $mean <b>Median:</b> $valmedian <b>Std. Dev:</b> $stddev<br>";
                $do_table = 1;
            }

            if ($do_table) {
                $ret .= "<table>";
            }

            foreach my $it (@{$its{$qid}})
            {
                my ($itid, $item) = @$it;
                clean_poll(\$item);

                if ($mode eq "enter") {
                    if ($q->{'type'} eq "drop") {
                        my $sel = ($itid == $preval{$qid}) ? " SELECTED" : "";
                        $ret .= "<option value=\"$itid\"$sel>$item";
                    } elsif ($q->{'type'} eq "check") {
                        my $sel = ($preval{$qid} =~ /\b$itid\b/) ? " CHECKED" : "";
                        $ret .= "<input type=checkbox value=$itid name=\"pollq-$qid\"$sel> $item<br>";
                    } elsif ($q->{'type'} eq "radio") {
                        my $sel = ($itid == $preval{$qid}) ? " CHECKED" : "";
                        $ret .= "<input type=radio value=$itid name=\"pollq-$qid\"$sel> $item<br>";
                    }
                }
                elsif ($mode eq "results") 
                {
                    my $count = $itvotes{$itid}+0;
                    my $percent = sprintf("%.1f", (100 * $count / ($usersvoted||1)));
                    my $width = 20+int(($count/$maxitvotes)*380);

                    if ($do_table) {
                        $ret .= "<tr valign=middle><td align=right>$item</td>";
                        $ret .= "<td><img src=\"$LJ::IMGPREFIX/poll/leftbar.gif\" align=absmiddle height=14 width=7>";
                        $ret .= "<img src=\"$LJ::IMGPREFIX/poll/mainbar.gif\" align=absmiddle height=14 width=$width alt=\"$count ($percent%)\">";
                        $ret .= "<img src=\"$LJ::IMGPREFIX/poll/rightbar.gif\" align=absmiddle height=14 width=7> ";
                        $ret .= "<b>$count</b> ($percent%)</td></tr>";
                    } else {
                        $ret .= "<p>$item<br>";
                        $ret .= "<nobr><img src=\"$LJ::IMGPREFIX/poll/leftbar.gif\" align=absmiddle height=14 width=7>";
                        $ret .= "<img src=\"$LJ::IMGPREFIX/poll/mainbar.gif\" align=absmiddle height=14 width=$width alt=\"$count ($percent%)\">";
                        $ret .= "<img src=\"$LJ::IMGPREFIX/poll/rightbar.gif\" align=absmiddle height=14 width=7> ";
                        $ret .= "<b>$count</b> ($percent%)</nobr>";
                    }
                        
                }

            }

            if ($do_table) {
                $ret .= "</table>";
            }

            if ($do_form && $q->{'type'} eq "drop") {
                $ret .= "</select>";
            }
        }


        $ret .= "</blockquote>";
    }
    
    if ($do_form) {
        $ret .= "<input type=submit name=\"poll-submit\" value=\"Submit Poll\"></form>";
    }    
    
    return $ret;
}

sub find_security
{
    my $dbs = shift;
    my $dbr = $dbs->{'reader'};
    my $po = shift;
    my $remote = shift;
    my $sth;

    ## if remote is poll owner, can do anything.
    if ($remote && $remote->{'userid'} == $po->{'posterid'}) {
        return (1, 1);
    }

    ## need to be both a person and with a visible journal to vote
    LJ::load_remote($dbs, $remote);
    unless ($remote->{'journaltype'} eq "P" && $remote->{'statusvis'} eq "V") {
        return (0, 0);
    }

    my $is_friend = 0;
    if (($po->{'whoview'} eq "friends" || 
         $po->{'whovote'} eq "friends") && $remote)
    {
        $is_friend = LJ::is_friend($dbs, $po->{'journalid'}, $remote->{'userid'});
    }

    my %sec;
    if ($po->{'whoview'} eq "all" ||
        ($po->{'whoview'} eq "friends" && $is_friend) ||
        ($po->{'whoview'} eq "none" && $remote && $remote->{'userid'} == $po->{'posterid'}))
    {
        $sec{'view'} = 1;
    }

    if ($po->{'whovote'} eq "all" ||
        ($po->{'whovote'} eq "friends" && $is_friend))
    {
        $sec{'vote'} = 1;
    }

    if (LJ::is_banned($dbs, $remote, $po->{'journalid'})) {
        $sec{'vote'} = 0;
    }
    
    if (LJ::is_banned($dbs, $remote, $po->{'posterid'})) {
        $sec{'vote'} = 0;
    }
    
    return ($sec{'vote'}, $sec{'view'});
}

sub submit
{
    my $dbs = shift;
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $remote = shift;
    my $form = shift;
    my $error = shift;
    my $sth;

    unless ($remote) {
        $$error = "You must be <a href=\"$LJ::SITEROOT/login.bml?ret=1\">logged in</a> to vote in a poll.";
        return 0;
    }

    my $pollid = $form->{'pollid'}+0;
    $sth = $dbr->prepare("SELECT itemid, whovote, journalid, posterid, whoview, whovote, name FROM poll WHERE pollid=$pollid");
    $sth->execute;
    my $po = $sth->fetchrow_hashref;
    unless ($po) {
        $$error = "pollid parameter is missing.";
        return 0;	
    }
    
    my ($can_vote, undef) = find_security($dbs, $po, $remote);

    unless ($can_vote) {
        $$error = "Sorry, you don't have permission to vote in this particular poll.";
        return 0;
    }

    ### load all the questions
    my @qs;
    $sth = $dbr->prepare("SELECT pollqid, type, opts, qtext FROM pollquestion WHERE pollid=$pollid");
    $sth->execute;
    push @qs, $_ while ($_ = $sth->fetchrow_hashref);
    $sth->finish;
    
    foreach my $q (@qs) {
        my $qid = $q->{'pollqid'}+0;
        my $val;
        $val = $form->{"pollq-$qid"};
        if ($q->{'type'} eq "check") {
            ## multi-selected items are comma separated from htdocs/poll/index.bml
            $val = join(",", sort { $a <=> $b } split(/,/, $val));
        }
        if ($q->{'type'} eq "scale") {
            my ($from, $to, $by) = split(m!/!, $q->{'opts'});
            if ($val < $from || $val > $to) { 
                # bogus! cheating?
                $val = "";
            }
        }
        if ($val ne "") {
            $val = $dbh->quote($val);
            $dbh->do("REPLACE INTO pollresult (pollid, pollqid, userid, value) VALUES ($pollid, $qid, $remote->{'userid'}, $val)");
        } else {
            $dbh->do("DELETE FROM pollresult WHERE pollid=$pollid AND pollqid=$qid AND userid=$remote->{'userid'}");
        }
    }
    
    ## finally, register the vote happened
    $dbh->do("REPLACE INTO pollsubmission (pollid, userid, datesubmit) VALUES ($pollid, $remote->{'userid'}, NOW())");

    return 1;
}

1;
