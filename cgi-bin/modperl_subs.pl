#!/usr/bin/perl
#

# to be require'd by modperl.pl

use strict;

package LJ;

use Apache2::ServerUtil ();

use Apache::LiveJournal;
use Apache::BML;
use Apache::SendStats;
use Apache::DebateSuicide;

use Digest::MD5;
use Text::Wrap ();
use LWP::UserAgent ();
use Storable;
use Time::HiRes ();
use Image::Size ();
use POSIX ();

use LJ::Portal ();
use LJ::Blob;
use LJ::Captcha;
use LJ::Faq;

use Class::Autouse qw(
                      DateTime
                      DateTime::TimeZone
                      LJ::CProd
                      LJ::OpenID
                      LJ::Location
                      LJ::SpellCheck
                      LJ::TextMessage
                      LJ::ModuleCheck
                      LJ::Widget
                      MogileFS::Client
                      DDLockClient
                      LJ::BetaFeatures
                      LJ::Config
                      );

LJ::Config->load;

# force XML::Atom::* to be brought in (if we have it, it's optional),
# unless we're in a test.
BEGIN {
    LJ::ModuleCheck->have_xmlatom unless LJ::is_from_test();
}

# in web context, Class::Autouse will load this, which loads MapUTF8.
# otherwise, we'll rely on the AUTOLOAD in ljlib.pl to load MapUTF8
use Class::Autouse qw(LJ::ConvUTF8);

# other things we generally want to load in web context, but don't need
# in testing context:  (not autoloaded normal ways)
use Class::Autouse qw(
                      MIME::Words
                      );

# Try to load DBI::Profile
BEGIN { $LJ::HAVE_DBI_PROFILE = eval "use DBI::Profile (); 1;" }

require "ljlang.pl";
require "htmlcontrols.pl";
require "weblib.pl";
require "imageconf.pl";
require "propparse.pl";
require "supportlib.pl";
require "supportstatslib.pl";
require "cleanhtml.pl";
require "talklib.pl";
require "ljtodo.pl";
require "ljfeed.pl";
require "ljlinks.pl";
require "emailcheck.pl";
require "ljmemories.pl";
require "ljmail.pl";
require "sysban.pl";
require "synlib.pl";
require "communitylib.pl";
require "taglib.pl";
require "schoollib.pl";
require "accountcodes.pl";
require "ljemailgateway-web.pl";
require "customizelib.pl";

# preload site-local libraries, if present:
require "$LJ::HOME/cgi-bin/modperl_subs-local.pl"
    if -e "$LJ::HOME/cgi-bin/modperl_subs-local.pl";

# defer loading of hooks, better that in the future, the hook loader
# will be smarter and only load in the *.pm files it needs to fulfill
# the hooks to be run
LJ::load_hooks_dir() unless LJ::is_from_test();

$LJ::IMGPREFIX_BAK = $LJ::IMGPREFIX;
$LJ::STATPREFIX_BAK = $LJ::STATPREFIX;
$LJ::USERPICROOT_BAK = $LJ::USERPIC_ROOT;

package LJ::ModPerl;

# pull in a lot of useful stuff before we fork children

sub setup_start {

    # auto-load some stuff before fork (unless this is a test program)
    unless ($0 && $0 =~ m!(^|/)t/!) {
        Storable::thaw(Storable::freeze({}));
        foreach my $minifile ("GIF89a", "\x89PNG\x0d\x0a\x1a\x0a", "\xFF\xD8") {
            Image::Size::imgsize(\$minifile);
        }
        DBI->install_driver("mysql");
        LJ::CleanHTML::helper_preload();
        LJ::Portal->load_portal_boxes;
    }

    # set this before we fork
    $LJ::CACHE_CONFIG_MODTIME = (stat("$LJ::HOME/cgi-bin/ljconfig.pl"))[9];

    eval { setup_start_local(); };
}

sub setup_restart {

    # setup httpd.conf things for the user:
    LJ::ModPerl::add_httpd_config("DocumentRoot $LJ::HTDOCS")
        if $LJ::HTDOCS;
    LJ::ModPerl::add_httpd_config("ServerAdmin $LJ::ADMIN_EMAIL")
        if $LJ::ADMIN_EMAIL;

    LJ::ModPerl::add_httpd_config(q{

# User-friendly error messages
ErrorDocument 404 /404-error.html
ErrorDocument 500 /500-error.html

# This interferes with LJ's /~user URI, depending on the module order
<IfModule mod_userdir.c>
    UserDir disabled
</IfModule>

# required for the $r we use
PerlOptions +GlobalRequest

PerlInitHandler Apache::LiveJournal
#PerlInitHandler Apache::SendStats
#PerlCleanupHandler Apache::SendStats
#PerlChildInitHandler Apache::SendStats
DirectoryIndex index.html index.bml

});

    # setup child init handler to seed random using a good entropy source
    Apache2::ServerUtil->server->push_handlers(PerlChildInitHandler => sub {
        srand(LJ::urandom_int());
    });

    if ($LJ::BML_DENY_CONFIG) {
        LJ::ModPerl::add_httpd_config("PerlSetVar BML_denyconfig \"$LJ::BML_DENY_CONFIG\"\n");
    }

    unless ($LJ::SERVER_TOTALLY_DOWN)
    {
        LJ::ModPerl::add_httpd_config(q{

# BML support:
<Files ~ "\.bml$">
    SetHandler perl-script
    PerlResponseHandler Apache::BML
</Files>

});
    }

    unless ($LJ::DISABLED{ignore_htaccess}) {
        LJ::ModPerl::add_httpd_config(qq{

<Directory />
    AllowOverride none
</Directory>

        });
    }

    eval { setup_restart_local(); };

}

sub add_httpd_config {
    my $text = shift;
    Apache2::ServerUtil->server->add_config( [ split /\n/, $text ] );
}

setup_start();

1;

