#!/usr/bin/perl
#

package FB;

use strict;
use lib "$ENV{'FBHOME'}/src/s2";
use Danga::EXIF;
use DBI;
use DBI::Role;
use Digest::MD5 ();
use IO::File ();
use Image::Size ();
use FB::User;
use FB::Gallery;
use FB::MemCache;
use FB::Gpic;
use FB::Upic;
use FB::SecGroup;
use FB::Job;
use FB::Manage;
use MogileFS::Client;
use File::Path ();
use File::Copy ();
use File::Temp ();
use POSIX ();
use IPC::Open3 ();
use HTMLCleaner;
use Storable ();
use S2;
use S2FotoBilder;
use S2::Checker;
use S2::Compiler;
use LWP::Simple;

use constant FMT_JPEG => 1;
use constant FMT_GIF => 2;
use constant FMT_PNG => 3;
use constant FMT_TIFF => 4;

use Carp qw (confess);

require 'export.pl';
require "$ENV{'FBHOME'}/etc/fbconfig.pl";
require "fbdefaults.pl";

# load the bread crumb hash
require "$ENV{'FBHOME'}/cgi-bin/crumbs.pl";

# don't let people use these:
foreach (qw(interface site help support about download doc docs webmaster
            manage edit login logout js create tools system gallery res admin
            contact user users dev static img pic pics photos photo)) {
    $FB::RESERVED_DIR{$_} = 1;
}

$FB::DBIRole = new DBI::Role {
    'sources' => \%FB::DBINFO,
    'weights_from_db' => $FB::DBWEIGHTS_FROM_DB,
    'default_db' => "fotobilder",
} or die "Could not initialize DBI::Role";

if (%FB::MOGILEFS_CONFIG) {
    $FB::MogileFS = MogileFS::Client->new(
                                  domain => $FB::MOGILEFS_CONFIG{domain},
                                  root   => $FB::MOGILEFS_CONFIG{root},
                                  hosts  => $FB::MOGILEFS_CONFIG{hosts},
                                  )
        or die "Could not initialize MogileFS";
}

@FB::VALID_SCALING_W = qw(0 50 100 150 320 640 800 1024 1280 1600);
@FB::VALID_SCALING_H = qw(0 50 100 150 240 320 480 600 640 768 960 1200);

# Gallery flag mappings, name => bit
# (Currently empty, this is for future gallery booleans)
%FB::GALLERY_FLAGS = ( );

# setup local domainid, even if site has no other auth plugins
$FB::DOMAIN_DOMAINID{lc($FB::DOMAIN)} = 0;

foreach my $dmid (keys %FB::AUTH_DOMAIN) {
    next if $FB::AUTH_DOMAIN_LOADED{$dmid}++;
    my $v = $FB::AUTH_DOMAIN{$dmid};
    my $a = FB::new_domain_plugin($dmid, $v->[0], $v->[1]);
}

# if this is a dev server, alias FB::D to Data::Dumper::Dumper
if ($FB::IS_DEV_SERVER) {
    eval "use Data::Dumper ();";
    *FB::D = \&Data::Dumper::Dumper;
}

# create mime->fmtid and fmtid->mime mappings
%FB::fmtid_to_mime_map = (
    1 => 'image/jpeg',
    2 => 'image/gif',
    3 => 'image/png',
    4 => 'image/tiff',

    101 => 'video/quicktime',
    102 => 'application/vnd.rn-realmedia',
    103 => 'video/3gpp',
    104 => 'video/mpeg',
    105 => 'video/x-msvideo',

    201 => 'audio/mpeg',
);
# flip keys/values (wacky flip from Artur)
@FB::mime_to_fmtid_map{values %FB::fmtid_to_mime_map} = keys %FB::fmtid_to_mime_map;


# create ext->fmtid mapping
%FB::ext_to_mime_map = (
    'jpg' => 'image/jpeg',
    'gif' => 'image/gif',
    'png' => 'image/png',
    'tif' => 'image/tiff',

    'mov'  => 'video/quicktime',
    'rm'   => 'application/vnd.rn-realmedia',
    'rv'   => 'application/vnd.rn-realmedia',
    '3gp'  => 'video/3gpp',
    'mpg'  => 'video/mpeg',
    'mpeg' => 'vide/mpeg',
    'avi'  => 'video/x-msvideo',
    'wmv'  => 'video/x-msvideo',
    'asf'  => 'video/x-msvideo',

    'mp3'  => 'audio/mpeg',
);
# flip keys/values
@FB::fmtid_to_ext_map{values %FB::ext_to_mime_map} = keys %FB::ext_to_mime_map;

FB::MemCache::init();

sub start_request
{
    FB::unset_remote();       # clear cached remote
    FB::set_active_crumb(''); # clear active crumb

    FB::Gallery->reset_singletons;
    FB::Upic->reset_singletons;

    # reset all singletons at the start of this request
    FB::Singleton->reset_all;

    # clear the handle request cache (like normal cache, but verified already for
    # this request to be ->ping'able).
    $FB::DBIRole->clear_req_cache();

    # need to suck db weights down on every request (we check
    # the serial number of last db weight change on every request
    # to validate master db connection, instead of selecting
    # the connection ID... just as fast, but with a point!)
    $FB::DBIRole->trigger_weight_reload();

    # normally, BML requests already reset it, but we use
    # the magic %BML::COOKIE hash in non-BML codepaths too
    eval { BML::reset_cookies() };

    # clear the FB request cache
    %FB::REQ_CACHE = ();

    # clear out ddlockd server object
    $FB::LOCKER_OBJ = undef;

    # check the modtime of fbconfig.pl and reload if necessary
    # only do a stat every 10 seconds and then only reload
    # if the file has changed
    my $now = time();
    if ($now - $FB::CACHE_CONFIG_MODTIME_LASTCHECK > 10) {
        my $modtime = (stat("$ENV{'FBHOME'}/etc/fbconfig.pl"))[9];
        if ($modtime > $FB::CACHE_CONFIG_MODTIME) {
            # reload config and update cached modtime
            $FB::CACHE_CONFIG_MODTIME = $modtime;
            eval {
                do "$ENV{'FBHOME'}/etc/fbconfig.pl";
                do "$ENV{'FBHOME'}/cgi-bin/fbdefaults.pl";

                # reload MogileFS config
                if ($FB::MogileFS) {
                    $FB::MogileFS->reload
                        ( domain => $FB::MOGILEFS_CONFIG{domain},
                          root   => $FB::MOGILEFS_CONFIG{root},
                          hosts  => $FB::MOGILEFS_CONFIG{hosts}, );
                }
            };

            $FB::IMGPREFIX_BAK = $FB::IMGPREFIX;
            $FB::DBIRole->set_sources(\%FB::DBINFO);
            FB::MemCache::reload_conf();
            if ($modtime > $now - 60) {
                # show to stderr current reloads.  won't show
                # reloads happening from new apache children
                # forking off the parent who got the inital config loaded
                # hours/days ago and then the "updated" config which is
                # a different hours/days ago.
                #
                # only print when we're in web-context
                print STDERR "fbconfig.pl reloaded\n"
                    if eval { Apache->request };
            }
        }
        $FB::CACHE_CONFIG_MODTIME_LASTCHECK = $now;
    }

    # run all registered site-specific start_request hooks
    FB::run_hooks("start_request");

    # include standard resources if this is a web request
    if (eval { Apache->request }) {
        FB::need_res(qw(
                        static/default.css
                        ));
    }

    return 1;
}

