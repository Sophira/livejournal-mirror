#!/usr/bin/perl

use strict;
use lib "$ENV{LJHOME}/cgi-bin";
require 'ljlib.pl';
use LJ::Blob;
use LJ::User;
use Getopt::Long;
use IPC::Open3;
use Digest::MD5;

# this script is a migrater that will move phone posts from an old storage method
# into mogilefs.

# the basic theory is that we iterate over all clusters, find all phoneposts that
# aren't in mogile right now, and put them there

# determine 
my ($one, $besteffort, $dryrun, $user, $verify, $verbose, $clusters);
my $rv = GetOptions("best-effort"  => \$besteffort,
                    "one"          => \$one,
                    "dry-run"      => \$dryrun,
                    "user=s"       => \$user,
                    "verify"       => \$verify,
                    "verbose"      => \$verbose,
                    "clusters=s"   => \$clusters,);
unless ($rv) {
    die <<ERRMSG;
This script supports the following command line arguments:

    --clusters=X[-Y]
        Only handle clusters in this range.  You can specify a single
        number, or a range of two numbers with a dash.

    --user=username
        Only move this particular user.
        
    --one
        Only move one user.  (But it moves all their phone posts.)  This is
        used for testing.

    --verify
        If specified, this option will reload the phonepost from MogileFS and
        make sure it's been stored successfully.

    --dry-run
        If on, do not update the database.  This mode will put the phonepost
        in MogileFS and give you paths to examine the phone posts and make
        sure everything is okay.  It will not update the phonepost2 table,
        though.

    --best-effort
        Normally, if a problem is encountered (null phonepost, md5 mismatch,
        connection failure, etc) the script will die to make sure
        everything goes well.  With this flag, we don't die and instead
        just print to standard error.

    --verbose
        Be very chatty.
ERRMSG
}

# make sure ljconfig is setup right (or so we hope)
die "Please define a 'phoneposts' class in your \%LJ::MOGILEFS_CONFIG\n"
    unless defined $LJ::MOGILEFS_CONFIG{classes}->{phoneposts};
die "Unable to find MogileFS object (\%LJ::MOGILEFS_CONFIG not setup?)\n"
    unless $LJ::MogileFS;

# setup stderr if we're in best effort mode
if ($besteffort) {
    my $oldfd = select(STDERR);
    $| = 1;
    select($oldfd);
}

# operation modes
if ($user) {
    # move a single user
    my $u = LJ::load_user($user);
    die "No such user: $user\n" unless $u;
    handle_userid($u->{userid}, $u->{clusterid});
    
} else {
    # parse the clusters
    my @clusters;
    if ($clusters) {
        if ($clusters =~ /^(\d+)(?:-(\d+))?$/) {
            my ($min, $max) = map { $_ + 0 } ($1, $2 || $1);
            push @clusters, $_ foreach $min..$max;
        } else {
            die "Error: --clusters argument not of right format.\n";
        }
    } else {
        @clusters = @LJ::CLUSTERS;
    }
    
    # now iterate over the clusters to pick
    my $ctotal = scalar(@clusters);
    my $ccount = 0;
    foreach my $cid (sort { $a <=> $b } @clusters) {
        # status report
        $ccount++;
        print "\nChecking cluster $cid...\n\n";

        # get a handle
        my $dbcm = get_db_handle($cid);

        # get all userids
        print "Getting userids...\n";
        my $limit = $one ? 'LIMIT 1' : '';
        my $userids = $dbcm->selectcol_arrayref
            ("SELECT DISTINCT userid FROM phonepostentry WHERE location <> 'mogile' OR location IS NULL $limit");
        my $total = scalar(@$userids);

        # iterate over userids
        my $count = 0;
        print "Beginning iteration over userids...\n";
        foreach my $userid (@$userids) {
            # move this phonepost
            my $extra = sprintf("[%6.2f%%, $ccount of $ctotal] ", (++$count/$total*100));
            handle_userid($userid, $cid, $extra);
        }

        # don't hit up more clusters
        last if $one;
    }
}
print "\n";

print "Updater terminating.\n";

#############################################################################
### helper subs down here

