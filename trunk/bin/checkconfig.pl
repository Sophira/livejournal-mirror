#!/usr/bin/perl
#

use strict;
use Getopt::Long;

my $debs_only = 0;
my ($only_check, $no_check, $opt_nolocal);

my %dochecks;   # these are the ones we'll actually do
my @checks = (  # put these in the order they should be checked in
    "modules",
    "env",
    "database",
    "ljconfig",
);
foreach my $check (@checks) { $dochecks{$check} = 1; }

sub usage {
    die "Usage: checkconfig.pl
checkconfig.pl --needed-debs
checkconfig.pl --only=<check> | --no=<check>

Checks are:
 " . join(', ', @checks);
}

usage() unless GetOptions(
                          'needed-debs' => \$debs_only,
                          'only=s'      => \$only_check,
                          'no=s'        => \$no_check,
                          'nolocal'     => \$opt_nolocal,
                          );

if ($debs_only) {
    $dochecks{ljconfig} = 0;
    $dochecks{database} = 0;
}

usage() if $only_check && $no_check;

%dochecks = ( $only_check => 1)
    if $only_check;

# dependencies
if ($dochecks{ljconfig}) {
    $dochecks{env} = 1;
}

$dochecks{$no_check} = 0
    if $no_check;

my @errors;
my $err = sub {
    return unless @_;
    die "\nProblem:\n" . join('', map { "  * $_\n" } @_);
};

my %modules = (
               "DateTime" => { 'deb' => 'libdatetime-perl' },
               "DBI" => { 'deb' => 'libdbi-perl',  },
               "DBD::mysql" => { 'deb' => 'libdbd-mysql-perl', },
               "Class::Autouse" => { 'deb' => 'libclass-autouse-perl', },
               "Class::Trigger" => { 'deb' => 'libclass-trigger-perl', },
               "Digest::MD5" => { 'deb' => 'libdigest-md5-perl', },
               "Digest::SHA1" => { 'deb' => 'libdigest-sha1-perl', },
               "Image::Size" => { 'deb' => 'libimage-size-perl', },
               "MIME::Lite" => { 'deb' => 'libmime-lite-perl', },
               "MIME::Words" => { 'deb' => 'libmime-perl', },
               "Compress::Zlib" => { 'deb' => 'libcompress-zlib-perl', },
               "Net::SMTP" => {
                   'deb' => 'libnet-perl',
                   'opt' => "Alternative to piping into sendmail to send mail.",
               },
               "Net::DNS" => {
                   'deb' => 'libnet-dns-perl',
               },
               "MIME::Base64" => { 'deb' => 'libmime-base64-perl' },
               "URI::URL" => { 'deb' => 'liburi-perl' },
               "HTML::Tagset" => { 'deb' => 'libhtml-tagset-perl' },
               "HTML::Parser" => { 'deb' => 'libhtml-parser-perl', },
               "LWP::Simple" => { 'deb' => 'libwww-perl', },
               "LWP::UserAgent" => { 'deb' => 'libwww-perl', },
               "GD" => { 'deb' => 'libgd-gd2-perl' },
               "GD::Graph" => {
                   'deb' => 'libgd-graph-perl',
                   'opt' => 'Required to make graphs for the statistics page.',
               },
               "Mail::Address" => { 'deb' => 'libmailtools-perl', },
               "Proc::ProcessTable" => {
                   'deb' => 'libproc-process-perl',
                   'opt' => "Better reliability for starting daemons necessary for high-traffic installations.",
               },
               "RPC::XML" => {
                   'deb' => 'librpc-xml-perl',
                   'opt' => 'Required for outgoing XMLRPC support',
               },
               "SOAP::Lite" => {
                   'deb' => 'libsoap-lite-perl',
                   'opt' => 'Required for XML-RPC support.',
               },
               "Unicode::MapUTF8" => { 'deb' => 'libunicode-maputf8-perl', },
               "Storable" => {
                   'deb' => 'libstorable-perl',
               },
               "XML::RSS" => {
                   'deb' => 'libxml-rss-perl',
                   'opt' => 'Required for retrieving RSS off of other sites (syndication).',
               },
               "XML::Simple" => {
                   'deb' => 'libxml-simple-perl',
                   'ver' => 2.12,
               },
               "String::CRC32" => {
                   'deb' => 'libstring-crc32-perl',
                   'opt' => 'Required for palette-altering of PNG files.  Only necessary if you plan to make your own S2 styles that use PNGs, not GIFs.',
               },
               "Time::HiRes" => { 'deb' => 'libtime-hires-perl' },
               "IO::WrapTie" => { 'deb' => 'libio-stringy-perl' },
               "XML::Atom" => {
                   'deb' => 'libxml-atom-perl',
                   'opt' => 'Required for AtomAPI support.',
               },
               "Math::BigInt::GMP" => {
                   'opt' => 'Aides Crypt::DH so it isn\'t crazy slow.',
                   'deb' => 'libmath-bigint-gmp-perl',
               },
               "URI::Fetch" => {
                   'opt' => 'Required for OpenID support.',
               },
               "Crypt::DH" => {
                   'opt' => 'Required for OpenID support.',
               },
               "Unicode::CheckUTF8" => {},
               "Digest::HMAC_SHA1" => {
                   'deb' => 'libdigest-hmac-perl',
               },
               "Image::Magick" => {
                   deb => 'perlmagick',
                   opt => "Required for the userpic factory.",
               },
               "Class::Accessor" => {
                   deb => 'libclass-accessor-perl',
                   opt => "Required for TheSchwartz job submission",
               },
               "Class::Trigger" => {
                   deb => 'libclass-trigger-perl',
                   opt => "Required for TheSchwartz job submission",
               },
               "Class::Data::Inheritable" => {
                   opt => "Required for TheSchwartz job submission",
               },
               );