sub get_dbh {
    $FB::DBIRole->get_dbh(@_);
}

sub use_diff_db {
    $FB::DBIRole->use_diff_db(@_);
}

sub get_db_reader
{
    return FB::get_dbh("slave", "master");
}

sub get_db_writer
{
    return FB::get_dbh("master");
}

sub locker {
    return $FB::LOCKER_OBJ if $FB::LOCKER_OBJ;
    eval "use DDLockClient ();";
    die "Couldn't load locker client: $@" if $@;

    return $FB::LOCKER_OBJ =
        new DDLockClient (
                          servers => [ @FB::LOCK_SERVERS ],
                          lockdir => $FB::LOCKDIR || "$FB::HOME/locks",
                          );
}

# only used by logout code, really:
sub set_remote
{
    my $remote = shift;
    $FB::CACHED_REMOTE = 1;
    $FB::CACHE_REMOTE = $remote;
    1;
}

sub unset_remote
{
    $FB::CACHED_REMOTE = 0;
    $FB::CACHE_REMOTE = undef;
    1;
}

sub get_system_message
{
    my $u = shift or return undef;

    # pretty much a stub for now, but more complex
    # functionality could be added here
    return $FB::SYSTEM_MESSAGE || '';
}

sub get_remote_ip
{
    return Apache->request->connection->remote_ip;
}


sub last_error_code
{
    return $FB::last_error;
}

sub last_error
{
    my $err = {
        'utf8' => "Encoding isn't valid UTF-8",
        'db' => "Database error",
    };
    my $des = $err->{$FB::last_error};
    if ($FB::last_error eq "db" && $FB::db_error) {
        $des .= ": $FB::db_error";
    }
    return $des || $FB::last_error;
}

sub error
{
    my $err = shift;
    if (ref $err eq "DBI::db" || ref $err eq "FB::User") {
        $FB::db_error = $err->errstr;
        $err = "db";
    } elsif ($err eq "db") {
        $FB::db_error = "";
    }
    $FB::last_error = $err;
    if ($FB::DEBUG) {
        my ($pkg, $filename, $line) = caller;
        warn "error: $FB::last_error ($FB::db_error) from $pkg/$filename/$line\n";
    }
    return undef;
}

sub want_userid
{
    my $uuserid = shift;
    return $uuserid->{'userid'} if ref $uuserid;
    return $uuserid;
}

sub want_username
{
    my $uun = shift;
    return ref $uun ? $uun->{'user'} : $uun;
}

sub want_user
{
    my $uuser = shift;
    return ref $uuser ? $uuser : load_user($uuser);
}

sub want_gpicid
{
    my $g = shift;
    return $g->{gpicid} if ref $g;
    return $g;
}

sub want_gpic
{
    my $g = shift;
    return $g if ref $g;
    return FB::Gpic->load($g);
}

sub want_upicid
{
    my $pic = shift;
    return $pic->{upicid} if ref $pic;
    return $pic;
}

sub want_gallid
{
    my $gal = shift;
    return $gal->{gallid} if ref $gal;
    return $gal;
}

sub set_active_crumb
{
    $FB::ACTIVE_CRUMB = shift;
    return undef;
}

sub set_dynamic_crumb
{
    my ($title, $parent) = @_;
    $FB::ACTIVE_CRUMB = [ $title, $parent ];
}

sub get_parent_crumb
{
    my $thiscrumb = FB::get_crumb(FB::get_active_crumb());
    return FB::get_crumb($thiscrumb->[2]);
}

sub get_active_crumb
{
    return $FB::ACTIVE_CRUMB;
}

sub get_crumb_path
{
    my $cur = FB::get_active_crumb();
    my @list;
    while ($cur) {
        # get crumb, fix it up, and then put it on the list
        if (ref $cur) {
            # dynamic crumb
            push @list, [ $cur->[0], '', $cur->[1], 'dynamic' ];
            $cur = $cur->[1];
        } else {
            # just a regular crumb
            my $crumb = FB::get_crumb($cur);
            last unless $crumb;
            last if $cur eq $crumb->[2];
            $crumb->[3] = $cur;
            push @list, $crumb;

            # now get the next one we're going after
            $cur = $crumb->[2]; # parent of this crumb
        }
    }
    return @list;
}

sub get_crumb
{
    my $crumbkey = shift;
    if (defined $FB::CRUMBS_LOCAL{$crumbkey}) {
        return $FB::CRUMBS_LOCAL{$crumbkey};
    } else {
        return $FB::CRUMBS{$crumbkey};
    }
}


sub paging_bar
{
    my ($page, $pages, $opts) = @_;

    my $self_link = $opts->{'self_link'} ||
                    sub { BML::self_link({ 'page' => $_[0] }) };

    my $navcrap;
    if ($pages > 1) {
        $navcrap .= "<center><font face='Arial,Helvetica' size='-1'><b>";
        $navcrap .= "Page $page of $pages<br />";
        my $left = "<b>&lt;&lt;</b>";
        if ($page > 1) { $left = "<a href='" . $self_link->($page-1) . "'>$left</a>"; }
        my $right = "<b>&gt;&gt;</b>";
        if ($page < $pages) { $right = "<a href='" . $self_link->($page+1) . "'>$right</a>"; }
        $navcrap .= $left . " ";
        for (my $i=1; $i<=$pages; $i++) {
            my $link = "[$i]";
            if ($i != $page) { $link = "<a href='" . $self_link->($i) . "'>$link</a>"; }
            else { $link = "<font size='+1'><b>$link</b></font>"; }
            $navcrap .= "$link ";
        }
        $navcrap .= "$right";
        $navcrap .= "</font></center>\n";
        $navcrap = BML::fill_template("standout", { 'DATA' => $navcrap });
    }
    return $navcrap;
}

# <WCMFUNC>
# name: FB::are_hooks
# des: Returns true if the site has one or more hooks installed for
#      the given hookname.
# args: hookname
# </WCMFUNC>
sub are_hooks
{
    my $hookname = shift;
    return defined $FB::HOOKS{$hookname};
}

# <WCMFUNC>
# name: FB::clear_hooks
# des: Removes all hooks.
# </WCMFUNC>
sub clear_hooks
{
    %FB::HOOKS = ();
}

