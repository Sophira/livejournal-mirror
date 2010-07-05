package LJ::Identity;
use strict;

use Carp qw();

# initialization code. do not touch this.
my @CLASSES = LJ::ModuleLoader->module_subclasses('LJ::Identity');
foreach my $class (@CLASSES) {
    eval "use $class";
    Carp::confess "Error loading event module '$class': $@" if $@;
}

my %TYPEMAP = map { $_->typeid => $_ } @CLASSES;

# initialization code ends

sub new {
    my ($class, %opts) = @_;

    return bless {
        'value' => $opts{'value'},
    }, $TYPEMAP{$opts{'typeid'}};
}

sub pretty_type { Carp::confess 'Invalid identity type' }
sub typeid { Carp::confess 'Invalid identity type' }
sub url { Carp::confess 'Invalid identity type' }
sub short_code { 'unknown' }

sub value {
    my ($self) = @_;
    return $self->{'value'};
}

1;
