#!/usr/bin/perl
#
# <LJDEP>
# lib: Proc::ProcessTable, cgi-bin/ljlib.pl
# </LJDEP>

use strict;
use Getopt::Long
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

my $opt_foreground;
my $opt_debug;
my $opt_stop;
exit 1 unless GetOptions('foreground' => \$opt_foreground,
                         'debug' => \$opt_debug,
                         'stop' => \$opt_stop,
                         );

BEGIN {
    $LJ::OPTMOD_PROCTABLE = eval "use Proc::ProcessTable; 1;";
}

my $DELAY = $LJ::QBUFFERD_DELAY || 15;

my $pidfile = $LJ::QBUFFERD_PIDFILE || "$ENV{'LJHOME'}/var/qbufferd.pid";
my $pid;
if (-e $pidfile) {
    open (PID, $pidfile);
    chomp ($pid = <PID>);
    close PID;
    if ($opt_stop) {
        if (kill 15, $pid) {
            print "Shutting down qbufferd.\n";
        } else {
            print "qbufferd not running?\n";
        }
        exit;
    }

    if ($LJ::OPTMOD_PROCTABLE) {
        my $processes = Proc::ProcessTable->new()->table;
        if (grep { $_->cmndline =~ /perl.+qbufferd/ && $_->pid != $$ } @$processes) {
            exit;
        }
    } else {
        if (kill 0, $pid) {
            # seems to still be running (at least something is with that pid)
            exit;
        }
    }
}
if ($opt_stop) {
    print "qbufferd not running?\n";
    exit;
}

$SIG{'INT'} = \&stop_qbufferd;
$SIG{'TERM'} = \&stop_qbufferd;
$SIG{'HUP'} = sub { 
    # nothing.  maybe later make a HUP force a flush?
};

if (!$opt_foreground && ($pid = fork)) 
{
    unless (open (PID, ">$pidfile")) {
        kill 15, $pid;
        die "Couldn't write PID file.  Exiting.\n";
    }
    print PID $pid, "\n";
    close PID;
    print "qbufferd started with pid $pid\n";
    if (-s $pidfile) { print "pid file written ($pidfile)\n"; }
    exit;
} 

# fork off a separate qbufferd process for all specified
# job types in @LJ::QBUFFERD_ISOLATE, and then
# another process for all other job types. The current process
# will keep tabs on all of those

my %isolated;
my %pids;         # job -> pid
my %jobs;         # pid -> job
my $working = 0;  # 1 for processes that do actual work 

my $my_job;

foreach my $job (@LJ::QBUFFERD_ISOLATE) {
    $isolated{$job} = 1;
}

foreach my $job (@LJ::QBUFFERD_ISOLATE, "_others_") {
    if (my $child = fork) { 
        # parent.
        $pids{$job} = $child;
        $jobs{$child} = $job;
        next;
    } else {
        # child.
        $my_job = $job;
        $working = 1;
        last;  
    }
}

# at this point, $my_job is either the specialized 'cmd' to run, or
# '_others_' to mean everything besides stuff with their own processes.
# $working is 1 for nonempty values of $my_job .

sub stop_qbufferd
{
    # stop children
    unless ($working) {
        foreach my $job (keys %pids) {
            my $child = $pids{$job};
            print "Killing child pid $child job: $job\n" if $opt_debug;
            kill 15, $child;
        }

        unlink $pidfile;
    }

    print "Quitting: " . ($working ? "job $my_job" : "parent") . "\n" if $opt_debug;
    exit;
}


while(not $working) {
    # controlling process's cycle
    my $pid;

    $pid = wait();

    print "Child exited, pid $pid, job $jobs{$pid}\n" if $opt_debug;
    if ($jobs{$pid}) {
        my $job = $jobs{$pid};
        print "Restarting job $job\n" if $opt_debug;
        delete $pids{$job};
        delete $jobs{$pid};
        if (my $child = fork) {
            # parent.
            $pids{$job} = $child;
            $jobs{$child} = $job;
        } else {
            # child.
            $my_job = $job;
            $working = 1; # go work
        }
    }
}

# the actual work begins here
my @all_jobs = qw(delitem weblogscom);
foreach my $hook (keys %LJ::HOOKS) {
    next unless $hook =~ /^cmdbuf:(\w+):run$/;
    push @all_jobs, $1;
}
        
while (LJ::start_request())
{
    my $cycle_start = time();
    print "Starting cycle. Job $my_job\n" if $opt_debug;

    # syndication (checks RSS that need to be checked)
    if ($my_job eq "synsuck") {
        system("$ENV{'LJHOME'}/bin/ljmaint.pl", "-v0", "synsuck");
        print "Sleeping. Job $my_job\n" if $opt_debug;
        my $elapsed = time() - $cycle_start;
        sleep ($DELAY-$elapsed) if $elapsed < $DELAY;
        next;
    }

    # do main cluster updates
    my $dbh = LJ::get_dbh("master");
    unless ($dbh) {
        sleep 10;
        next;
    }
    
    # keep track of what commands we've run the start hook for
    my %started;

    # handle clusters
    foreach my $c (@LJ::CLUSTERS) {
        print "Cluster: $c Job: $my_job\n" if $opt_debug;
        my $db = LJ::get_cluster_master($c);
        next unless $db;

        my @check_jobs = ($my_job);
        if ($my_job eq "_others_") { @check_jobs = grep { ! $isolated{$_} } @all_jobs; }

        foreach my $cmd (@check_jobs) {
            my $have_jobs = $db->selectrow_array("SELECT cbid FROM cmdbuffer WHERE cmd=? LIMIT 1",
                                                 undef, $cmd);
            next unless $have_jobs;

            print "  Starting $cmd...\n" if $opt_debug;
            unless ($started{$cmd}++) {
                LJ::cmd_buffer_flush($dbh, $db, "$cmd:start");
            }
            LJ::cmd_buffer_flush($dbh, $db, $cmd);
            print "  Finished $cmd.\n" if $opt_debug;
        }
    }

    # run the end hook for all commands we've run
    foreach my $cmd (keys %started) {
        LJ::cmd_buffer_flush($dbh, undef, "$cmd:finish");
    }
    

    print "Sleeping. Job $my_job\n" if $opt_debug;
    my $elapsed = time() - $cycle_start;
    sleep ($DELAY-$elapsed) if $elapsed < $DELAY;
};