# <WCMFUNC>
# name: FB::run_hooks
# des: Runs all the site-specific hooks of the given name.
# returns: list of arrayrefs, one for each hook ran, their
#          contents being their own return values.
# args: hookname, args*
# des-args: Arguments to be passed to hook.
# </WCMFUNC>
sub run_hooks
{
    my ($hookname, @args) = @_;
    my @ret;
    return unless ref $FB::HOOKS{$hookname} eq "ARRAY";
    foreach my $hook (@{$FB::HOOKS{$hookname}}) {
        push @ret, [ $hook->(@args) ];
    }
    return @ret;
}

# <WCMFUNC>
# name: FB::run_hooks
# des: Runs hook of the given name.  If there are multiple registered, only one is run.
# returns: return value from hook.
# args: hookname, args*
# des-args: Arguments to be passed to hook.
# </WCMFUNC>
sub run_hook
{
    my ($hookname, @args) = @_;
    my @ret;
    return undef unless $FB::HOOKS{$hookname} && @{$FB::HOOKS{$hookname}};
    my $hook = $FB::HOOKS{$hookname}->[0];
    return $hook->(@args);
}

# <WCMFUNC>
# name: FB::register_hook
# des: Installs a site-specific hook.
# info: Installing multiple hooks per hookname is valid.
#       They're run later in the order they're registered.
# args: hookname, subref
# des-subref: Subroutine reference to run later.
# </WCMFUNC>
sub register_hook
{
    my $hookname = shift;
    my $subref = shift;
    push @{$FB::HOOKS{$hookname}}, $subref;
}

# <WCMFUNC>
# class: logging
# name: FB::statushistory_add
# des: Adds a row to a user's statushistory
# info: See the [dbtable[statushistory]] table.
# returns: boolean; 1 on success, 0 on failure
# args: dbarg, userid, adminid, shtype, notes?
# des-userid: The user getting acted on.
# des-adminid: The site admin doing the action.
# des-shtype: The status history type code.
# des-notes: Optional notes associated with this action.
# </WCMFUNC>
sub statushistory_add
{
    my $userid = want_userid(shift);
    my $admid  = want_userid(shift);

    my $dbh = FB::get_db_writer();
    my $qshtype = $dbh->quote(shift);
    my $qnotes  = $dbh->quote(shift);

    $dbh->do("INSERT INTO statushistory (userid, adminid, shtype, notes) ".
             "VALUES ($userid, $admid, $qshtype, $qnotes)");
    return $dbh->err ? 0 : 1;
}

sub hex_to_bin
{
    return pack("H*", $_[0]);
}

sub bin_to_hex
{
    return unpack("H*", $_[0]);
}

sub fmtid_is_video
{
    my $fmtid = shift;
    return $fmtid > 100 && $fmtid < 200;
}

sub fmtid_is_still
{
    my $fmtid = shift;
    return $fmtid <= 100;
}

sub fmtid_is_audio
{
    my $fmtid = shift;
    return $fmtid > 200 && $fmtid < 300;
}

# the magic isn't hex encoded
# see ~/notes/formats
sub fmtid_from_magic
{
    my $magic = shift;
    my $hex = unpack "H*", $magic;
    my $mime;

    # image formats
    $mime = 'image/jpeg' if $magic =~ /^\xff\xd8/; # JPEG
    $mime = 'image/gif'  if $magic =~ /^GIF8/;     # GIF
    $mime = 'image/png'  if $magic =~ /^\x89PNG/;  # PNG
    $mime = 'image/tiff' if $magic =~ /^MM\0\x2a/; # TIFF, big-endian
    $mime = 'image/tiff' if $magic =~ /^II\x2a\0/; # TIFF, little-endian

    # video formats
    $mime = 'video/3gpp' if $magic =~ /^\x00{2}.*3gp/;               # 3GPP
    $mime = 'video/quicktime' if $magic =~ /^\x00{2}.*(?:moov|mdat|ftyp|free|junk|pnot|skip|wide|pict)(?:.*qt)?/;
                                                           # Quicktime
    $mime = 'video/vnd.rn-realmedia' if $magic =~ /^\.RMF/;                      # RealMedia
    $mime = 'video/mpeg' if $magic =~ /^\x00\x00\x01\xba/;           # Generic MPEG stream
    $mime = 'video/x-msvideo' if $magic =~ /(?:^\x30\x26\xb2\x75|AVI)/
                 or $hex =~ /^(?:\w{2}){8}415649/;         # AVI/WMV/ASF

    if ($FB::AUDIO_SUPPORT) {
        # audio formats
        $mime = 'audio/mpeg' if $magic =~ /^ID3/;      #MP3
    }

    return 0 unless $mime;
    return FB::mime_to_fmtid($mime);
}

sub mime_to_fmtid {
    my $mime = shift;
    return $FB::mime_to_fmtid_map{$mime};
}

sub fmtid_from_ext
{
    my $ext = lc shift;
    return FB::mime_to_fmtid($FB::ext_to_mime_map{$ext});
}

sub fmtid_to_mime
{
    my $fmtid = shift;
    return $FB::fmtid_to_mime_map{$fmtid};
}

# This function returns a two element list, the first of which is "db" or
# "disk" and the second is an integer between 1 and 255.
# it determines where new pictures are stored.
sub lookup_pcluster_dest
{
    # pick one at random
    my $idx = rand() * @FB::NEW_PICS_ON;
    return @{$FB::NEW_PICS_ON[$idx]};
}

sub format_extension
{
    my $fmtid = shift;
    return $FB::fmtid_to_ext_map{$fmtid};
}

sub make_dirs
{
    my $filename = shift;
    Carp::confess("Invalid filename") unless $filename;
    my $dir = File::Basename::dirname($filename);
    eval { File::Path::mkpath($dir, 0, 0775); };
    return $@ ? 0 : 1;
}

sub current_domain_id
{
    return 1;
    my $r = eval { Apache->request };

    # this shouldn't ever be called from outside of web context
    # if it is, we'll die rather than defaulting to 0 so the caller
    # knows there is a problem and can pass an explicit domainid to whatever
    # API they are calling
    Carp::cluck("FB::current_domain_id() called from non-web context") unless $r;

    my $dhost = lc($r->header_in("Host"));
    if ($dhost =~ /,/) {
        my @list = split(/\s*,\s*/, $dhost);
        foreach $dhost (@list) {
            my $dmid = $FB::VHOST_DOMAINID{$dhost};
            return $dmid if $dmid;
        }
    }
    my $dmid = $FB::VHOST_DOMAINID{$dhost};
    return $dmid + 0;
}

sub domain_plugin
{
    confess "no domain plugin";
}

sub current_domain_plugin
{
    confess "no domain plugin";
}

# returns domain id or undef if unknown domain
sub get_domain_id
{
    confess "no domain plugin";
}

sub get_domainid_name
{
    confess "no domain plugin";
}

sub new_domain_plugin
{
    my ($dmid, $class, $args) = @_;
    return undef unless $class =~ /^\w+$/;
    my $rv = eval "use FotoBilder::Auth::$class;";
    if ($@) {
        print STDERR "Error loading auth module '$class': $@\n";
        return undef;
    }
    my $mod = "FotoBilder::Auth::$class";
    return $mod->new($dmid, $args);
}

