#!/usr/bin/perl
#

require "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";

use strict;
use HTML::TokeParser;

#     &LJ::CleanHTML::clean(\$u->{'bio'}, { 
#	 'wordlength' => 100,
#	 'addbreaks' => 1,
#	 'eat' => [qw(head title style layer iframe)],
#	 'mode' => 'allow',
#	 'deny' => [qw(marquee)],
#        'remove' => [qw()],
#        'maximgwidth' => 100,
#        'maximgheight' => 100,
#        'keepcomments' => 1,
#        'cuturl' => 'http://www.domain.com/full_item_view.ext',
#     });

package LJ::CleanHTML;

sub clean
{
    my $data = shift;
    my $opts = shift;
    my $newdata;
 
    my $p = HTML::TokeParser->new($data);

    my $wordlength = $opts->{'wordlength'};
    my $addbreaks = $opts->{'addbreaks'};
    my $keepcomments = $opts->{'keepcomments'};
    my $mode = $opts->{'mode'};
    my $cut = $opts->{'cuturl'};

    my %action = ();
    my %remove = ();
    if (ref $opts->{'eat'} eq "ARRAY") {
	foreach (@{$opts->{'eat'}}) { $action{$_} = "eat"; }
    }
    if (ref $opts->{'allow'} eq "ARRAY") {
	foreach (@{$opts->{'allow'}}) { $action{$_} = "allow"; }
    }
    if (ref $opts->{'deny'} eq "ARRAY") {
	foreach (@{$opts->{'deny'}}) { $action{$_} = "deny"; }
    }
    if (ref $opts->{'remove'} eq "ARRAY") {
	foreach (@{$opts->{'remove'}}) { $action{$_} = "deny"; $remove{$_} = 1; }
    }

    $action{'script'} = "eat";
    my @attrstrip = qw(onabort onblur onchange onclick onerror onfocus onload
		       onmouseout onmouseover onreset onselect onsubmit onunload);

    if (ref $opts->{'attrstrip'} eq "ARRAY") {
	foreach (@{$opts->{'attrstrip'}}) { push @attrstrip, $_; }
    }

    my %opencount = ();

  TOKEN:
    while (my $token = $p->get_token)
    {
	my $type = $token->[0];

	if ($type eq "S")     # start tag
	{
	    my $tag = $token->[1];

	    if ($action{$tag} eq "eat") {
		$p->unget_token($token);
		$p->get_tag("/$tag");
	    } 
	    elsif ($tag eq "lj-cut") 
	    {
		my $attr = $token->[2];
		if ($cut) {
		    my $text = "Read more...";
		    if ($attr->{'text'}) {
			$text = $attr->{'text'};
			$text =~ s/</&lt;/g;
			$text =~ s/>/&gt;/g;
		    }
		    $newdata .= "<nobr><b>( <a href=\"$cut\">$text</a> )</b></nobr>";
		    last TOKEN;
		} else {
		    next; # ignore the tag.
		}
	    }
	    elsif ($tag eq "lj") 
	    {
		my $attr = $token->[2];
		if ($attr->{'user'}) {
		    my $user = LJ::canonical_username($attr->{'user'});
		    if ($user) {
			$newdata .= "<a href=\"$LJ::SITEROOT/userinfo.bml?user=$user\"><img src=\"$LJ::IMGPREFIX/userinfo.gif\" WIDTH=17 HEIGHT=17 ALIGN=ABSMIDDLE border=0></a><b><a href=\"$LJ::SITEROOT/users/$user/\">$user</a></b>";
		    } else {
			$newdata .= "<b>[Bad username in LJ tag]</b>";
		    }
		} else {
		    $newdata .= "<b>[Unknown LJ tag]</b>";
		}
	    }
	    else 
	    {
		my $alt_output = 0;

		my $hash = $token->[2];
		foreach (@attrstrip) {
		    delete $hash->{$_};
		}

		foreach my $attr (qw(href content src dynsrc lowsrc))
		{
		    next unless (defined $hash->{$attr});
		    $hash->{$attr} =~ s/^lj:(?:\/\/)?(.*)$/ExpandLJURL($1)/ei;
		    if ($hash->{$attr} =~ /^\s*javascript:/i) { delete $hash->{$attr}; }
		}

		if ($tag eq "img") 
		{
		    # prevent people from making images pointing to URLs
		    # on the site where a GET action could be bad. (anywhere
		    # but the images directory).  also, force absolute URLs.
		    if (($hash->{'src'} !~ m!^http://!) ||
			(($hash->{'src'} =~ m!^http://$LJ::DOMAIN_RE/!) &&
			 ($hash->{'src'} !~ m!^http://$LJ::DOMAIN_RE/img/!) &&
			 ($hash->{'src'} !~ m!^http://$LJ::DOMAIN_RE/userpic/!)))
		    {
			$hash->{'src'} = "about:";
		    }
		    
		    my $img_bad = 0;
		    if ($opts->{'maximgwidth'} &&
			(! defined $hash->{'width'} ||
			 $hash->{'width'} > $opts->{'maximgwidth'})) { $img_bad = 1; }
		    if ($opts->{'maximgheight'} &&
			(! defined $hash->{'height'} ||
			 $hash->{'height'} > $opts->{'maximgheight'})) { $img_bad = 1; }

		    if ($img_bad) {
			$newdata .= "<a href=\"$hash->{'src'}\"><b>(Image Link)</b></a>";
			$alt_output = 1;
		    }
		}

		unless ($alt_output)
		{
		    my $allow;
		    if ($mode eq "allow") {
			$allow = 1;
			if ($action{$tag} eq "deny") { $allow = 0; }
		    } else {
			$allow = 0;
			if ($action{$tag} eq "allow") { $allow = 1; }
		    }

		    if ($allow && ! $remove{$tag})
		    {
			if ($allow) { $newdata .= "<$tag"; }
			else { $newdata .= "&lt;$tag"; }
			foreach (keys %$hash) {
			    $newdata .= " $_=\"$hash->{$_}\"";
			}
			if ($allow) { $newdata .= ">"; }
			else { $newdata .= "&gt;"; }

			$opencount{$tag}++;
		    }
		}
	    }
	}
	elsif ($type eq "E") 
	{
	    my $tag = $token->[1];

	    my $allow;
	    if ($mode eq "allow") {
		$allow = 1;
		if ($action{$tag} eq "deny") { $allow = 0; }
	    } else {
		$allow = 0;
		if ($action{$tag} eq "allow") { $allow = 1; }
	    }
	    
	    if ($allow && ! $remove{$tag})
	    {
		if ($allow) {
		    $newdata .= "</$tag>";
		    $opencount{$tag}--;
		} else { $newdata .= "&lt;$tag&gt;"; }
	    }
	}
	elsif ($type eq "T" || $type eq "D") {
	    my %url = ();
	    my $urlcount = 0;

	    if ($addbreaks && ! $opencount{'a'}) {
		$token->[1] =~ s!http://[a-z0-9A-Z_\-\.\/\?\%\+\=\~\:\;\#\&\,]+!$url{++$urlcount}=$&;"\{url$urlcount\}";!eg;
	    }
	    if ($wordlength) {
		# this treats normal characters and &entities; as single characters
		$token->[1] =~ s/(([^&\s]|(&.{1,7};)){$wordlength})\B/$1<wbr>/g;
	    } 
	    if ($addbreaks) {
		$token->[1] =~ s/\n/<br>/g;
		if (! $opencount{'a'}) {
		    $token->[1] =~ s/\{url(\d+)\}/<a href=\"$url{$1}\">$url{$1}<\/a>/g;
		}
	    }
	    
	    ## the HTML tokenizer returns half-broken comments as text, so
	    ## want to make sure we delete any comment starts we see until
	    ## the end, since they could both be used to comment out the 
	    ## remainder of the page and also to sneak in back HTML/scripting
	    $token->[1] =~ s/<!--.*//s;

	    $newdata .= $token->[1];
	} 
	elsif ($type eq "C") {
	    # by default, ditch comments
	    if ($keepcomments) {
		$newdata .= $token->[1];
	    }
	}
	elsif ($type eq "PI") {
	    $newdata .= "<?$token->[1]>";
	}
	else {
	    $newdata .= "<!-- OTHER: " . $type . "-->\n";
	}
    } # end while

#    if ($opts->{'addbreaks'}) {
#	$newdata =~ s/^( {1,10})/"&nbsp;&nbsp;"x length($1)/eg;
#	$newdata =~ s/\n( {1,10})/"\n" . "&nbsp;&nbsp;"x length($1)/eg;
#    }

    if (ref $opts->{'autoclose'} eq "ARRAY") {
	foreach my $tag (@{$opts->{'autoclose'}}) {
	    if ($opencount{$tag}) {
		$newdata .= "</$tag>" x $opencount{$tag};
	    }
	}
    }


    $$data = $newdata;
}

sub ExpandLJURL 
{
    my @args = grep { $_ } split(/\//, $_[0]);
    my $mode = shift @args;

    if ($mode eq 'user')
    {
	my $url;
	my $user = shift @args;
	$user = LJ::canonical_username($user);
	if ($args[0] eq "profile") {
	    $url = "$LJ::SITEROOT/userinfo.bml?user=$user";
	} else {
	    $url = "$LJ::SITEROOT/users/$user/";
	    foreach (@args) {
		$url .= "$_/";
	    }
	}
	return $url;
    }
    
    if ($mode eq 'support') 
    {
	if ($args[0]) {
	    my $id = $args[0]+0;
	    return "$LJ::SITEROOT/support/see_request.bml?id=$id";
	} else {
	    return "$LJ::SITEROOT/support/";
	}
    }

    if ($mode eq 'faq') 
    {
	if ($args[0]) {
	    my $id = $args[0]+0;
	    return "$LJ::SITEROOT/support/faqbrowse.bml?faqid=$id";
	} else {
	    return "$LJ::SITEROOT/support/faq.bml";
	}
    }

    return "$LJ::SITEROOT/";
}

my $subject_eat = [qw[head title style layer iframe applet object]];
my $subject_allow = [qw[a b i u]];
my $subject_remove = [qw[bgsound embed object caption link font]];
sub clean_subject
{
    my $ref = shift;
    clean($ref, {
	'wordlength' => 40,
	'addbreaks' => 0,
	'eat' => $subject_eat,
	'mode' => 'deny',
	'allow' => $subject_allow,
	'remove' => $subject_remove,
    });
}

## returns a pure text subject (needed in links, email headers, etc...)
my $subjectall_eat = [qw[head title style layer iframe applet object]];
sub clean_subject_all
{
    my $ref = shift;
    clean($ref, {
	'wordlength' => 40,
	'addbreaks' => 0,
	'eat' => $subjectall_eat,
	'mode' => 'deny',
    });
}

my $event_eat = [qw[head title style layer iframe applet object]];
my $event_remove = [qw[bgsound embed object caption link body]];

my @comment_close = qw(a b i u ul ol s font tt blockquote pre sub sup code strong em big small center h1 h2 h3 table tr td strike dl cite xmp th marquee);
my @comment_all = (@comment_close, "img", "li", "br", "dd", "dt", "hr", "p");

sub clean_event
{
    my $ref = shift;
    my $opts = shift;

    # old prototype was passing in the ref and preformatted flag.
    # now the second argument is a hashref of options, so convert it to support the old way.
    unless (ref $opts eq "HASH") {
	$opts = { 'preformatted' => $opts };
    }

    clean($ref, {
	'linkify' => 1,
	'wordlength' => 40,
	'addbreaks' => $opts->{'preformatted'} ? 0 : 1,
	'cuturl' => $opts->{'cuturl'},
	'eat' => $event_eat,
	'mode' => 'allow',
	'remove' => $event_remove,
	'autoclose' => \@comment_close,
    });
}

sub get_okay_comment_tags
{
    return @comment_all;
}

sub clean_comment
{
    my $ref = shift;
    my $preformatted = shift;

    clean($ref, {
	'linkify' => 1,
	'wordlength' => 40,
	'addbreaks' => $preformatted ? 0 : 1,
	'eat' => [qw[head title style layer iframe applet object]],
	'mode' => 'deny',
	'allow' => \@comment_all,
	'autoclose' => \@comment_close,
    });
}
