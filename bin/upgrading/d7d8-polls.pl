#!/usr/bin/perl
#
# Goes over every user, updating their dversion to 8 and
# migrating whatever polls they have to their user cluster

use strict;
use lib "$ENV{'LJHOME'}/cgi-bin/";
require "ljlib.pl";
use LJ::Poll;

my $BLOCK_SIZE = 10_000; # get users in blocks of 10,000
my $VERBOSE    = 0;      # print out extra info

my $dbh = LJ::get_db_writer()
    or die "Could not connect to global master";

# get user count
my $total = $dbh->selectrow_array("SELECT COUNT(*) FROM user WHERE dversion = 7");
print "Total users at dversion 7: $total\n";

my $migrated = 0;

foreach my $cid (@LJ::CLUSTERS) {
    my $udbh = LJ::get_cluster_master($cid)
        or die "Could not get cluster master handle for cluster $cid";

    while (1) {
        my $sth = $dbh->prepare("SELECT userid FROM user WHERE dversion=7 AND clusterid=? LIMIT $BLOCK_SIZE");
        $sth->execute($cid);
        die $sth->errstr if $sth->err;

        my $count = $sth->rows;
        print "Got $count users on cluster $cid with dversion=7\n";
        last unless $count;

        while (my ($userid) = $sth->fetchrow_array) {
            my $u = LJ::load_userid($userid)
                or die "Invalid userid: $userid";

            my $ok = $u->upgrade_to_dversion_8;
            my $ok = 1;

            print "Migrated user " . $u->user . "... " . ($ok ? 'ok' : 'ERROR') . "\n"
                if $VERBOSE;

            $migrated++ if $ok;
        }

        print "Migrated $migrated users so far\n\n";

        # make sure we don't end up running forever for whatever reason
        last if $migrated > $total;
    }
}

print "\nDone migrating $migrated of $total users to dversion 8\n";