sub rand_auth
{
    return int(rand(65536));
}

sub rand_chars
{
    my $length = shift;
    my $chal = "";
    my $digits = "abcdefghijklmnopqrstuvwzyzABCDEFGHIJKLMNOPQRSTUVWZYZ0123456789";
    for (1..$length) {
        $chal .= substr($digits, int(rand(62)), 1);
    }
    return $chal;
}

sub save_receipt
{
    my ($u, $rcptkey, $type, $val) = @_;
    return undef unless $u && $rcptkey && $type;

    $u->writer  or return FB::error("db");

    # hashrefs get urlencoded
    if (ref $val eq 'HASH') {
        $val = join("&", map { FB::eurl($_) . "=" . FB::eurl($val->{$_}) } keys %$val);
    }
    return FB::error("Receipt value too long") if length($val) > 255;

    my $now   = time();
    my $exp_p = 86400*3; # 3 days for UploadPrepare
    my $exp_t = 60*15;   # 15 minutes for UploadTempFile

    # lazily clean old receipts for this user
    my $sth = $u->prepare
        ("SELECT userid, rcptkey, type, val, timecreate " .
         "FROM receipts WHERE userid=? AND " .
         "(type='P' AND timecreate<? OR type='T' AND timecreate<?)",
         $u->{userid}, [$now - $exp_p, "int"], [$now - $exp_t, "int"]);
    $sth->execute;
    return FB::error($u) if $u->err;

    my @to_delete = ();
    while (my $rcpt = $sth->fetchrow_hashref) {

        # val gets urldecoded into a hash
        $rcpt->{val_hash} = {};
        FB::decode_url_args(\$rcpt->{val}, $rcpt->{val_hash});
        my $val = $rcpt->{val_hash};

        # tempfiles need to be cleared from disk
        if ($rcpt->{type} eq 'T') {
            FB::clean_receipt_tempfile($val->{pclustertype}, $val->{pathkey})
                or return FB::error(FB::last_error());

        }

        push @to_delete, $rcpt->{rcptkey};
    }

    if (@to_delete) {
        my $bind = join(',', map { '?' } @to_delete);
        $u->do("DELETE FROM receipts WHERE userid=? AND rcptkey IN ($bind)",
               $u->{userid}, @to_delete);
        return FB::error($u) if $u->err;
    }

    # insert the new row
    $u->do("REPLACE INTO receipts (userid, rcptkey, type, val, timecreate) " .
           "VALUES (?,?,?,?,UNIX_TIMESTAMP())",
           $u->{userid}, $rcptkey, $type, $val);
    return FB::error($u) if $u->err;

    return 1;
}

sub clean_receipt_tempfile
{
    my ($pclustertype, $pathkey) = @_;
    return undef unless $pclustertype && $pathkey;

    if ($pclustertype eq 'mogilefs') {

        # delete tempfile from mogilefs
        # -- note that the delete method returns true even if the file
        #    was already deleted.
        $FB::MogileFS->delete($pathkey)
            or return FB::error("Unable to delete existing temporary file from MogileFS: $pathkey");

    } elsif ($pclustertype eq 'disk') {

        # unlink tempfile from disk if necessary
        if (-e $pathkey) {

            my $rv = unlink $pathkey;
            unless ($rv) {
                my $filename = (split('/', $pathkey))[-1];
                return FB::error("Unable to to delete existing temporary file from disk: $filename");
            }

        }

    } else {
        return FB::error("Unknown pclustertype: $pclustertype");
    }

    return 1;
}

sub load_receipt
{
    my ($u, $rcptkey) = @_;
    return undef unless $u && $rcptkey;

    return FB::error("db") unless $u->writer;

    my $row = $u->selectrow_hashref("SELECT userid, rcptkey, type, val, timecreate " .
                                    "FROM receipts WHERE userid=? AND rcptkey=?",
                                    $u->{userid}, $rcptkey);
    return FB::error($u) if $u->err;

    # val gets urldecoded into a hash
    $row->{val_hash} = {};
    FB::decode_url_args(\$row->{val}, $row->{val_hash});

    return $row;
}

sub valid_scaling_list
{
    my ($sw, $sh) = @_;

    # allow a $up (upic) object to be passed in
    ($sw, $sh) = @{$sw}{qw(width height)} if ref $sw;

    # swap width and height for FB::scale on
    # portrait images (landscape default)
    my $swap = $sh > $sw;
    ($sw, $sh) = ($sh, $sw) if $swap;

    # ${w}x$h -- fo' realz
    my $dimstr = sub { join("x", @_[0,1]) };

    # figure out possible dimensions, based on valid
    # widths and heights, filtering out dups
    my %dims = ();
    foreach (@FB::VALID_SCALING_W) {
        next if $_ >= $sw || ! $_;

        my ($w, $h) = FB::scale($sw, $sh, $_);
        next unless FB::valid_scaling($w, $h);

        # swap width/height for portrait images
        # - this is for the popup display
        ($w, $h) = ($h, $w) if $swap;
        $dims{$dimstr->($w, $h)} = [$w, $h];
    }
    foreach (@FB::VALID_SCALING_H) {
        next if $_ >= $sh || ! $_;

        my ($w, $h) = FB::scale($sw, $sh, undef, $_);
        next unless FB::valid_scaling($w, $h);

        ($w, $h) = ($h, $w) if $swap;
        $dims{$dimstr->($w, $h)} = [$w, $h];
    }

    # sort based on image area (pixels)
    return map { ( $dimstr->(@$_) => $dimstr->(@$_) ) }
           sort { $a->[0]*$a->[1] <=> $b->[0]*$b->[1] }
           values %dims;
}

# FIXME: this should optionally take a $pic ref with width/height
# info and allow alternate dimensions based on landscape/portrait
sub valid_scaling
{
    my ($w, $h) = @_;
    ($w, $h) = ($h, $w) if $h > $w; # portrait

    return 0 unless grep { $_ == $w } @FB::VALID_SCALING_W;
    return 0 unless grep { $_ == $h } @FB::VALID_SCALING_H;
    return 0 unless $w || $h;

    return 1;
}


sub b28_encode
{
    my $num = shift;
    my $enc = "";
    my $digits = "0123456789abcdefghkpqrstwxyz";
    while ($num) {
        my $dig = $num % 28;
        $enc = substr($digits, $dig, 1) . $enc;
        $num = ($num - $dig) / 28;
    }
    return ("0"x(5-length($enc)) . $enc);
}

sub b28_decode
{
    my $enc = lc(shift);
    unless (defined %FB::B28_TABLE) {
        my $digits = "0123456789abcdefghkpqrstwxyz";
        for (0..27) { $FB::B28_TABLE{substr($digits,$_,1)} = $_; }
    }
    my $num = 0;
    my $place = 0;
    while ($enc) {
        return 0 unless $enc =~ s/\w$//o;
        $num += $FB::B28_TABLE{$&} * (28 ** $place++);
    }
    return $num;
}

