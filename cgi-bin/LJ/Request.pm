package LJ::Request;
use strict;

use constant MP2 => (exists $ENV{MOD_PERL_API_VERSION} &&
                     $ENV{MOD_PERL_API_VERSION} == 2) ? 1 : 0;

#my $driver; # do not assign any value
#use vars qw/$driver/;
BEGIN {
    if (MP2){
        require LJ::Request::Apache2;
#        $driver = 'LJ::Request::Apache2';
#        import Apache2::Const qw/REDIRECT/;
#        *OK        = \&Apache2::Const::OK;
#        *REDIRECT  = \&REDIRECT;
#        *DONE      = \&Apache2::Const::DONE;
#        *NOT_FOUND = \&Apache2::Const::NOT_FOUND;
    } else {
        require LJ::Request::Apache;
#        $driver = 'LJ::Request::Apache';
#        *OK        = \&Apache::Constants::OK;
#        *REDIRECT  = \&Apache::Constants::REDIRECT;
#        *DONE      = \&Apache::Constants::DONE;
#        *NOT_FOUND = \&Apache::Constants::NOT_FOUND;
    }
}

#my $instance = '';
=head
sub new {
    my $class = shift;
    my $apr   = shift;
    
    $instance ||= bless {}, $class;
    $instance->{apr} = $driver->new($apr);
                    #MP2
                    #  ? LJ::Request::Apache2->new($apr)
                    #  : LJ::Request::Apache->new($apr,
                    #                         DISABLE_UPLOADS => 1
                    #                        );
    $instance->{r} = $apr;
    return $instance;
}
=cut




1;

