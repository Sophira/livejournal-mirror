#!/usr/bin/perl
#

# to be require'd by modperl.pl

use strict;

package LJ;

use Apache;
use Apache::LiveJournal;
use Apache::CompressClientFixup;
use Apache::BML;
use LJ::SpellCheck;
use LJ::TextMessage;
use LJ::Blob;
use LJ::Captcha;
use Digest::MD5;
use MIME::Words;
use Text::Wrap ();
use LWP::UserAgent ();
use Storable;
use Image::Size ();

require "$ENV{'LJHOME'}/cgi-bin/ljlang.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljpoll.pl";
require "$ENV{'LJHOME'}/cgi-bin/htmlcontrols.pl";
require "$ENV{'LJHOME'}/cgi-bin/weblib.pl";
require "$ENV{'LJHOME'}/cgi-bin/imageconf.pl";
require "$ENV{'LJHOME'}/cgi-bin/propparse.pl";
require "$ENV{'LJHOME'}/cgi-bin/supportlib.pl";
require "$ENV{'LJHOME'}/cgi-bin/cleanhtml.pl";
require "$ENV{'LJHOME'}/cgi-bin/portal.pl";
require "$ENV{'LJHOME'}/cgi-bin/talklib.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljtodo.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljfeed.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljlinks.pl";
require "$ENV{'LJHOME'}/cgi-bin/directorylib.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljemailgateway.pl";
require "$ENV{'LJHOME'}/cgi-bin/emailcheck.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljmemories.pl";
require "$ENV{'LJHOME'}/cgi-bin/ljmail.pl";
require "$ENV{'LJHOME'}/cgi-bin/sysban.pl";
require "$ENV{'LJHOME'}/cgi-bin/synlib.pl";

# preload site-local libraries, if present:
require "$ENV{'LJHOME'}/cgi-bin/modperl_subs-local.pl"
    if -e "$ENV{'LJHOME'}/cgi-bin/modperl_subs-local.pl";

$LJ::IMGPREFIX_BAK = $LJ::IMGPREFIX;
$LJ::STATPREFIX_BAK = $LJ::STATPREFIX;

package LJ::ModPerl;

# pull in a lot of useful stuff before we fork children

sub setup_start {

    # auto-load some stuff before fork:
    Storable::thaw(Storable::freeze({}));
    foreach my $minifile ("GIF89a", "\x89PNG\x0d\x0a\x1a\x0a", "\xFF\xD8") {
        Image::Size::imgsize(\$minifile);
    }
    DBI->install_driver("mysql");

    # set this before we fork
    $LJ::CACHE_CONFIG_MODTIME = (stat("$ENV{'LJHOME'}/cgi-bin/ljconfig.pl"))[9];

    eval { setup_start_local(); };
}

sub setup_restart {

    # setup httpd.conf things for the user:
    Apache->httpd_conf("DocumentRoot $LJ::HTDOCS")
        if $LJ::HTDOCS;
    Apache->httpd_conf("ServerAdmin $LJ::ADMIN_EMAIL")
        if $LJ::ADMIN_EMAIL;

    Apache->httpd_conf(qq{

# This interferes with LJ's /~user URI, depending on the module order
<IfModule mod_userdir.c>
  UserDir disabled
</IfModule>

PerlInitHandler Apache::LiveJournal
PerlInitHandler Apache::SendStats
PerlFixupHandler Apache::CompressClientFixup
PerlCleanupHandler Apache::SendStats
PerlChildInitHandler Apache::SendStats
DirectoryIndex index.html index.bml
});

    if ($LJ::BML_DENY_CONFIG) {
        Apache->httpd_conf("PerlSetVar BML_denyconfig \"$LJ::BML_DENY_CONFIG\"\n");
    }

    unless ($LJ::SERVER_TOTALLY_DOWN)
    {
        Apache->httpd_conf(qq{
# BML support:
<Files ~ "\\.bml\$">
  SetHandler perl-script
  PerlHandler Apache::BML
</Files>

# User-friendly error messages
ErrorDocument 404 /404-error.html
ErrorDocument 500 /500-error.html

});
    }

}

setup_start();

1;