sub domainweb
{
    if (my $authmod = FB::current_domain_plugin()) {
        return $authmod->domain_web;
    }

    return $FB::DOMAIN_WEB;
}

sub siteroot
{
    return $FB::SITEROOT;
}

sub user_siteroot
{
    return FB::siteroot();
}

sub remote_root
{
    confess "no auth module";
}

sub sitename
{
    return $FB::SITENAME;
}

sub scale
{
    my ($sw, $sh, $dw, $dh) = @_;

    # or, first arg can be hashref, instead of sw/sh
    if (ref $sw) {
        ($dw, $dh) = ($sh, $dw);
        ($sw, $sh) = ($sw->{'width'}, $sw->{'height'});
    }

    if ($dh==0 && $dw) { return ($dw, int($sh * $dw / $sw)); }
    if ($dw==0 && $dh) { return (int($sw * $dh / $sh), $dh); }
    return ($sw, $sh) unless ($sw && $sh && $dw && $dh);

    if ($sh / $dh > $sw / $dw) {
        # maximize height
        return (int($sw * $dh / $sh), $dh);
    } else {
        # maximize width
        return ($dw, int($sh * $dw / $sw));
    }
}

sub make_code
{
    my ($id, $auth) = @_;
    return (FB::b28_encode($id) .
            substr(FB::b28_encode($auth), 2, 3));
}

sub alloc_uniq {
    my ($u, $table) = @_;
    return $u->alloc_counter("U") if $table eq "upic_ctr";
    return $u->alloc_counter("G") if $table eq "gallery_ctr";
    die "Invalid table type";
}