# take a userid and move their phone posts
sub handle_userid {
    my ($userid, $cid, $extra) = @_;
    
    # load user to move and do some sanity checks
    my $u = LJ::load_userid($userid);
    unless ($u) {
        LJ::end_request();
        LJ::start_request();
        $u = LJ::load_userid($userid);
    }
    die "ERROR: Unable to load userid $userid\n"
        unless $u;

    # if a user has been moved to another cluster, but the source data from
    # phonepost2 wasn't deleted, we need to ignore the user
    return unless $u->{clusterid} == $cid;

    # get a handle if we weren't given one
    my $dbcm = get_db_handle($u->{clusterid});

    # get all their photos that aren't in mogile already
    my $rows = $dbcm->selectall_arrayref
        ("SELECT filetype, blobid FROM phonepostentry WHERE userid = ? AND (location <> 'mogile' OR location IS NULL)",
         undef, $u->{userid});
    return unless @$rows;

    # print that we're doing this user
    print "$extra$u->{user}($u->{userid})\n";

    # now we have a userid and blobids, get the photos from the blob server
    foreach my $row (@$rows) {
        my ($filetype, $blobid) = @$row;
        print "\tstarting move for blobid $blobid\n"
            if $verbose;
        my $format = { 0 => 'mp3', 1 => 'ogg', 2 => 'wav' }->{$filetype};
        my $data = LJ::Blob::get($u, "phonepost", $format, $blobid);

        # get length
        my $len = length($data);
        if ($besteffort && !$len) {
            print STDERR "empty_phonepost userid=$u->{userid} blobid=$blobid\n";
            print "\twarning: empty phonepost.\n\n"
                if $verbose;
            next;
        }
        die "Error: data from blob empty ($u->{user}, 'phonepost', $format, $blobid)\n"
            unless $len;

        # get filehandle to Mogile and put the file there
        print "\tdata length = $len bytes, uploading to MogileFS...\n"
            if $verbose;
        my $fh = $LJ::MogileFS->new_file("pp:$u->{userid}:$blobid", 'phoneposts');
        if ($besteffort && !$fh) {
            print STDERR "new_file_failed userid=$u->{userid} blobid=$blobid\n";
            print "\twarning: failed in call to new_file\n\n"
                if $verbose;
            next;
        }
        die "Unable to get filehandle to save file to MogileFS\n"
            unless $fh;

        # now save the file and close the handles
        $fh->print($data);
        my $rv = $fh->close;
        if ($besteffort && !$rv) {
            print STDERR "close_failed userid=$u->{userid} blobid=$blobid reason=$@\n";
            print "\twarning: failed in call to cloes: $@\n\n"
                if $verbose;
            next;
        }
        die "Unable to save file to MogileFS: $@\n"
            unless $rv;

        # extra verification
        if ($verify) {
            my $data2 = $LJ::MogileFS->get_file_data("pp:$u->{userid}:$blobid");
            my $eq = ($data2 && $$data2 eq $data) ? 1 : 0;
            if ($besteffort && !$eq) {
                print STDERR "verify_failed userid=$u->{userid} blobid=$blobid\n";
                print "\twarning: verify failed; phone post not updated\n\n"
                    if $verbose;
                next;
            }
            die "\tERROR: phone post NOT stored successfully, content mismatch\n"
                unless $eq;
            print "\tverified length = " . length($$data2) . " bytes...\n"
                if $verbose;
        }

        # done moving this phone post
        unless ($dryrun) {
            print "\tupdating database for this phone post...\n"
                if $verbose;
            $dbcm->do("UPDATE phonepostentry SET location = 'mogile' WHERE userid = ? AND blobid = ?",
                      undef, $u->{userid}, $blobid);
        }

        # get the paths so the user can verify if they want
        if ($verbose) {
            my @paths = $LJ::MogileFS->get_paths("pp:$u->{userid}:$blobid", 1);
            print "\tverify mogile path: $_\n" foreach @paths;
            print "\tphone post update complete.\n\n";
        }
    }
}

# a sub to get a cluster handle and set it up for our use
sub get_db_handle {
    my $cid = shift;
    
    my $dbcm = LJ::get_cluster_master({ raw => 1 }, $cid);
    unless ($dbcm) {
        print STDERR "handle_unavailable clusterid=$cid\n";
        die "ERROR: unable to get raw handle to cluster $cid\n";
    }
    eval {
        $dbcm->do("SET wait_timeout = 28800");
        die $dbcm->errstr if $dbcm->err;
    };
    die "Couldn't set wait_timeout on $cid: $@\n" if $@;
    $dbcm->{'RaiseError'} = 1;
    
    return $dbcm;
}
