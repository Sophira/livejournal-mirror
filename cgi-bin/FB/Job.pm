#!/usr/bin/perl

use strict;
use lib "$ENV{FBHOME}/lib";

package FB::Job;

use Carp qw(croak);
use Storable qw(nfreeze thaw);
use Gearman::Client;

use vars qw($CLIENT);

sub do {
    my $class = shift;
    croak "'do' is a class method"
        unless $class eq 'FB::Job';

    my $opts = ref $_[0] ? shift() : {};
    my %arg = @_;

    my $job_name = $arg{job_name};   # name of the job to be dispatched
    my $arg_ref  = $arg{arg_ref};    # ref of arguments to pass to job
    my $task_ref = $arg{task_ref};   # subref which performs job given arguments
    my $do_in_bg = $arg{background}; # dispatch in background?
    croak "invalid arguments"
        unless length($job_name) && ref $arg_ref && ref $task_ref;

    # now there are 3 courses of action for this call
    #  1 - no gearman, perform the action directly
    #  2 - gearman calling, act like a gearman worker
    #  3 - gearman enabled, dispatch a job

    # ignore gearman and do the job directly
    if (! @FB::GEARMAN_SERVERS || $FB::GEARMAN_DISABLED{$job_name}) {
        return $task_ref->($arg_ref);
    }

    # gearman is using us as a worker
    if ($opts->{is_gearman}) {
        return $task_ref->($arg_ref);
    }

    # register a new gearman job
    my $arg_stor = Storable::nfreeze($arg_ref)
        or croak "unable to nfreeze passed args";

    # instantiate a Gearman client
    my $client = $FB::Job::CLIENT ||=
        Gearman::Client->new
        ( job_servers => \@FB::GEARMAN_SERVERS )
        or croak "unable to construct Gearman::Worker object";

    # return the result reference to the calling worker
    if (!$do_in_bg) {
        return $client->do_task
            ($job_name, $arg_stor)
            or croak "unable to complete task: $job_name";
    } else {
        return $client->dispatch_background
            ($job_name, $arg_stor)
            or croak "unable to dispatch task: $job_name";
     }
}

# accepts same arguments as do(), except $args{arg_ref}
# must be a scalar ref to a storable object in memory,
# presumably frozen by do() during a gearman dispatch call
sub do_as_gearman {
    my $class = shift;
    croak "'do_as_gearman' is a class method"
        unless $class eq 'FB::Job';

    my %args = @_;

    # args will be a storable object, convert them back now
    # - ($gpicid, $width, $height, $opts)
    $args{arg_ref} = Storable::thaw(${$args{arg_ref}});

    return $class->do({ is_gearman => 1 }, %args);
}

# same as above but dispatch in background
sub do_as_gearman_in_background {
    my $class = shift;
    croak "'do_as_gearman' is a class method"
        unless $class eq 'FB::Job';

    my %args = @_;

    # args will be a storable object, convert them back now
    # - ($gpicid, $width, $height, $opts)
    $args{arg_ref} = Storable::thaw(${$args{arg_ref}});

    return $class->do({ is_gearman => 1, background => 1 }, %args);
}

1;


__END__

=head1 NAME

FB::Job - FotoBilder wrapper for the Gearman job system

=head1 SYNOPSIS

use FB::Job;

    # From application API:
    FB::Job->do
    ( job_name => 'myname',
      arg_ref  => \%arguments, # (or \@, \$, etc)
      task_ref => sub { ... },
    );

    # From Gearman worker script:
    FB::Job->do_as_gearman 
    ( job_name => 'myname',
      arg_ref  => \%arguments,
      task_ref => sub { ... },
    );

=head1 DESCRIPTION

I<FB::Job> is a wrapper to simplify the writing of application-level APIs
which need to function either through Gearman or directly through the
application, depending on configuration status.

Callers pass a Gearman job name, argument reference, and a reference to 
a function which implements the desired behavior.  Upon calling FB::Job->do,
Gearman setup status will be checked to determine what should be done.  If
@FB::GEARMAN_SERVERS is populated then a new job will be dispatched to 
gearmand for a worker to process.  Otherwise, the passed handler function
will be executed directly.

=head1 USAGE

=head2 FB::Job->do(%options)

Processes a specified job using Gearman or directly in the current process.

=head2 FB::Job->do_as_gearman(%options)

Processes a specified job directly in the current process.  This API is 
intended to be called from a Gearman::Worker object and is meant to 
override Gearman-dispatch functionality so that the specified handler
function is run directly.

=head2 %options accepts the following keys

=over 4

=item job_name

The name of the job to be processed.  In the Gearman case, this must 
coincide with the job name that the worker process registers with 
gearmand.  In a non-Gearman situation it is ignored.

=item arg_ref

A reference to the args which should be passed to the handler function.
In the Gearman case, this reference is frozen using Storable and later
automatically thawed when do_as_gearman is called.  In the non-Gearman
case this argument is complete opaque.

Since it is possible that this will be serialized, sent over the network,
and processed at some time in the future, these arguments should be as
small and simple as possible.  Contents such as tied filehandles and 
complex objects not only increase memory used by Gearmand, but they might
not work at all.  

=item task_ref

A reference to the handler function for this job.  It is either executed
by the current process directly or by a Gearman worker process.  The
function must accept arg_ref (defined above) as its argument and return 
a reference suitable for Storable serialization.  Once again, no special
filehandles, etc.

=head1 EXAMPLES

=head2 Handler Function

sub _somejob_do {
    my $arg_ref = shift;

    # do work with $arg_ref
    my $results = "";

    return \$results;
}

=head2 Gearman::Worker Definition

$worker->register_function('somejob' => sub {
    my $job = shift;

    return FB::Job->do_as_gearman
        ( job_name => 'somejob',
          arg_ref  => $job->{argref},
          task_ref => \&_somejob_do,
          );
});

=head2 Application Caller

sub somejob {
    my $self = shift;
    my %args = @_;

    my $result_ref = FB::Job->do
        ( job_name => 'somejob',
          arg_ref  => \%args,
          task_ref => \&_somejob_do,
          );
    
    # res_ref should be a scalar ref now
    return ref $result_ref ? $$result_ref : undef;
}

=head1 Author

Brad Whitaker <whitaker@danga.com>