sub eurl
{
    my $a = $_[0];
    # Note: we intentionally escape commas (",") because they can
    # appear in gallery names, which we send back in HTTP headers,
    # and commas are otherwise header separators
    $a =~ s/([^a-zA-Z0-9_\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

sub durl
{
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

sub did_post
{
    return (BML::get_method() eq "POST");
}

sub bad_input
{
    my @errors = @_;
    my $ret = "";
    $ret .= "<?badcontent?>\n<ul>\n";
    foreach (@errors) {
        $ret .= "<li>$_</li>\n";
    }
    $ret .= "</ul>\n";
    return $ret;
}

# <WCMFUNC>
# name: FB::decode_url_args
# class: web
# des: Parse URL-style arg/value pairs into a hash.
# args: buffer, hashref
# des-buffer: Scalar or scalarref of buffer to parse.
# des-hashref: Hashref to populate.
# returns: boolean; true.
# </WCMFUNC>
sub decode_url_args
{
    my $a = shift;
    my $buffer = ref $a ? $a : \$a;
    my $hashref = shift;  # output hash

    foreach my $pair (split(/&/, $$buffer)) {
        my ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $hashref->{$name} .= $hashref->{$name} ? "\0$value" : $value;
    }
    return 1;
}

# <WCMFUNC>
# name: FB::ehtml
# class: text
# des: Escapes HTML
# args: text
# des-text: Text to escape.
# returns: Escaped text.
# </WCMFUNC>
sub ehtml
{
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&\#39;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}

# <WCMFUNC>
# name: FB::exml
# class: text
# des: Escapes a value before it can be put in XML.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </WCMFUNC>
sub exml
{
    my $a = shift;
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&apos;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}

# <WCMFUNC>
# name: FB::ejs
# class: text
# des: Escapes a string value before it can be put in JavaScript.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </WCMFUNC>
sub ejs
{
    my $a = $_[0];
    $a =~ s/[\"\'\\]/\\$&/g;
    $a =~ s/\r?\n/\\n/gs;
    $a =~ s/\r//gs;
    return $a;
}

# <WCMFUNC>
# name: FB::eall
# class: text
# des: Escapes HTML and BML.
# args: text
# des-text: Text to escape.
# returns: Escaped text.
# </WCMFUNC>
sub eall
{
    my $a = shift;

    ### escape HTML
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;

    ### and escape BML
    $a =~ s/<\?/&lt;?/g;
    $a =~ s/\?>/?&gt;/g;
    return $a;
}


sub html_security ### DEPRECATED:  use $u->security_widget
{
    my ($u, $name, $default) = @_;
    $default = 255 unless defined $default; # public

    my @extra;
    if ($u) {
        $u->{'_secgroups'} ||= FB::load_secgroups($u);

        my $h = $u->{'_secgroups'};
        foreach (sort { $h->{$a}->{'grpname'} cmp $h->{$b}->{'grpname'} }
                 keys %$h) {
            push @extra, $_, $h->{$_}->{'grpname'},
        }
        unshift @extra, '', "----------" if @extra;
    }

    return LJ::html_select({ 'name' => $name,
                             'selected' => $default,
                             'disabled' => ! $u, },
                           255 => "Public",
                           0 => "Private",
                           253 => "Registered Users",
                           254 => "All Groups",
                           @extra);
}

sub html_pics
{
    my ($u, $pics, $opts) = @_;
    return undef unless $u && ref $pics && @$pics;

    my $hook = sub { return ref $opts eq 'HASH' && ref $opts->{$_[0]} eq 'CODE' ? $opts->{$_[0]} : undef };

    my $ret = "<table>";

    my $ct = 0;
    foreach my $p (@$pics) {
        next unless ref $p;

        if ($ct++ % 5 == 0) {
            $ret .= "</tr>" unless $ct == 1;
            $ret .= "<tr valign='bottom'>";
        }

        $ret .= "<td align='center'>";

        # render img tag
        if (my $hk = $hook->('img_tag')) {
            $ret .= $hk->($p);
        } else {
            my $piccode = FB::piccode($p);
            my ($url, $w, $h) = FB::scaled_url($u, $p, 100, 100);
            $ret .= "<a href='/manage/pic?id=$p->{upicid}'>";
            $ret .= "<img src='$url' width=$w height=$h alt='$piccode' align='top' border=0/>";
            $ret .= "</a>";
        }

        # text below image
        if (my $hk = $hook->('img_text')) {
            $ret .= "<br />" . $hk->($p);
        }

        $ret .= "</td>";
    }

    $ret .= "</tr></table>\n";

    return $ret;
}

# <WCMFUNC>
# name: FB::parse_userdomain
# des: Gets username, domainid from a username@domain string
# args: user
# des-user: username in username@domain.com format
# returns: list with 2 elements; user, domainid
# </WCMFUNC>
sub parse_userdomain {
   my $userd = shift;
   return unless defined $userd;

   $userd =~ s/\s+//;
   return undef unless $userd =~ /^(.+?)(?:\@(.+?))?$/;
   my ($user, $domain) = ($1, $2);

   # FIXME: let domain plugin decide what's canonical?
   $user = FB::canonical_username($user);
   return undef unless defined $user;

   my $dmid;
   if (defined $domain) {
       $dmid = FB::get_domain_id($domain);
       return undef unless defined $dmid;
   } else {
       $dmid = FB::current_domain_id();
   }

   return ($user, $dmid);
}

sub fbuser_text
{
    my ($arg, $dmid) = @_;
    return unless $arg;

    my $usercs;
    if (ref $arg) {
        $dmid = $arg->{domainid};
        $usercs = $arg->{usercs};
    } else {
        $usercs = $arg;
    }

    my $ret = FB::canonical_username($usercs);
    if ($dmid != FB::current_domain_id()) {
        $ret .= '@' . FB::get_domainid_name($dmid);
    }
    return $ret;
}

sub fbuser
{
    # should wrap with link fb_usertext
    return "[FIXME: little LJ-headlike thing]";
}

# <WCMFUNC>
# name: FB::paging helper
# des: helper to do paging on a list of items
# args: opts
# des-opts: hashref; keys: items=arrayref of full set of items, page_size=size of each page, page=current page
#                          url_of=code ref to display url of a given page passed as the argument
# returns: hashref; keys: items=truncated arrayref, current_page=current page, total_pages=total pages,
#                         total_items=total items, from_item=first item in page, to_item=last item in page,
#                         num_items_displayed=number of items in current page,
#                         all_items_displayed=true if all items are on this page, url_of=code ref passed earlier
# </WCMFUNC>
sub paging_helper
{
    my $opts = shift;
    my $ir = {};

    # arrayref
    my $items = $opts->{'items'};
    my $page_size = ($opts->{'pagesize'}+0) || 25;
    my $page = $opts->{'page'}+0 || 1;
    my $num_items = scalar @$items;

    my $pages = POSIX::ceil($num_items / $page_size);
    if ($page > $pages) { $page = $pages; }

    splice(@$items, 0, ($page-1)*$page_size) if $page > 1;
    splice(@$items, $page_size) if @$items > $page_size;

    $ir->{'current_page'} = $page;
    $ir->{'total_pages'} = $pages;
    $ir->{'total_items'} = $num_items;
    $ir->{'from_item'} = ($page-1) * $page_size + 1;
    $ir->{'num_items_displayed'} = @$items;
    $ir->{'to_item'} = $ir->{'from_item'} + $ir->{'num_items_displayed'} - 1;
    $ir->{'all_items_displayed'} = ($pages == 1);
    $ir->{'url_of'} = $opts->{'url_of'};

    my $url_of = ref $ir->{'url_of'} eq "CODE" ? $ir->{'url_of'} : sub {"";};

    $ir->{'url_next'} = $url_of->($ir->{'current_page'} + 1)
        unless $ir->{'current'} >= $ir->{'total_pages'};
    $ir->{'url_prev'} = $url_of->($ir->{'current_page'} - 1)
        unless $ir->{'current_page'} <= 1;
    $ir->{'url_first'} = $url_of->(1)
        unless $ir->{'current_page'} == 1;
    $ir->{'url_last'} = $url_of->($ir->{'total_pages'})
        unless $ir->{'current_page'} == $ir->{'total_pages'};

    return $ir;
}

sub get_sysid
{
    return $FB::CACHED_SYSID if $FB::CACHED_SYSID;
    my $su = FB::load_user("system",0);
    return ($FB::CACHED_SYSID = $su->{'userid'});
}

sub get_props  # DEPRECATED
{
    return $FB::CACHED_PROPS if $FB::CACHED_PROPS;
    my %props;
    my $dbr = FB::get_db_reader();
    my $sth = $dbr->prepare("SELECT propid, propname FROM proplist");
    $sth->execute;
    while (my ($id, $name) = $sth->fetchrow_array) {
        $props{$id} = $name;
        $props{$name} = $id;
    }
    $FB::CACHED_PROPS = \%props;
    return $FB::CACHED_PROPS;
}

sub get_des  # DEPRECATED
{
    my ($u, $it) = @_;
    return undef unless
        $u->{'userid'} && $it->{'userid'} && $it->{'userid'} == $u->{'userid'};
    return $it->{'des'} if $it->{'des'};

    my ($type, $id);
    if ($it->{'gallid'}) {
        ($type, $id) = ("G", $it->{'gallid'});
    } elsif ($it->{'upicid'}) {
        ($type, $id) = ("P", $it->{'upicid'});
    }
    return undef unless $id;

    my $des = $u->selectrow_array("SELECT des FROM des WHERE userid=? AND ".
                                  "itemtype=? AND itemid=?",
                                  $u->{'userid'}, $type, $id);
    $it->{'des'} = $des;
    return $des;
}

sub get_des_multi  # DEPRECATED
{
    my ($u, $type, $items, $opts) = @_;
    return undef unless $u && ref $items eq 'ARRAY';
    $opts = {} unless ref $opts eq 'HASH';

    my @need = map { $_->{upicid} } grep { ! $_->{des} } @$items;
    my $itemid_in = join(",", map { $_ + 0 } @need);

    return FB::error("Couldn't connect to user database cluster") unless $u->writer;

    my $sth = $u->prepare("SELECT itemid, des FROM des ".
                          "WHERE userid=? AND itemtype=? AND itemid IN ($itemid_in)",
                          $u->{userid}, $type);
    $sth->execute;
    return FB::error($u) if $u->err;

    my %des = ();
    while (my ($id, $des) = $sth->fetchrow_array) {
        $des{$id} = $des;
    }

    my @ret = ();
    my $idkey = $type eq 'G' ? 'gallid' : 'upicid';
    foreach my $it (@$items) {
        $it->{des} ||= $des{$it->{$idkey}};
        push @ret, $it;
    }

    return @ret;
}

sub format_des  # DEPRECATED
{
    my ($it, $ctx) = @_;
    return unless ref $it eq "HASH" && defined $it->{'des'};

    $it->{'des'} = ehtml($it->{'des'});
    $it->{'des'} =~ s!\n!<br />!g;
}

sub set_des  # DEPRECATED
{
    my ($u, $it, $value) = @_;
    return 0 unless
        $u && $it &&
        $u->{'userid'} && $it->{'userid'} && $it->{'userid'} == $u->{'userid'};
    return 1 if $it->{'des'} eq $value;

    my ($type, $id);
    if ($it->{'gallid'}) {
        ($type, $id) = ("G", $it->{'gallid'});
    } elsif ($it->{'upicid'}) {
        ($type, $id) = ("P", $it->{'upicid'});
    }
    return 0 unless $id;
    return error('utf8') unless FB::is_utf8($value);

    my $udbh = FB::get_user_db_writer($u);
    if ($value) {
        $udbh->do("REPLACE INTO des (userid, itemtype, itemid, des) VALUES ".
                  "(?,?,?,?)", undef, $u->{'userid'}, $type, $id, $value);
        $it->{'des'} = $value;
    } else {
        $udbh->do("DELETE FROM des WHERE userid=? AND itemtype=? AND itemid=?",
                  undef, $u->{'userid'}, $type, $id);
        delete $it->{'des'};
    }
    return 1;
}

sub set_upic_prop  # DEPRECATED
{
    my ($u, $up, $key, $value) = @_;
    return 0 unless
        $u->{'userid'} && $up->{'userid'} && $u->{'userid'} == $up->{'userid'};
    if ($up->{$key} eq $value) { return 1; }

    my $p = FB::get_props();
    return 0 unless $p->{$key};

    my $udbh = FB::get_user_db_writer($u);
    if ($value) {
        $udbh->do("REPLACE INTO upicprop (userid, upicid, propid, value) ".
                  "VALUES (?,?,?,?)", undef, $u->{'userid'}, $up->{'upicid'},
                  $p->{$key}, $value);
        $up->{$key} = $value;
    } else {
        $udbh->do("DELETE FROM upicprop WHERE userid=? AND upicid=? AND propid=?",
                  undef, $u->{'userid'}, $up->{'upicid'}, $p->{$key});
        delete $up->{$key};
    }
    return 1;
}


sub date_unix_to_http
{
    my $time = shift;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($time);
    my @day = qw{Sun Mon Tue Wed Thu Fri Sat};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};
    if ($year < 1900) { $year += 1900; }
    return sprintf("$day[$wday], %02d $month[$mon] $year %02d:%02d:%02d GMT",
                   $mday, $hour, $min, $sec);
}

sub date_unix_to_mysql
{
    my ($time, $gmt) = @_;
    $time ||= time();
    my @ltime = $gmt ? gmtime($time) : localtime($time);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
                   $ltime[5]+1900,
                   $ltime[4]+1,
                   $ltime[3],
                   $ltime[2],
                   $ltime[1],
                   $ltime[0]);
}

sub date_without_zero
{
    my $date = shift;  # yyyy-mm-dd[ hh:mm:ss]
    $date =~ s/\-00.*//g;
    $date =~ s/ 00:00:00$//;
    $date =~ s/:00$//;
    return $date;
}

sub date_from_user
{
    my $date = shift;
    $date =~ s/^\s+//;
    $date =~ s/\s+$//;
    $date =~ s/\s*[\:\-]\s*/ /g;
    my @parts = split(/\s+/, $date);
    return undef unless $parts[0] > 999;
    return undef if $parts[1] > 12;
    return undef if $parts[2] > 31;
    return undef if $parts[3] > 23;
    return undef if $parts[4] > 59;
    return undef if $parts[5] > 59;
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d", map { $_+0 } @parts);
}

sub get_thumb_formats
{
    my $ctx = shift;
    my $fmts_string = S2::get_property_value($ctx, "thumbnails");
    my %ret;

    foreach my $pair (split(/&/, $fmts_string))
    {
        my ($name, $fmtstring) = split(/=/, $pair);
        next unless $name =~ /^\w{1,10}$/;

        my ($w, $h);
        my %flags;
        foreach my $longflag (split(/,/, $fmtstring)) {
            if ($longflag =~ /^(\d+)x(\d+)$/) {
                $w = $1 if $1 <= 200;
                $h = $2 if $2 <= 200;
                $flags{'size'} = sprintf("%02x%02x", $w, $h);
            } elsif ($longflag eq "grey") {
                $flags{'grey'} = "g";
            } elsif ($longflag eq "negate") {
                $flags{'negate'} = "n";
            } elsif ($longflag eq "crop") {
                $flags{'csz'} = "c";
            } elsif ($longflag eq "stretch") {
                $flags{'csz'} = "s";
            } elsif ($longflag eq "zoom") {
                $flags{'csz'} = "z";
            }
        }
        next unless $w && $h;
        $ret{$name} = [ $w, $h, join("", map { $flags{$_} }
                                     qw(grey negate csz)) ];
    }

    return %ret;
}

# <WCMFUNC>
# name: FB::help_icon
# des: Returns BML to show a help link/icon given a help topic, or nothing
#      if the site hasn't defined a URL for that topic.  Optional arguments
#      include HTML/BML to place before and after the link/icon, should it
#      be returned.
# args: topic, pre?, post?
# des-topic: Help topic key.  See doc/ljconfig.pl.txt for examples.
# des-pre: HTML/BML to place before the help icon.
# des-post: HTML/BML to place after the help icon.
# </WCMFUNC>
sub help_icon
{
    my $topic = shift;
    my $pre = shift;
    my $post = shift;
    return "" unless defined $FB::HELPURL{$topic};
    return "$pre<?help $FB::HELPURL{$topic} help?>$post";
}

sub dump
{
    my @args = @_;
    use Data::Dumper;
    return "<pre>" . Dumper(@args) . "</pre>";
}

# <WCMFUNC>
# name: FB::is_utf8
# des: check text for UTF-8 validity
# args: text
# des-text: text to check for UTF-8 validity
# returns: 1 if text is a valid UTF-8 stream, 0 otherwise.
# </WCMFUNC>
sub is_utf8 {
    my $text = shift;
    my $ref = ref $text ? $text : \$text;
    $$ref =~ m/^([\x00-\x7f] |
                 [\xc2-\xdf][\x80-\xbf] |
                 \xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xef][\x80-\xbf][\x80-\xbf] |
                 \xf0[\x90-\xbf][\x80-\xbf][\x80-\xbf] |
                 [\xf1-\xf7][\x80-\xbf][\x80-\xbf][\x80-\xbf])*(.*)/x;
    return 1 unless $2;
    return 0;
}

# DB Reporting UDP socket object
$FB::ReportSock = undef;

# <WCMFUNC>
# name: FB::blocking_report
# des: Log a report on the total amount of time used in a slow operation to a
#      remote host via UDP.
# args: host, time, notes, type
# des-host: The DB host the operation used.
# des-type: The type of service the operation was talking to (e.g., 'database',
#           'memcache', etc.)
# des-time: The amount of time (in floating-point seconds) the operation took.
# des-notes: A short description of the operation.
# </WCMFUNC>
sub blocking_report {
    my ( $host, $type, $time, $notes ) = @_;

    if ( $FB::DB_LOG_HOST ) {
        unless ( $FB::ReportSock ) {
            my ( $host, $port ) = split /:/, $FB::DB_LOG_HOST, 2;
            return unless $host && $port;

            $FB::ReportSock = new IO::Socket::INET (
                PeerPort => $port,
                Proto    => 'udp',
                PeerAddr => $host
               ) or return;
        }

        my $msg = join( "\x3", $host, $type, $time, $notes );
        $FB::ReportSock->send( $msg );
    }
}

# to be called as &nodb; (so this function sees caller's @_)
sub nodb {
    shift @_ if
        ref $_[0] eq "DBI::db" ||
        ref $_[0] eq "DBIx::StateKeeper" ||
        ref $_[0] eq "Apache::DBI::db";
}

# Get style thumbnail information from per-process caches,
# or load if not available
sub get_style_thumbnails
{
    my $now = time;
    return \%FB::CACHE_STYLE_THUMBS if $FB::CACHE_STYLE_THUMBS{'_loaded'} > $now - 300;
    %FB::CACHE_STYLE_THUMBS = ();

    open (PICS, "$FB::HOME/htdocs/img/preview/pics.dat") or return undef;
    while (my $line = <PICS>) {
        chomp $line;
        my ($style, $url) = split(/\t/, $line);
        $FB::CACHE_STYLE_THUMBS{$style} = $url;
    }
    $FB::CACHE_STYLE_THUMBS{'_loaded'} = $now;
    return \%FB::CACHE_STYLE_THUMBS;
}

sub crumbs {
    return "<div class='crumbs'>$_[0]</div>";
}

sub img {
    my $ic = shift;
    my $type = shift;  # either "" or "input"
    my $attr = shift;
    require "$ENV{FBHOME}/cgi-bin/imageconf.pl";

    my $i = $FB::Img::img{$ic};
    return ("$FB::IMGPREFIX$i->{src}", $i->{width}, $i->{height}) if wantarray;

    my $attrs;
    if ($attr) {
        if (ref $attr eq "HASH") {
            foreach (keys %$attr) {
                $attrs .= " $_=\"" . FB::ehtml($attr->{$_}) . "\"";
            }
        } else {
            $attrs = " name=\"$attr\"";
        }
    }

    if ($type eq "") {
        return "<img src=\"$FB::IMGPREFIX$i->{'src'}\" width=\"$i->{'width'}\" ".
            "height=\"$i->{'height'}\" alt=\"$i->{'alt'}\" title=\"$i->{'alt'}\" ".
            "border='0'$attrs />";
    }
    if ($type eq "input") {
        return "<input type=\"image\" src=\"$FB::IMGPREFIX$i->{'src'}\" ".
            "width=\"$i->{'width'}\" height=\"$i->{'height'}\" title=\"$i->{'alt'}\" ".
            "alt=\"$i->{'alt'}\" border='0'$attrs />";
    }
    return "<b>XXX</b>";
}

# given a URI to an image, return (user, upicid, auth, seperator, extra, extension)
sub decode_picture_uri {
    my $uri = shift;

    my ($user, $upicid, $auth, $separator, $extra, $extension) =
        $uri =~ m!^
        (?:/(\w+))?    # /user
        /pic/
        (\w{5,5})      # upicid, b28 encoded
        (\w\w\w)       # auth,   b28 encoded
        (/|--)?        # / or -- separator (old vs. new way, respectively)
        (\w*)?         # extra options
        (?:\.(\w{3,4}))?  # option extension, 3 or 4 characters
        $!x;

    my $ret = {
        'user'      => $user,
        'upicid'    => $upicid,
        'auth'      => $auth,
        'separator' => $separator,
        'extra'     => $extra,
        'extension' => $extension,
    };

    return $ret;
}

# given a URI to a gallery, return ($user, $gallid, $auth, $eurl_tag)
sub decode_gallery_uri {
    my $uri = shift;

    my ($user, $gallid, $auth, $eurl_tag) = $uri =~ m!^(?:/(\w+))?/(?:gallery/(.....)(...)|tags?/([\S ]+?))/?(\.xml)?$!;

    my $ret = {
        'user'      => $user,
        'gallid'    => $gallid,
        'auth'      => $auth,
        'eurl_tag'  => $eurl_tag,
    };

    return $ret;
}

# returns path, width, height, mime
# yeah this is kinda silly here but it's better than hardcoding it in lots of places
sub audio_thumbnail_info {
    return ('img/dynamic/audio_200x200.gif', 100, 100, 'image/gif');
}

sub res_includes {
    my $ret = "";
    my $do_concat = $FB::IS_SSL ? $FB::CONCAT_RES_SSL : $FB::CONCAT_RES;

    my $remote = FB::get_remote();
    my $hasremote = $remote ? 'true' : 'false';

    # include standard JS info
    $ret .= qq {
        <script language="JavaScript" type="text/javascript">
        var Site = {};
        Site.imgprefix = "$FB::IMGPREFIX";
        Site.siteroot = "$FB::SITEROOT";
        Site.has_remote = $hasremote;
        </script>
        };

    my $now = time();
    my %list;   # type -> [];
    my %oldest; # type -> $oldest
    my $add = sub {
        my ($type, $what, $modtime) = @_;

        # in the concat-res case, we don't directly append the URL w/
        # the modtime, but rather do one global max modtime at the
        # end, which is done later in the tags function.
        $what .= "?v=$modtime" unless $do_concat;

        push @{$list{$type} ||= []}, $what;
        $oldest{$type} = $modtime if $modtime > $oldest{$type};
    };

    foreach my $path (@FB::NEEDED_RES) {
        my $mtime = _file_modtime($path, $now);

        # if we want to also include a local version of this file, include that too
        if (@FB::USE_LOCAL_RES) {
            if (grep { lc $_ eq lc $path } @FB::USE_LOCAL_RES) {
                my $inc = $path;
                $inc =~ s/(\w+)\.(\w+)$/$1-local.$2/;
                FB::need_res($inc);
            }
        }

        if ($path =~ m!^js/(.+)!) {
            $add->('js', $1, $mtime);
        } elsif ($path =~ m!^static/(.+)!) {
            $add->('static', $1, $mtime);
        }
    }

    my $tags = sub {
        my ($type, $template) = @_;
        my $list;
        return unless $list = $list{$type};

        if ($do_concat) {
            my $csep = join(',', @$list);
            $csep .= "?v=" . $oldest{$type};
            $template =~ s/__+/??$csep/;
            $ret .= $template;
        } else {
            foreach my $item (@$list) {
                my $inc = $template;
                $inc =~ s/__+/$item/;
                $ret .= $inc;
            }
        }
    };

    $tags->("js", "<script type=\"text/javascript\" src=\"$FB::SITEROOT/js/___\"></script>\n");
    $tags->("static", "<link rel=\"stylesheet\" type=\"text/css\" href=\"$FB::SITEROOT/static/___\" />\n");
    return $ret;
}

sub need_res {
    foreach my $reskey (@_) {
        die "Bogus reskey $reskey" unless $reskey =~ m!^(js|static)/!;
        unless ($FB::NEEDED_RES{$reskey}++) {
            push @FB::NEEDED_RES, $reskey;
        }
    }
}

{
    my %stat_cache = ();  # key -> {lastcheck, modtime}
    sub _file_modtime {
        my ($key, $now) = @_;
        if (my $ci = $stat_cache{$key}) {
            if ($ci->{lastcheck} > $now - 10) {
                return $ci->{modtime};
            }
        }

        my $set = sub {
            my $mtime = shift;
            $stat_cache{$key} = { lastcheck => $now, modtime => $mtime };
            return $mtime;
        };

        my $file = "$FB::HOME/htdocs/$key";
        my $mtime = (stat($file))[9];
        return $set->($mtime);
    }
}

1;
