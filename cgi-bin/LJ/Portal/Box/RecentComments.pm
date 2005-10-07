package LJ::Portal::Box::RecentComments; # <--- Change this
use base 'LJ::Portal::Box';
use strict;

######################## override this stuff ######################

our $_box_class = "RecentComments";
our $_prop_keys = { 'maxshow' => 1 };
our $_config_props = {
    'maxshow' => { 'type'      => 'integer',
                   'desc'      => 'Maximum number of recent comments to display',
                   'max'       => 15,
                   'min'       => 1,
                   'maxlength' => 2,
                   'default'   => 5,
               },
};
our $_box_description = 'Show latest comments received';
our $_box_name = "Recent Comments";

our $cmtinfodata = {};

sub generate_content {
    my $self = shift;
    my $content = '';
    my $u = $self->{'u'};

    my $pboxid = $self->pboxid;

    my $count = 0;
    my %logrow;

    my $maxshow = $self->get_prop('maxshow');

    if (!LJ::get_cap($u, "tools_recent_comments_display")) {
        return "Sorry, your account type cannot view recent comments.";
    }

    my (@recv, @posted, %talkids);
    my %need_userid;
    my %need_logids;  # hash of "journalid jitemid" => [journalid, jitemid]

    my $jargent = "journal=$u->{'user'}&amp;";

    # Retrieve received
    @recv = $u->get_recent_talkitems(int(($maxshow * 3) / 2) + 1);
    foreach my $post (@recv) {
        $need_userid{$post->{posterid}} = 1 if $post->{posterid};
        $talkids{$post->{jtalkid}} = 1;
        $need_logids{"$u->{userid} $post->{nodeid}"} = [$u->{userid}, $post->{nodeid}]
            if $post->{nodetype} eq "L";
        $count++;
    }

    $count = ($count > $maxshow) ? $maxshow : $count;

    $content .= "<a href=\"$LJ::SITEROOT/tools/recent_comments.bml\">";
    $content .= (%talkids ? "Last $count comments posted in </a>" : "No comments have been posted in </a>") . LJ::ljuser($u) . ":<br />";

    @recv = sort { $b->{datepostunix} <=> $a->{datepostunix} } @recv;
    my @recv_talkids = map { $_->{'jtalkid'} } @recv;

    my %props;

    LJ::load_talk_props2($u->{'userid'}, \@recv_talkids, \%props);

    my $us = LJ::load_userids(keys %need_userid);

    # setup the parameter to get_logtext2multi
    my $need_logtext = {};
    foreach my $need (values %need_logids) {
        my $ju = $us->{$need->[0]};
        next unless $ju;
        push @{$need_logtext->{$ju->{clusterid}} ||= []}, $need;
    }

    my $comment_text = LJ::get_talktext2($u, keys %talkids);
    my $log_text     = LJ::get_logtext2multi($need_logtext);
    my $root = LJ::journal_base($u);

    my $commentcount = 0;

    my %LJ_cmtinfo;

    $LJ_cmtinfo{'canAdmin'} = 1;
    $LJ_cmtinfo{'remote'} = $u->{user};
    $LJ_cmtinfo{'journal'} = $u->{user};

    $content .= "<table style='width: 100%' cellpadding='5' cellspacing='0'>";
    foreach my $r (@recv) {
	next unless $r->{nodetype} eq "L";
        next if $r->{state} eq "D";

        last unless $commentcount++ < $maxshow;

        my $pu = $us->{$r->{posterid}};
        next if $pu && $pu->{statusvis} =~ /[XS]/;
        my $jtalkid = $r->{'jtalkid'};

        $r->{'props'} = $props{$jtalkid};

        my $lrow = $logrow{"$u->{userid} $r->{nodeid}"} ||= LJ::get_log2_row($u, $r->{'nodeid'});
        my ($subject, $body, $posterid) = (@{$comment_text->{$jtalkid}||[]}[0,1], $lrow->{posterid});

        $subject ||= '';
        $body ||= '(No comment text)';

        # trim comment body
        my $maxlen = 120;
        if (length($body) > $maxlen) {
            $body = substr($body, 0, $maxlen);
            $body .= '...';
        }

        my $date = LJ::ago_text(time() - $r->{'datepostunix'});

        my $talkid = ($r->{'jtalkid'} << 8) + $lrow->{'anum'};

        my $managebtns;
        my $ljcmt = $LJ_cmtinfo{$talkid} = {};
        $ljcmt->{u} = $pu ? $pu->{user} : "";

        unless ($r->{state} eq "D")
        {
            $managebtns .= "<a href='$LJ::SITEROOT/delcomment.bml?${jargent}id=$talkid'>" . LJ::img("btn_del", "", { 'align' => 'absmiddle', 'hspace' => 2, 'vspace' => }) . "</a>";
            if ($r->{'state'} ne 'F') {
                $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=freeze&amp;${jargent}talkid=$talkid'>" . LJ::img("btn_freeze", "", { align => 'absmiddle', hspace => 2, vspace => }) . "</a>";
            }

            if ($r->{'state'} eq 'F') {
                $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=unfreeze&amp;${jargent}talkid=$talkid'>" . LJ::img("btn_unfreeze", "", { align => 'absmiddle', hspace => 2, vspace => }) . "</a>";
            }

            if ($r->{'state'} ne 'S') {
                $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=screen&amp;${jargent}talkid=$talkid'>" . LJ::img("btn_scr", "", { 'align' => 'absmiddle', 'hspace' => 2, 'vspace' => }) . "</a>";
            }

            if ($r->{'state'} eq 'S') {
                 $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=unscreen&amp;${jargent}talkid=$talkid'>" . LJ::img("btn_unscr", "", { 'align' => 'absmiddle', 'hspace' => 2, 'vspace' => }) . "</a>";
             }
         }

        my $posturl  = "$root/$lrow->{ditemid}.html";
        my $replyurl = LJ::Talk::talkargs($posturl, "replyto=$talkid");
        my $talkurl  = "$root/$lrow->{ditemid}.html?thread=$talkid\#t$talkid";
        my $userlink = LJ::isu($pu) ? LJ::ljuser($pu) : "<i>(Anonymous)</i>";
        $content .= qq {
            <tr id="ljcmt$talkid">
                <td>

                  <span class="RecentCommentTitle">$userlink: $subject</span>
                  <span class="RecentCommentDate"><a href="$talkurl">$date</a></span>
                  <br style="clear: both;" />

                  <div class="RecentCommentItem">
                      $body
                      <div class="RecentCommentLinks">
                        $managebtns
                        <a href="$replyurl">Reply</a> | <a href="$posturl">Entry Link</a>
                      </div>
                  </div>
                </td>
            </tr>
        };
    }

    $content .= '</table>';

    $cmtinfodata = LJ::js_dumper(\%LJ_cmtinfo);

    $content .= qq {
        <script>
            LJ_cmtinfo = $cmtinfodata;
            current_pboxid = $pboxid;
        </script>
    };


    return $content;
}

# when box is reloaded, execute this javascript
sub box_updated {
    my $self = shift;
    my $pboxid = $self->pboxid;

    return qq {
        LJ_cmtinfo = $cmtinfodata;
        current_pboxid = $pboxid;
        setupAjax();
    };
}

# added by default if user has cap
sub default_added {
    my ($self, $u) = @_;
    if (LJ::isu($u)) {
        return LJ::get_cap($u, "tools_recent_comments_display");
    }
    return 0;
}

#######################################

sub can_refresh { 1; }
sub box_description { $_box_description; }
sub box_name { $_box_name; };
sub config_props { $_config_props; }
sub prop_keys { $_prop_keys; }
sub box_class { $_box_class; }

1;
