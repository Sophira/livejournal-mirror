#!/usr/bin/perl
#
# This program deals with inserting/extracting text/language data
# from the database.
#

use strict;
use Getopt::Long;

my $opt_help = 0;
my $opt_local_lang;
my $opt_extra;
exit 1 unless
GetOptions(
           "help" => \$opt_help,
           "local-lang=s" => \$opt_local_lang,
           "extra=s" => \$opt_extra,
           );

my $mode = shift @ARGV;

help() if $opt_help or not defined $mode or @ARGV;

sub help
{
    die "Usage: texttool.pl <commands>

Where 'command' is one of:
  load         Runs the following three commands in order:
    popstruct  Populate lang data from text[-local].dat into db
    poptext    Populate text from en.dat, etc into database
    copyfaq    If site is translating FAQ, copy FAQ data into trans area
    makeusable Setup internal indexes necessary after loading text
  dumptext     Dump lang text based on text[-local].dat information
  check        Check validity of text[-local].dat files
  wipedb       Remove all language/text data from database.
  newitems     Search files in htdocs, cgi-bin, & bin and insert
               necessary text item codes in database.

               Optionally:
                  --local-lang=..  If given, works on local site files too

";
}

## make sure $LJHOME is set so we can load & run everything
unless (-d $ENV{'LJHOME'}) {
    die "LJHOME environment variable is not set, or is not a directory.\n".
        "You must fix this before you can run this database update script.";
}
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

my %dom_id;     # number -> {}
my %dom_code;   # name   -> {}
my %lang_id;    # number -> {}
my %lang_code;  # name   -> {}
my @lang_domains; 

my $set = sub {
    my ($hash, $key, $val, $errmsg) = @_;
    die "$errmsg$key\n" if exists $hash->{$key};
    $hash->{$key} = $val;
};

foreach my $scope ("general", "local")
{
    my $file = $scope eq "general" ? "text.dat" : "text-local.dat";
    my $ffile = "$ENV{'LJHOME'}/bin/upgrading/$file";
    unless (-e $ffile) {
        next if $scope eq "local";
        die "$file file not found; odd: did you delete it?\n";
    }
    open (F, $ffile) or die "Can't open file: $file: $!\n";
    while (<F>) {
        s/\s+$//; s/^\#.+//;
        next unless /\S/;
        my @vals = split(/:/, $_);
        my $what = shift @vals;

        # language declaration
        if ($what eq "lang") {
            my $lang = { 
                'scope'  => $scope,
                'lnid'   => $vals[0],
                'lncode' => $vals[1],
                'lnname' => $vals[2],
                'parentlnid' => 0,   # default.  changed later.
                'parenttype' => 'diff',
            };
            $lang->{'parenttype'} = $vals[3] if defined $vals[3];
            if (defined $vals[4]) {
                unless (exists $lang_code{$vals[4]}) {
                    die "Can't declare language $lang->{'lncode'} with missing parent language $vals[4].\n";
                }
                $lang->{'parentlnid'} = $lang_code{$vals[4]}->{'lnid'};
            }
            $set->(\%lang_id,   $lang->{'lnid'},   $lang, "Language already defined with ID: ");
            $set->(\%lang_code, $lang->{'lncode'}, $lang, "Language already defined with code: ");
        }

        # domain declaration
        if ($what eq "domain") {
            my $dcode = $vals[1];
            my ($type, $args) = split(m!/!, $dcode);
            my $dom = {
                'scope' => $scope,
                'dmid' => $vals[0],
                'type' => $type,
                'args' => $args || "",
            };
            $set->(\%dom_id,   $dom->{'dmid'}, $dom, "Domain already defined with ID: ");
            $set->(\%dom_code, $dcode, $dom, "Domain already defined with parameters: ");
        }

        # langdomain declaration
        if ($what eq "langdomain") {
            my $ld = {
                'lnid' => 
                    (exists $lang_code{$vals[0]} ? $lang_code{$vals[0]}->{'lnid'} : 
                     die "Undefined language: $vals[0]\n"),
                'dmid' =>
                    (exists $dom_code{$vals[1]} ? $dom_code{$vals[1]}->{'dmid'} : 
                     die "Undefined domain: $vals[1]\n"),
                'dmmaster' => $vals[2] ? "1" : "0",
                };
            push @lang_domains, $ld;
        }
    }
    close F;
}

if ($mode eq "check") {
    print "all good.\n";
    exit 0;
}

## make sure we can connect
my $dbh = LJ::get_dbh("master");
my $sth;
unless ($dbh) {
    die "Can't connect to the database.\n";
}

