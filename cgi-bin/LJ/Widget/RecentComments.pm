package LJ::Widget::RecentComments;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub need_res { }

# args
#   user: optional $u whose recent received comments we should get (remote is default)
#   limit: number of recent comments to show, or 3
sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $opts{user} && LJ::isu($opts{user}) ? $opts{user} : LJ::get_remote();
    return "" unless $u;

    my $limit = defined $opts{limit} ? $opts{limit} : 3;

    my @comments = $u->get_recent_talkitems($limit, memcache => 1);

    my $ret;

    $ret .= "<h2>" . $class->ml('widget.recentcomments.title') . "</h2>";
    $ret .= "<a href='$LJ::SITEROOT/tools/recent_comments.bml'>&raquo; " . $class->ml('widget.recentcomments.viewall') . "</a>";

    # return if no comments
    return "<p>" . $class->ml('widget.recentcomments.nocomments', {'aopts' => "href='$LJ::SITEROOT/update.bml'"}) . "</p>"
        unless @comments && defined $comments[0];

    # there are comments, print them
    @comments = reverse @comments; # reverse the comments so newest is printed first
    $ret .= "<div>";
    foreach my $row (@comments) {
        next unless $row->{nodetype} eq 'L';

        # load the comment
        my $comment = LJ::Comment->new($u, jtalkid => $row->{jtalkid});
        next if $comment->is_deleted;

        # load the comment poster
        my $posteru = $comment->poster;
        next if $posteru && ($posteru->is_suspended || $posteru->is_expunged);
        my $poster = $posteru ? $posteru->ljuser_display : $class->ml('widget.recentcomments.anon');

        # load the entry the comment was posted to
        my $entry = $comment->entry;

        # print the comment
        $ret .= "<p>";
        $ret .= $comment->poster_userpic;
        $ret .= $class->ml('widget.recentcomments.commentheading', {'poster' => $poster, 'entry' => "<a href='" . $entry->url . "'>"});
        $ret .= $entry->subject_text ? $entry->subject_text : $class->ml('widget.recentcomments.nosubject');
        $ret .= "</a><br />";
        $ret .= substr($comment->body_text, 0, 250) . "<br />";
        $ret .= "(<a href='" . $comment->url . "'>" . $class->ml('widget.recentcomments.link') . "</a>) ";
        $ret .= "</p>";

    }
    $ret .= "</div>";

    return $ret;
}

1;
