#!/usr/bin/perl
#
# <LJDEP>
# lib: cgi-bin/ljlib.pl
# </LJDEP>

use strict;
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

my $dbh = LJ::get_dbh("master");

# what tables don't we want to export the auto_increment columns from
# because they already have their own unique string, which is what matters
my %skip_auto = ("userproplist" => "name",
                 "talkproplist" => "name",
                 "logproplist" => "name",
                 "priv_list" => "privcode",
                 "supportcat" => "catkey",
                 "ratelist" => "rlid",
                 );

# get tables to export
my %tables = ();
my $sth = $dbh->prepare("SELECT tablename, redist_mode, redist_where ".
                        "FROM schematables WHERE redist_mode NOT IN ('off')");
$sth->execute;
while (my ($table, $mode, $where) = $sth->fetchrow_array) {
    $tables{$table}->{'mode'} = $mode;
    $tables{$table}->{'where'} = $where;
}

my %output;  # {general|local} -> [ [ $alphasortkey, $SQL ]+ ]

# dump each table.
foreach my $table (sort keys %tables)
{
    my $where;
    if ($tables{$table}->{'where'}) {
        $where = "WHERE $tables{$table}->{'where'}";
    }

    my $sth = $dbh->prepare("DESCRIBE $table");
    $sth->execute;
    my @cols = ();
    my $skip_auto = 0;
    while (my $c = $sth->fetchrow_hashref) {
        if ($c->{'Extra'} =~ /auto_increment/ && $skip_auto{$table}) {
            $skip_auto = 1;
        } else {
            push @cols, $c;
        }
    }

    my $cols = join(", ", map { $_->{'Field'} } @cols);
    my $sth = $dbh->prepare("SELECT $cols FROM $table $where");
    $sth->execute;
    my $sql;
    while (my @r = $sth->fetchrow_array)
    {
        my %vals;
        my $i = 0;
        foreach (map { $_->{'Field'} } @cols) {
            $vals{$_} = $r[$i++];
        }
        my $scope = "general";
        $scope = "local" if (defined $vals{'scope'} &&
                             $vals{'scope'} eq "local");
        my $verb = "INSERT IGNORE";
        $verb = "REPLACE" if ($tables{$table}->{'mode'} eq "replace" &&
                              ! $skip_auto);
        $sql = "$verb INTO $table ";
        if ($skip_auto) { $sql .= "($cols) "; }
        $sql .= "VALUES (" . join(", ", map { $dbh->quote($_) } @r) . ");\n";

        my $uniqc = $skip_auto{$table};
        my $skey = $uniqc ? $vals{$uniqc} : $sql;
        push @{$output{$scope}}, [ "$table.$skey.1", $sql ];

        if ($skip_auto) {
            # for all the *proplist tables, there might be new descriptions
            # or columns, but we can't do a REPLACE, because that'd mess
            # with their auto_increment ids, so we do insert ignore + update
            my $where = "$uniqc=" . $dbh->quote($vals{$uniqc});
            delete $vals{$uniqc};
            $sql = "UPDATE $table SET ";
            $sql .= join(",", map { "$_=" . $dbh->quote($vals{$_}) } keys %vals);
            $sql .= " WHERE $where;\n";
            push @{$output{$scope}}, [ "$table.$skey.2", $sql ];
        }
    }
}

foreach my $k (keys %output) {
    my $file = $k eq "general" ? "base-data.sql" : "base-data-local.sql";
    print "Dumping $file\n";
    my $ffile = "$ENV{'LJHOME'}/bin/upgrading/$file";
    open (F, ">$ffile") or die "Can't write to $ffile\n";
    foreach (sort { $a->[0] cmp $b->[0] } @{$output{$k}}) {
        print F $_->[1];
    }
    close F;
}

# and do S1 styles (ugly schema)
print "Dumping s1styles.dat\n";
require "$ENV{'LJHOME'}/bin/upgrading/s1style-rw.pl";
my $ss = {};
$sth = $dbh->prepare("SELECT user, styledes, type, formatdata, is_embedded, ".
                     "is_colorfree, lastupdate ".
                     "FROM style WHERE user='system' AND is_public='Y'");
$sth->execute;
while (my $s = $sth->fetchrow_hashref) {
    my $uniq = "$s->{'type'}/$s->{'styledes'}";
    $ss->{$uniq}->{$_} = $s->{$_} foreach (keys %$s);
}
s1styles_write($ss);

print "Done.\n";