# indenter
my $idlev = 0;
my $out = sub {
    my @args = @_;
    while (@args) {
        my $a = shift @args;
        if ($a eq "+") { $idlev++; }
        elsif ($a eq "-") { $idlev--; }
        elsif ($a eq "x") { $a = shift @args; die "  "x$idlev . $a . "\n"; }
        else { print "  "x$idlev, $a, "\n"; }
    }
};

my @good = qw(load popstruct poptext dumptext newitems wipedb makeusable copyfaq);

popstruct() if $mode eq "popstruct" or $mode eq "load";
poptext() if $mode eq "poptext" or $mode eq "load";
copyfaq() if $mode eq "copyfaq" or $mode eq "load";
makeusable() if $mode eq "makeusable" or $mode eq "load";
dumptext() if $mode eq "dumptext";
newitems() if $mode eq "newitems";
wipedb() if $mode eq "wipedb";
help() unless grep { $mode eq $_ } @good;
exit 0;

sub makeusable
{
    $out->("Making usable...", '+');
    my $rec = sub {
        my ($lang, $rec) = @_;
        my $l = $lang_code{$lang};
        $out->("x", "Bogus language: $lang") unless $l;
        my @children = grep { $_->{'parentlnid'} == $l->{'lnid'} } values %lang_code;
        foreach my $cl (@children) {
            $out->("$l->{'lncode'} -- $cl->{'lncode'}");

            my %need;
            # push downwards everything that has some valid text in some language (< 4)
            $sth = $dbh->prepare("SELECT dmid, itid, txtid FROM ml_latest WHERE lnid=$l->{'lnid'} AND staleness < 4");
            $sth->execute;
            while (my ($dmid, $itid, $txtid) = $sth->fetchrow_array) {
                $need{"$dmid:$itid"} = $txtid;
            }
            $sth = $dbh->prepare("SELECT dmid, itid, txtid FROM ml_latest WHERE lnid=$cl->{'lnid'}");
            $sth->execute;
            while (my ($dmid, $itid, $txtid) = $sth->fetchrow_array) {
                delete $need{"$dmid:$itid"};
            }
            while (my $k = each %need) {
                my ($dmid, $itid) = split(/:/, $k);
                my $txtid = $need{$k};
                my $stale = $cl->{'parenttype'} eq "diff" ? 3 : 0;
                $dbh->do("INSERT INTO ml_latest (lnid, dmid, itid, txtid, chgtime, staleness) VALUES ".
                         "($cl->{'lnid'}, $dmid, $itid, $txtid, NOW(), $stale)");
                die $dbh->errstr if $dbh->err;
            }
            $rec->($cl->{'lncode'}, $rec);
        }
    };
    $rec->("en", $rec);
    $out->("-", "done.");
}

sub copyfaq
{
    my $faqd = LJ::Lang::get_dom("faq");
    my $ll = LJ::Lang::get_root_lang($faqd);
    unless ($ll) { return; }

    my $domid = $faqd->{'dmid'};

    $out->("Copying FAQ...", '+');

    my %existing;
    $sth = $dbh->prepare("SELECT i.itcode FROM ml_items, ml_latest WHERE l.lnid=$ll->{'lnid'} AND dmid=$domid AND l.itid=i.itid AND i.dmid=$domid");
    $sth->execute;
    $existing{$_} = 1 while $_ = $sth->fetchrow_array;

    # faq category
    $sth = $dbh->prepare("SELECT faqcat, faqcatname FROM faqcat");
    $sth->execute;
    while (my ($cat, $name) = $sth->fetchrow_array) {
        next if exists $existing{"cat.$cat"};
        my $opts = { 'childrenlatest' => 1 };
        LJ::Lang::set_text($dbh, $domid, $ll->{'lncode'}, "cat.$cat", $name, $opts);
    }

    # faq items
    $sth = $dbh->prepare("SELECT faqid, question, answer FROM faq");
    $sth->execute;
    while (my ($faqid, $q, $a) = $sth->fetchrow_array) {
        next if
            exists $existing{"$faqid.1question"} and
            exists $existing{"$faqid.2answer"};
        my $opts = { 'childrenlatest' => 1 };
        LJ::Lang::set_text($dbh, $domid, $ll->{'lncode'}, "$faqid.1question", $q, $opts);
        LJ::Lang::set_text($dbh, $domid, $ll->{'lncode'}, "$faqid.2answer", $a, $opts);
    }

    $out->('-', "done.");
}

sub wipedb
{
    $out->("Wiping DB...", '+');
    foreach (qw(domains items langdomains langs latest text)) {
        $out->("deleting from $_");
        $dbh->do("DELETE FROM ml_$_");
    }
    $out->("-", "done.");
}

