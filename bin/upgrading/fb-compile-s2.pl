#!/usr/bin/perl

# Run this to compile S2 layers for FB

use strict;
use lib $ENV{LJHOME} . '/cgi-bin';
require 'ljlib.pl';

print " - Compiling S2 layers for FB...\n";
compile_s2_layers();
print " - Done.\n";


sub compile_s2_layers {
    my $dbh = FB::get_db_writer()
        or die "Could not get FB DB reader";

    ##### add the S2 layers
    my $LD = "s2layers"; # layers dir

    # get the system account's userid (making it, if needed)
    my $su = FB::load_user("system", 0);
    my $sysid;
    unless ($su) {
        $sysid = FB::User->create({
            'domainid' => 0,
            'usercs' => 'system',
        });
        $su = FB::load_user("system", 0);
        die "Couldn't create system account" unless $sysid && $su;
        print "Created system account.\n";
    } else {
        $sysid = $su->{'userid'};
    }

    # find existing re-distributed layers that are in the database
    # and their styleids.
    my $existing = FB::get_public_layers($sysid);

    my $fbupgrade_dir = "$ENV{'LJHOME'}/bin/upgrading/fb";

    chdir $fbupgrade_dir or die "$fbupgrade_dir does not exist.\n";
    my %layer;    # maps redist_uniq -> { 'type', 'parent' (uniq), 'id' (s2lid) }
    {
        my $compile = sub {
            my ($base, $type, $parent, $s2source) = @_;
            return unless $s2source =~ /\S/;

            my $id = $existing->{$base} ? $existing->{$base}->{'s2lid'} : 0;
            unless ($id) {
                my $parentid = 0;
                $parentid = $layer{$parent}->{'id'} unless $type eq "core";
                # allocate a new one.
                $dbh->do("INSERT INTO s2layers (s2lid, b2lid, userid, type) ".
                         "VALUES (NULL, $parentid, $sysid, ?)", undef, $type);
                die $dbh->errstr if $dbh->err;
                $id = $dbh->{'mysql_insertid'};
                if ($id) {
                    $dbh->do("INSERT INTO s2info (s2lid, infokey, value) VALUES (?,'redist_uniq',?)",
                             undef, $id, $base);
                }
            }
            die "Can't generate ID for '$base'" unless $id;

            $layer{$base} = {
                'type' => $type,
                'parent' => $parent,
                'id' => $id,
            };

            my $parid = $layer{$parent}->{'id'};

            # see if source changed
            my $md5_source = Digest::MD5::md5_hex($s2source);
            my $md5_exist = $dbh->selectrow_array("SELECT MD5(s2code) FROM s2source WHERE s2lid=?", undef, $id);

            # skip compilation if source is unchanged and parent wasn't rebuilt.
            return if $md5_source eq $md5_exist && ! $layer{$parent}->{'built'};

            print "$base($id) is $type";
            if ($parid) { print ", parent = $parent($parid)"; };
            print "\n";

            # we're going to go ahead and build it.
            $layer{$base}->{'built'} = 1;

            # compile!
            my $lay = {
                's2lid' => $id,
                'userid' => $sysid,
                'b2lid' => $parid,
                'type' => $type,
            };
            my $error = "";
            my $compiled;
            my $info;
            die $error unless FB::layer_compile($lay, \$error, {
                's2ref' => \$s2source,
                'redist_uniq' => $base,
                'compiledref' => \$compiled,
                'layerinfo' => \$info,
            });

            # put raw S2 in database.
            $dbh->do("REPLACE INTO s2source (s2lid, s2code) ".
                     "VALUES ($id, ?)", undef, $s2source);
            die $dbh->errstr if $dbh->err;
        };

        my @layerfiles = ("s2layers.dat");
        foreach my $file ("s2layers.dat", "s2layers-local.dat") {
            next unless -e $file;
            open (SL, $file) or die;
            print "SOURCE: $file\n";
            while (<SL>) {
                s/\#.*//; s/^\s+//; s/\s+$//;
                next unless /\S/;
                my ($base, $type, $parent) = split;

                if ($type eq "INCLUDE") {
                    push @layerfiles, $base;
                    next;
                }

                if ($type ne "core" && ! defined $layer{$parent}) {
                    die "'$base' references unknown parent '$parent'\n";
                }

                # is the referenced $base file really an aggregation of
                # many smaller layers?  (likely themes, which tend to be small)
                my $multi = ($type =~ s/\+$//);

                my $s2source;
                open (L, "$LD/$base.s2") or die "Can't open file: $base.s2\n";

                unless ($multi) {
                    while (<L>) { $s2source .= $_; }
                    $compile->($base, $type, $parent, $s2source);
                } else {
                    my $curname;
                    while (<L>) {
                        if (/^\#NEWLAYER:\s*(\S+)/) {
                            my $newname = $1;
                            $compile->($curname, $type, $parent, $s2source);
                            $curname = $newname;
                            $s2source = "";
                        } elsif (/^\#NEWLAYER/) {
                            die "Badly formatted \#NEWLAYER line";
                        } else {
                            $s2source .= $_;
                        }
                    }

                    $compile->($curname, $type, $parent, $s2source);
                }
                close L;
            }
            close SL;
        }
    }
}
