#!/usr/bin/perl

# This script parses LJ function info from all the library files 
# that make up the site.  See cgi-bin/ljlib.pl for an example
# of the necessary syntax.

use strict;
use Getopt::Long;
use Data::Dumper;

my $opt_warn = 0;
my $opt_file;
my $opt_stubs = 0;  # generate stubs of undoced funcs
my $opt_class = 0;  # group by class
my ($opt_include, $opt_exclude);  # which packages to inc/excl
die unless GetOptions(
                      'warn' => \$opt_warn,
                      'file=s' => \$opt_file,
                      'stubs' => \$opt_stubs,
                      'class' => \$opt_class,
                      'include=s' => \$opt_include,
                      'exclude=s' => \$opt_exclude,                      
           );

die "Unknown arguments.\n" if @ARGV;
die "Can't exclude and include at same time!\n" if $opt_include && $opt_exclude;

unless (-d $ENV{'LJHOME'}) {
    die "\$LJHOME not set.\n";
}

my @classes = qw(general api db logging time component s1);
my %classname = 
    (
     'general' => "General",
     'db' => "Database",
     'component' => "Components",
     'logging' => "Logging",
     'time' => "Date & Time",
     'text' => "Text Processing",
     'security' => "Security",
     'web' => "Web Programming",
     's1' => "Style System v1",
     );

my %common_args = 
    (
     'dbarg' => 'A master database handle ($dbh) or a master/slave set of database handles ($dbs) as generated by [func[LJ::get_dbs]].',
     'dbs' => 'A master/slave database pair, as generated by [func[LJ::get_dbs]].',
     'hookname' => 'Name of hook. See doc/hooks.txt.',
     'u' => 'A hashref of a row from the user table, sometimes called a "user object".  Although only initially a row from the user table, gets a lot of tacked onto it from various other LJ API functions.',
     'remote' => 'Hashref of remote user containing \'user\' and \'userid\' keys if obtained from [func[LJ::get_remote]] or just \'user\' if untrusted and obtained from [func[LJ::get_remote_noauth]].',
     'dbcm' => 'Cluster master database handle',
     'dbh' => 'Master database handle.',
     );

my %funcs;
if ($opt_file) {
    check_file($opt_file);
} else {
    chdir $ENV{'LJHOME'} or die "Can't cd to $ENV{'LJHOME'}\n";
    find(qw(cgi-bin));
}

exit if $opt_warn;

if ($opt_class)
{
    my %by_class;
    foreach my $n (sort keys %funcs) {
        my $f = $funcs{$n};
        push @{$by_class{$f->{'class'}}}, $f;
    }
    my $ret = [];
    foreach my $cn (@classes) {
        push @$ret, [ $classname{$cn}, $by_class{$cn} ];
    }
    print Dumper($ret);
    exit;
}

print Dumper(\%funcs);
exit;

sub find
{
    my @dirs = @_;
    while (@dirs)
    {
        my $dir = shift @dirs;
        next if ($dir eq "htdocs/img");

        opendir (D, $dir);
        my @files = sort { $a cmp $b } readdir(D);
        close D;

        foreach my $f (@files) {
            next if ($f eq "." || $f eq "..");
            my $full = "$dir/$f";
            if (-d $full) { find($full); }
            elsif (-f $full) { check_file($full); }
        }
    }

}

sub check_file 
{
    $_ = shift;
    return unless (-f);
    return if (/\.(gif|jpg|png|class|jar|zip|exe)$/);
    return if (/~$/);

    my $curpackage = "";

    my $file = $_;
    my $infunc = 0;
    my $f;                # the current function info we're loading

    my $prefix;
    my $curkey;
    my $contlen;

    open (F, $file);
    while (my $l = <F>)
    {
        if ($l =~ /^package\s*(.+);/) {
            $curpackage = $1;
        }
        if ($opt_warn && $curpackage && $l =~ /^sub\s+([a-zA-Z0-9]\S+)/) {
            my $s = $1;
            my $total = $curpackage . "::" . $s;
            unless ($funcs{$total}) {
                print STDERR "Undocumented: $total\n";
                
                if ($opt_stubs) {
                    print "# <LJFUNC>\n";
                    print "# name: $total\n";
                    print "# class: \n";
                    print "# des: \n";
                    print "# info: \n";
                    print "# args: \n";
                    print "# des-: \n";
                    print "# returns: \n";
                    print "# </LJFUNC>\n";
                }
            }
        }

        print $l if $opt_stubs;
        
        if (! $infunc) {
            if ($l =~ /<LJFUNC>/) {
                $infunc = 1;
                $f = {};
            }
            next;
        }
        
        if ($l =~ /<\/LJFUNC>/) {
            $infunc = 0;
            $prefix = "";
            $curkey = "";
            $contlen = 0;
            my $include = 0;
            if ($opt_exclude) {
                $include = 1;
                $include = 0 if $f->{'name'} =~ /^$opt_exclude/;
            } elsif ($opt_include) {
                $include = 1 if $f->{'name'} =~ /^$opt_include/;
            }
            if ($f->{'name'} && $include) {
                $f->{'source'} = $file;
                $f->{'class'} ||= "general";
                unless ($classname{$f->{'class'}}) {
                    print STDERR "Unknown class: $f->{'class'} ($f->{'name'})\n";
                }
                $funcs{$f->{'name'}} = $f;
                treeify($f);
            }
            next;
        }
        
        # continuing a line from line before... must have 
        # same indenting.
        if ($prefix && $contlen) {
            my $cont = $prefix . " "x$contlen;
            if ($l =~ /^\Q$cont\E(.+)/) {
                my $v = $1;
                $v =~ s/^\s+//;
                $v =~ s/\s+$//;
                $f->{$curkey} .= " " . $v;
                next;
            }
        }
        
        if ($l =~ /^(\W*)([\w\-]+)(:\s*)(.+)/) {
            $prefix = $1;
            my $k = $2;
            my $v = $4;
            $v =~ s/^\s+//;
            $v =~ s/\s+$//;
            $f->{$k} = $v;
            $curkey = $k;
            $contlen = length($2) + length($3);
        }
    }
    close (F);

}

sub treeify
{
    my $f = shift;
    my $args = $f->{'args'};
    $f->{'args'} = [];

    $args =~ s/\s+//g;
    foreach my $arg (split(/\,/, $args))
    {
        my $opt = 0;
        if ($arg =~ s/\?$//) { $opt = 1; }
        my $list = 0;
        if ($arg =~ s/\*$//) { $list = 1; }
        my $a = { 'name' => $arg };
        if ($opt) { $a->{'optional'} = 1; }
        if ($list) { $a->{'list'} = 1; }
        $a->{'des'} = $f->{"des-$arg"} || $common_args{$arg};
        delete $f->{"des-$arg"};
        unless ($a->{'des'}) {
            if ($opt_warn) {
                print "Warning: undescribed argument '$arg' in $a->{'name'}\n";
            }
        }
        push @{$f->{'args'}}, $a;
    }
    
      
}