sub popstruct
{
    $out->("Populating structure...", '+');
    foreach my $l (values %lang_id) {
        $out->("Inserting language: $l->{'lnname'}");
        $dbh->do("INSERT INTO ml_langs (lnid, lncode, lnname, parenttype, parentlnid) ".
                 "VALUES (" . join(",", map { $dbh->quote($l->{$_}) } qw(lnid lncode lnname parenttype parentlnid)) . ")");
    }

    foreach my $d (values %dom_id) {
        $out->("Inserting domain: $d->{'type'}\[$d->{'args'}\]");
        $dbh->do("INSERT INTO ml_domains (dmid, type, args) ".
                 "VALUES (" . join(",", map { $dbh->quote($d->{$_}) } qw(dmid type args)) . ")");
    }

    $out->("Inserting language domains ...");
    foreach my $ld (@lang_domains) {
        $dbh->do("INSERT IGNORE INTO ml_langdomains (lnid, dmid, dmmaster) VALUES ".
                 "(" . join(",", map { $dbh->quote($ld->{$_}) } qw(lnid dmid dmmaster)) . ")");
    }
    $out->("-", "done.");
}

sub poptext
{
    $out->("Populating text...", '+');
    my %source;  # lang -> file, or "[extra]" when given by --extra= argument
    if ($opt_extra) {
        $source{'[extra]'} = $opt_extra;
    } else {
        foreach my $lang (keys %lang_code) {
            my $file = "$ENV{'LJHOME'}/bin/upgrading/${lang}.dat";
            next unless -e $file;
            $source{$lang} = $file;            
        }
    }
    foreach my $source (keys %source)
    {
        $out->("$source", '+');
        my $file = $source{$source};
        open (D, $file)
            or $out->('x', "Can't open $source data file");

        # fixed language in *.dat files, but in extra files
        # it switches as it goes.
        my $l;
        if ($source ne "[extra]") { $l = $lang_code{$source}; }

        my $bml_prefix = "";

        my $addcount = 0;
        my $lnum = 0;
        my ($code, $text);
        my %metadata;
        while (my $line = <D>) {
            $lnum++;
            if ($line =~ /^==(LANG|BML):\s*(\S+)/) {
                $out->('x', "Bogus directives in non-extra file.")
                    if $source ne "[extra]";
                my ($what, $val) = ($1, $2);
                if ($what eq "LANG") {
                    $l = $lang_code{$val};
                    $out->('x', 'Bogus ==LANG switch to: $what') unless $l;
                    $bml_prefix = "";
                } elsif ($what eq "BML") {
                    $out->('x', 'Bogus ==BML switch to: $what') 
                        unless $val =~ m!^/.+\.bml$!;
                    $bml_prefix = $val;
                }
            } elsif ($line =~ /^(\S+?)=(.*)/) {
                ($code, $text) = ($1, $2);
            } elsif ($line =~ /^(\S+?)\<\<\s*$/) {
                ($code, $text) = ($1, "");
                while (<D>) {
                    last if $_ eq ".\n";
                    s/^\.//;
                    $text .= $_;
                }
                chomp $text;  # remove file new-line (we added it)
            } elsif ($line =~ /^[\#\;]/) {
                # comment line
                next;
            } elsif ($line =~ /\S/) {
                $out->('x', "$source:$lnum: Bogus format.");
            }

            if ($code =~ m!^\.!) {
                $out->('x', "Can't use code with leading dot: $code")
                    unless $bml_prefix;
                $code = "$bml_prefix$code";
            }

            if ($code =~ /\|(.+)/) {
                $metadata{$1} = $text;
                next;
            }

            next unless $code ne "";

            $out->('x', 'No language defined!') unless $l;


            my $qcode = $dbh->quote($code);
            my $exists = $dbh->selectrow_array("SELECT COUNT(*) FROM ml_latest l, ml_items i ".
                                               "WHERE l.dmid=1 AND i.dmid AND i.itcode=$qcode AND ".
                                               "i.itid=l.itid AND l.lnid=$l->{'lnid'}");
            if (! $exists) {
                $addcount++;
                my $staleness = $metadata{'staleness'}+0;
                my $res = LJ::Lang::set_text($dbh, 1, $l->{'lncode'}, $code, $text,
                                             { 'staleness' => $staleness,
                                               'notes' => $metadata{'notes'}, });
                unless ($res) {
                    $out->('x', "ERROR: " . LJ::Lang::last_error());
                }
            }
            %metadata = ();
        }
        close D;
        $out->("added: $addcount", '-');
    }
    $out->("-", "done.");
}

sub dumptext
{
    $out->('Dumping text...', '+');
    foreach my $lang (keys %lang_code)
    {
        $out->("$lang");
        my $l = $lang_code{$lang};
        open (D, ">$ENV{'LJHOME'}/bin/upgrading/${lang}.dat")
            or $out->('x', "Can't open $lang.dat");
        print D ";; -*- coding: utf-8 -*-\n";
        my $sth = $dbh->prepare("SELECT i.itcode, t.text, l.staleness, i.notes FROM ".
                                "ml_items i, ml_latest l, ml_text t ".
                                "WHERE l.lnid=$l->{'lnid'} AND l.dmid=1 ".
                                "AND i.dmid=1 AND l.itid=i.itid AND ".
                                "t.dmid=1 AND t.txtid=l.txtid AND ".
                                # only export mappings that aren't inherited:
                                "t.lnid=$l->{'lnid'} ".
                                "ORDER BY i.itcode");
        $sth->execute;
        die $dbh->errstr if $dbh->err;
        my $writeline = sub {
            my ($k, $v) = @_;
            if ($v =~ /\n/) {
                $v =~ s/\n\./\n\.\./g;
                print D "$k<<\n$v\n.\n";
            } else {
                print D "$k=$v\n";
            }
        };
        while (my ($itcode, $text, $staleness, $notes) = $sth->fetchrow_array) {
            $writeline->("$itcode|staleness", $staleness)
                if $staleness;
            $writeline->("$itcode|notes", $notes)
                if $notes =~ /\S/;
            $writeline->($itcode, $text);
            print D "\n";
        }
        close D;
    }
    $out->('-', 'done.');
}

sub newitems
{
    $out->("Searching for referenced text codes...", '+');
    my $top = $ENV{'LJHOME'};
    my @files;
    push @files, qw(htdocs cgi-bin bin);
    my %items;  # $scope -> $key -> 1;
    while (@files)
    {
        my $file = shift @files;
        my $ffile = "$top/$file";
        next unless -e $ffile;
        if (-d $ffile) {
            $out->("dir: $file");
            opendir (MD, $ffile) or die "Can't open $file";
            while (my $f = readdir(MD)) {
                next if $f eq "." || $f eq ".." || 
                    $f =~ /^\.\#/ || $f =~ /(\.png|\.gif|~|\#)$/;
                unshift @files, "$file/$f";
            }
            closedir MD;
        }
        if (-f $ffile) {
            my $scope = "local";
            $scope = "general" if -e "$top/cvs/livejournal/$file";

            open (F, $ffile) or die "Can't open $file";
            my $line = 0;
            while (<F>) {
                $line++;
                while (/BML::ml\([\"\'](.+?)[\"\']/g) {
                    $items{$scope}->{$1} = 1;
                }
                while (/\(=_ML\s+(.+?)\s+_ML=\)/g) {
                    my $code = $1;
                    if ($code =~ /^\./ && $file =~ m!^htdocs/!) {
                        $code = "$file$code";
                        $code =~ s!^htdocs!!;
                    }
                    $items{$scope}->{$code} = 1;
                }
            }
            close F;
        }
    }

    $out->(sprintf("%d general and %d local found.",
                   scalar keys %{$items{'general'}},
                   scalar keys %{$items{'local'}}));

    # [ General ]
    my %e_general;  # code -> 1
    $out->("Checking which general items already exist in database...");
    my $sth = $dbh->prepare("SELECT i.itcode FROM ml_items i, ml_latest l WHERE ".
                            "l.dmid=1 AND l.lnid=1 AND i.dmid=1 AND i.itid=l.itid ");
    $sth->execute;
    while (my $it = $sth->fetchrow_array) { $e_general{$it} = 1; }
    $out->(sprintf("%d found", scalar keys %e_general));
    foreach my $it (keys %{$items{'general'}}) {
        next if exists $e_general{$it};
        my $res = LJ::Lang::set_text($dbh, 1, "en", $it, undef, { 'staleness' => 4 });
        $out->("Adding general: $it ... $res");
    }

    if ($opt_local_lang) {
        my $ll = $lang_code{$opt_local_lang};
        die "Bogus --local-lang argument\n" unless $ll;
        die "Local-lang '$ll->{'lncode'}' parent isn't 'en'\n"
            unless $ll->{'parentlnid'} == 1;
        $out->("Checking which local items already exist in database...");

        my %e_local;
        $sth = $dbh->prepare("SELECT i.itcode FROM ml_items i, ml_latest l WHERE ".
                             "l.dmid=1 AND l.lnid=$ll->{'lnid'} AND i.dmid=1 AND i.itid=l.itid ");
        $sth->execute;
        while (my $it = $sth->fetchrow_array) { $e_local{$it} = 1; }
        $out->(sprintf("%d found\n", scalar keys %e_local));
        foreach my $it (keys %{$items{'local'}}) {
            next if exists $e_general{$it};
            next if exists $e_local{$it};
            my $res = LJ::Lang::set_text($dbh, 1, $ll->{'lncode'}, $it, undef, { 'staleness' => 4 });
            $out->("Adding local: $it ... $res");
        }
    }
    $out->('-', 'done.');
}
