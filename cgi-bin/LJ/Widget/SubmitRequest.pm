package LJ::Widget::SubmitRequest;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub need_res { }

# opts:
#  category -> the category to be selected
#  spid     -> comes from handle_post, spid of req this generated
#  nolink   -> whether to provide the user with the request #

sub render_body {
    my $class = shift;
    my %opts = @_;

    # then we're done
    if ($opts{spid}) {
        return "Thank you!" if $opts{nolink};

        my $url = "$LJ::SITEROOT/support/see_request.bml?id=$opts{spid}";
        return "Your request has been filed. Your tracking number is $opts{spid}. "
            . "You can track the progress of your request at: <blockquote><a href='$url'>$url</a></blockquote>";
    }

    my $remote = LJ::get_remote();
    my $ret = $class->start_form;

    unless ($remote) {
        $ret .= "<?p <em>If you're a $LJ::SITENAMESHORT user, <a href='$LJ::SITEROOT/login.bml?ret=1'>please log in</a> before submitting your request.</em> p?>";

        $ret .= "<p><b>Your name:</b><br />";
        $ret .= "<div style='margin-left: 30px'>";
        $ret .= $class->html_text(name => 'reqname', size => '40', maxlength => '50');
        $ret .= "</div></p>";

        $ret .= "<p><b>Your email address:</b><br />";
        $ret .= "<div style='margin-left: 30px'>";
        $ret .= $class->html_text(name => 'email', size => '30', maxlength => '70');
        $ret .= "<?de (not shown to the public) de?></div></p>";
     };

    my $cats = LJ::Support::load_cats();
    if (my $cat = LJ::Support::get_cat_by_key($cats, $opts{category})) {
        $ret .= $class->html_hidden("spcatid" => $cat->{spcatid});
    } else {
        $ret .= "<p><b>Category:</b><br />";
        $ret .= "<div style='margin-left: 30px'>";

        my @choices;
        foreach (sort { $a->{sortorder} <=> $b->{sortorder} } values %$cats) {
            next unless $_->{is_selectable};
            push @choices, $_->{spcatid}, $_->{catname};
        }

        $ret .= $class->html_select(name => 'spcatid', list => \@choices);
        $ret .= "</div></p>";
    }

    $ret .= "<p><b>Summary:</b><br />";
    $ret .= "<div style='margin-left: 30px'>";
    $ret .= $class->html_text(name => 'subject', size => '40', maxlength => '80');
    $ret .= "</div></p>";

    $ret .= "<p><b>Question or Problem:</b><br />";
    $ret .= "<div style='margin-left: 30px'>";
    $ret .= "<p><?de Do not include any sensitive information, such as your password. de?></p>";
    $ret .= $class->html_textarea(name => 'message', rows => '15', cols => '70', wrap => 'soft');
    $ret .= "</div><br />";

    $ret .= "<?standout <input type='submit' value='Submit Request' /> standout?>";
    $ret .= $class->end_form;

    return $ret;
}


sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    my ($u, $user, %req, @errors);
    my $remote = LJ::get_remote();

    if ($remote) {
        $req{'reqtype'} = "user";
        $req{'requserid'} = $remote->id;
        $req{'reqemail'} = $remote->email_raw;
        $req{'reqname'} = $remote->name_html;

    } else {
        $req{'reqtype'} = "email";
        $req{'reqemail'} = $post->{'email'};
        $req{'reqname'} = $post->{'reqname'};

        LJ::check_email($post->{'email'}, \@errors);
    }

    $req{'body'} = $post->{'message'};
    $req{'subject'} = $post->{'subject'};
    $req{'spcatid'} = $post->{'spcatid'};
    $req{'uniq'} = LJ::UniqCookie->current_uniq;

    # don't autoreply if they aren't gonna get a link
    $req{'no_autoreply'} = $opts{nolink} ? 1 : 0;

    # insert diagnostic information
    $req{'useragent'} = BML::get_client_header('User-Agent')
        if $LJ::SUPPORT_DIAGNOSTICS{track_useragent};

    $class->error_list(@errors) && return;
    my $spid = LJ::Support::file_request(\@errors, \%req);
    $class->error_list(@errors);

    return ('spid' => $spid);
}

sub error_list {
    my ($class, @errors) = @_;
    return 0 unless @errors;

    $class->error($_) foreach @errors;
    return 1;
}

1;
