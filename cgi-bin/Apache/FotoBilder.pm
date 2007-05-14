#!/usr/bin/perl
#

package Apache::FotoBilder;

use strict;
use Apache::Constants qw(:common REDIRECT HTTP_NOT_MODIFIED
                         HTTP_MOVED_TEMPORARILY HTTP_MOVED_PERMANENTLY);
use Apache::File ();
use XMLRPC::Transport::HTTP ();
use lib "$ENV{'FBHOME'}/cgi-bin";

# image serving
use Apache::FotoBilder::Pic;
use Apache::FotoBilder::DynamicImg;

# s2-land
use Apache::FotoBilder::IndexPage;
use Apache::FotoBilder::GalleryPage;
use Apache::FotoBilder::PicturePage;
use Apache::FotoBilder::StyleSheet;

# xml info pages
use Apache::FotoBilder::XMLPicInfoPage;
use Apache::FotoBilder::XMLGalleryInfoPage;

our %RQ;

# init handler (PostReadRequest)
sub handler
{
    my $r = shift;
    $r->set_handlers(PerlTransHandler => [ \&trans ]);
    $r->set_handlers(PerlCleanupHandler => [ sub { %RQ = () },
                                             "Apache::FotoBilder::cleanup_tempfiles" ]);

    # if we're behind a lite mod_proxy front-end, we need to trick future handlers
    # into thinking they know the real remote IP address.  problem is, it's complicated
    # by the fact that mod_proxy did nothing, requiring mod_proxy_add_forward, then
    # decided to do X-Forwarded-For, then did X-Forwarded-Host, so we have to deal
    # with all permutations of versions, hence all the ugliness:
    if (my $forward = $r->header_in('X-Forwarded-For'))
    {
        my (@hosts, %seen);
        foreach (split(/\s*,\s*/, $forward)) {
            next if $seen{$_}++;
            push @hosts, $_;
        }
        if (@hosts) {
            my $real = pop @hosts;
            $r->connection->remote_ip($real);
        }
        $r->header_in('X-Forwarded-For', join(", ", @hosts));
    }

    # and now, deal with getting the right Host header
    if ($_ = $r->header_in('X-Host')) {
        $r->header_in('Host', $_);
    } elsif ($_ = $r->header_in('X-Forwarded-Host')) {
        $r->header_in('Host', $_);
    }

    return OK;
}

sub redir
{
    my ($r, $url, $code) = @_;
    $r->content_type("text/html");
    $r->header_out(Location => $url);
    return $code || REDIRECT;
}

sub trans
{
    my $r = shift;
    my $uri = $r->uri;
    my $args = $r->args;
    my $args_wq = $args ? "?$args" : "";
    my $host = $r->header_in("Host");
    my $hostport = ($host =~ s/:\d+$//) ? $& : "";
    my $siteroot = FB::siteroot();

    FB::start_request();
    S2::set_domain('Fotobilder');

    # check domainid, run hooks, blah, set pnotes
    my $bml_env_or = {};
    FB::run_hooks("trans_bml_overrides", $r, $bml_env_or);
    $r->pnotes(BMLEnvOverride => $bml_env_or);

    $FB::IMGPREFIX = $FB::IMGPREFIX_BAK;

    # TODO: make more like LJ redirections (caching etc)
    if ($uri eq "/__setdomsess") {
        return redir($r, LJ::Session->setdomsess_handler($r));
    }
    my $burl;
    my $sessobj = LJ::Session->session_from_cookies(redirect_ref => \$burl);
    return redir($r, $burl, HTTP_MOVED_TEMPORARILY) if $burl;

    # let foo.com still work, but redirect to www.foo.com
    if ($FB::DOMAIN_WEB && $r->method eq "GET" &&
        $host eq $FB::DOMAIN && $FB::DOMAIN_WEB ne $FB::DOMAIN) {
        return redir($r, "$siteroot$uri$args_wq");
    }

    if (FB::are_hooks("http_extra_trans")) {
        my $res = FB::run_hook("http_extra_trans", $uri);
        if (ref $res eq 'CODE') {
            $r->handler("perl-script");
            $r->push_handlers(PerlHandler => $res);
            return OK;
        }
    }

    # /~user -> /user
    if ($uri =~ m#^/\~([\w-]+)#) {
        return redir($r, "$1.$LJ::SITEROOT/media");
    }

    # decide if it's for a BML page or not
    my ($topdir, $rest) = $uri =~ m!^/(\w+)(.*)!;

    # $single-user installation support
    my $single_user = 0;
    if ($FB::ROOT_USER) {
        if ($uri eq "/") {
            $single_user = 1;
            $rest = "/";
            $topdir = $FB::ROOT_USER;
        } elsif ($topdir eq "gallery" || $topdir eq "pic" || $topdir eq "res" || $topdir eq "tags") {
            $single_user = 1;
            $rest = $uri;
            $topdir = $FB::ROOT_USER;
        }
    }

    # an actual on-disk file perhaps?
    if ($FB::RESERVED_DIR{$topdir} && ! $single_user)  {
        # an on-disk image we're going to be transforming probably:
        if ($topdir eq "img") {
            $r->handler("perl-script");
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::Pic::img_dir);
            return OK;
        }

        # /dir -> /dir/
        if ($rest eq "" && -d "$FB::HOME/htdocs/$topdir") {
            return redir($r, "/$topdir/");
        }

        return DECLINED;
    }

    # probably for user:
    if ($topdir || $single_user) {
        my ($subdomain) = $host =~ /^([\w\-]{1,15})\.\Q$LJ::USER_DOMAIN\E$/;
        $FB::ROOT_USER = $subdomain if $subdomain;

        if ($rest =~ m!^/pic/.+\.xml$!) {
            # picture XMLInfo page
            $r->handler('perl-script');
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::XMLPicInfoPage::handler);
            return OK;
        } elsif ($rest =~ m!^/(gallery|tags?)/.+\.xml$!) {
            # gallery XMLInfo page
            $r->handler('perl-script');
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::XMLGalleryInfoPage::handler);
            return OK;
        } elsif ($topdir =~ /^media/ && (! $rest || $rest eq '/')) {
            $r->handler("perl-script");
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::IndexPage::handler);
        } elsif ($rest =~ m!^/pic!) {
            $r->handler("perl-script");
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::Pic::handler);
            return OK;
        } elsif ($topdir && $rest =~ m!^/?$!) {
            $r->handler("perl-script");
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::IndexPage::handler);
            return OK;
        } elsif ($topdir && $rest =~ m!^/(gallery|tags?)/!) {
            $r->handler("perl-script");
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::GalleryPage::handler);
            return OK;
        } elsif ($topdir && $rest =~ m!^/res/\d+/stylesheet$!) {
            $r->handler("perl-script");
            $r->push_handlers(PerlHandler => \&Apache::FotoBilder::StyleSheet::handler);
            return OK;
        }
    }

    return DECLINED;
}

sub cleanup_tempfiles
{
    my $r = shift;

    my $tempfiles = $r->pnotes('tempfiles');
    return OK unless $tempfiles && ref $tempfiles eq 'ARRAY';

    # unlink any tempfiles noted by application as needing deletion
    unlink $_ foreach @$tempfiles;

    return OK;
}

1;
