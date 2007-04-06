#!/usr/bin/perl

# Importing Library
#
# Mischa Spiegelmock <mischa@sixapart.com>
#

package FB::Importer;

use lib "$ENV{FBHOME}/lib";
use Gearman::Client;
use Gearman::Task;
use Storable qw(nfreeze thaw);

use strict;

use fields qw (url u job recurse importedurls);

# args: u => u/userid, [url => url to import], [recurse]
sub new {
    my $self = shift;

    $self = fields::new($self)
        unless ref $self;

    my %opts = @_;

    my $u = delete $opts{u};
    return undef unless $u;
    my $url = delete $opts{'url'};
    my $recurse = delete $opts{'recurse'};
    my $importedurls = delete $opts{'importedurls'};

    $self->{url} = $url;
    $self->{u} = ref $u ? $u : FB::load_userid($u);
    $self->{job} = undef;
    $self->{recurse} = $recurse || 0;
    $self->{importedurls} = $importedurls || [];

    return $self;
}

# takes a task name as argument
# returns scalar
sub _start_import {
    my $self = shift;
    my $import_func = shift;

    if (@FB::GEARMAN_SERVERS && !$FB::GEARMAN_DISABLED{'importing'}) {
        my $client = Gearman::Client->new;
        $client->job_servers(@FB::GEARMAN_SERVERS);
        return $client->dispatch_background($import_func, nfreeze([
                                                                   $self->{url},
                                                                   $self->{u}->{userid},
                                                                   $self->{recurse},
                                                                   $self->{importedurls},
                                                                   ]), {});
    } else {
        return $self->_do_import();
    }
}

sub _set_status {
    my ($self, $nu, $dn) = @_;

    return unless ($self->{job});
    $self->{job}->set_status($nu, $dn);
}

1;