sub check_modules {
    print "[Checking for Perl Modules....]\n"
        unless $debs_only;

    my @debs;

    foreach my $mod (sort keys %modules) {
        my $rv = eval "use $mod;";
        if ($@) {
            my $dt = $modules{$mod};
            unless ($debs_only) {
                if ($dt->{'opt'}) {
                    print STDERR "Missing optional module $mod: $dt->{'opt'}\n";
                } else {
                    push @errors, "Missing perl module: $mod";
                }
            }
            push @debs, $dt->{'deb'} if $dt->{'deb'};
            next;
        }

        my $ver_want = $modules{$mod}{ver};
        my $ver_got = $mod->VERSION;
        if ($ver_want && $ver_got && $ver_got < $ver_want) {
            push @errors, "Out of date module: $mod (need $ver_want, $ver_got installed)";
        }
    }
    if (@debs && -e '/etc/debian_version') {
        if ($debs_only) {
            print join(' ', @debs);
        } else {
            print STDERR "\n# apt-get install ", join(' ', @debs), "\n\n";
        }
    }

    $err->(@errors);
}

sub check_env {
    print "[Checking LJ Environment...]\n"
        unless $debs_only;

    $err->("\$LJHOME environment variable not set.")
        unless $ENV{'LJHOME'};
    $err->("\$LJHOME directory doesn't exist ($ENV{'LJHOME'})")
        unless -d $ENV{'LJHOME'};

    # before ljconfig.pl is called, we want to call the site-local checkconfig,
    # otherwise ljconfig.pl might load ljconfig-local.pl, which maybe load
    # new modules to implement site-specific hooks.
    my $local_config = "$ENV{'LJHOME'}/bin/checkconfig-local.pl";
    $local_config .= ' --needed-debs' if $debs_only;
    if (!$opt_nolocal && -e $local_config) {
        my $good = eval { require $local_config; };
        exit 1 unless $good;
    }

    $err->("No ljconfig.pl file found at $ENV{'LJHOME'}/cgi-bin/ljconfig.pl")
        unless -e "$ENV{'LJHOME'}/cgi-bin/ljconfig.pl";

    eval { require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl"; };
    $err->("Failed to load ljlib.pl: $@") if $@;

    # if SMTP_SERVER is set, then Net::SMTP is required, not optional.
    if ($LJ::SMTP_SERVER && ! defined $Net::SMTP::VERSION) {
        $err->("Net::SMTP isn't available, and you have \$LJ::SMTP_SERVER set.");
    }
}

sub check_database {

    require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";
    my $dbh = LJ::get_dbh("master");
    unless ($dbh) {
        $err->("Couldn't get master database handle.");
    }
    foreach my $c (@LJ::CLUSTERS) {
        my $dbc = LJ::get_cluster_master($c);
        next if $dbc;
        $err->("Couldn't get db handle for cluster \#$c");
    }

    if (%LJ::MOGILEFS_CONFIG && $LJ::MOGILEFS_CONFIG{hosts}) {
        print "[Checking MogileFS client.]\n";
        my $mog = LJ::mogclient();
        die "Couldn't create mogilefs client." unless $mog;
    }
}

sub check_ljconfig {
    # if we're a developer running this, make sure we didn't add any
    # new configuration directives without first documenting them:
    $ENV{READ_LJ_SOURCE} = 1 if $LJ::IS_DEV_SERVER;

    require LJ::ConfCheck;
    my @errs = LJ::ConfCheck::config_errors();
    local $" = ",\n\t";
    $err->("Config errors: @errs") if @errs;
}

foreach my $check (@checks) {
    next unless $dochecks{$check};
    my $cn = "check_".$check;
    no strict 'refs';
    &$cn;
}

unless ($debs_only) {
    print "All good.\n";
    print "NOTE: checkconfig.pl doesn't check everything yet\n";
}


