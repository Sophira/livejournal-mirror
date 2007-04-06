#!/usr/bin/perl

package FB::Protocol::Response;

use strict;

BEGIN {
    use fields qw(req vars u methods);
    use vars qw(%VALID_METHODS %ERR_MAP);

    use Carp;
    use XML::Simple ();

    # methods
    %VALID_METHODS = map { $_ => 1 } qw(
                                        CreateGals
                                        GetChallenge
                                        GetChallenges
                                        GetGals
                                        GetGalsTree
                                        GetPics
                                        GetSecGroups
                                        Login
                                        UploadPrepare
                                        UploadTempFile
                                        UploadPic
                                        );

    %ERR_MAP = (
                # User Errors (1xx)
                100 => "User error",
                101 => "No user specified",
                102 => "Invalid user",
                103 => "Unknown user",

                # Client Errors (2xx)
                200 => "Client error",
                201 => "Invalid request",
                202 => "Invalid mode",
                203 => "GetChallenge(s) is exclusive as primary mode",

                210 => "Unknown argument",
                211 => "Invalid argument",
                212 => "Missing required argument",
                213 => "Invalid image for upload",

                # Access Errors (3xx)
                300 => "Access error",
                301 => "No auth specified",
                302 => "Invalid auth",
                303 => "Account status does not allow upload",

                # Limit errors (4xx)
                400 => "Limit error",
                401 => "No disk space remaining",
                402 => "Insufficient disk space remaining",
                403 => "File upload limit exceeded",

                # Server Errors (5xx)
                500 => "Internal Server Error",
                501 => "Cannot connect to database",
                502 => "Database Error",
                503 => "Application Error",

                510 => "Error creating gpic",
                511 => "Error creating upic",
                512 => "Error creating gallery",
                513 => "Error adding to gallery",
                );

}

################################################################################
# Constructors
#

sub new {
    my FB::Protocol::Response $self = shift;

    $self = fields::new($self)
        unless ref $self;

    $self->{req}     = undef;
    $self->{vars}    = {};
    $self->{u}       = undef;
    $self->{methods} = [];

    my %args = @_;
    while (my ($field, $val) = each %args) {
        $self->{$field} = $val;
    }

    # validate self
    return _err("Constructor requires 'req' (FB::Protocol::Request) argument")
        unless $self->{req};
    return _err("'req' argument is not a valid FB::Protocol::Request object")
        unless ref $self->{req} eq 'FB::Protocol::Request';

    return $self;
}

sub _err {
    $@ = $_[0] if $_[0];
    return undef;
}

sub run_methods {
    my FB::Protocol::Response $self = shift;

    my $r    = $self->{req}->{r};
    my $vars = $self->{req}->{vars};

    # valid primary mode?
    if (exists $vars->{Mode} && ! $VALID_METHODS{$vars->{Mode}}) {
        $self->add_error(202 => $vars->{Mode});
        return undef;
    }

    # see what methods are active on this request
    $self->{methods} = [];
    {
        my %done = ();
        push @{$self->{methods}}, grep { $VALID_METHODS{$_} && ! $done{$_}++ } $vars->{Mode}, keys %$vars;
    }

    # check that a valid user was specified
    $self->validate_user or return undef;

    # special case:  if 'GetChallenge'/'GetChallenges' is the 
    # primary mode, then it's the only allowed mode since there 
    # is no required authentication
    if ($vars->{Mode} eq 'GetChallenge' || $vars->{Mode} eq 'GetChallenges') {

        # if other methods are present in this request, error
        if (grep { $_ ne $vars->{Mode} } @{$self->{methods}}) {
            $self->add_error(203);
            return undef;
        }

        # no error, run method and get a challenge
        $self->run_method($vars->{Mode});
        return 1;
    }

    # validate authentication for this request
    $self->validate_auth or return undef;

    # run individual methods
    $self->run_method($_) foreach @{$self->{methods}};

    return 1;
}

sub run_method {
    my FB::Protocol::Response $self = shift;
    my $meth = shift;

    # valid method?
    return undef unless $VALID_METHODS{$meth};

    # module available?
    eval "use FB::Protocol::$meth";
    if ($@) {
        $self->add_error(500 => [$_ => $@]);
        return undef;
    }

    # need strict refs off for the remainder of this scope
    no strict 'refs';
    return "FB::Protocol::${meth}::handler"->($self);
}

sub get_xml {
    my FB::Protocol::Response $self = shift;
    my $vars = shift;

    my $rv;
    eval { $rv = XML::Simple::XMLout
               ( $vars || $self->{vars},
                 RootName      => 'FBResponse',
                 SuppressEmpty => 1,
                         
                 # do pretty printing on dev servers
                 NoIndent      => ! $FB::IS_DEV_SERVER,
               ) 
         };

    return $@ ? undef : $rv;
}

sub get_vars {
    my FB::Protocol::Response $self = shift;

    return $self->{vars};
}

sub error_msg {
    my FB::Protocol::Response $self = shift;
    my ($err, $extra) = @_;

    my $errmsg = $ERR_MAP{$err};
    if ($extra) {
        $errmsg .= ": " if $errmsg;
        $errmsg .= ref $extra eq 'ARRAY' ? join(': ', grep { $_ ne '' } @$extra) : $extra;
    }

    return FB::exml($errmsg);
}

sub add_error {
    my FB::Protocol::Response $self = shift;
    my ($err, $extra) = @_;

    my $errmsg = $self->error_msg(@_);

    push @{$self->{vars}->{Error}}, {
        code    => $err, 
        content => $errmsg,
    };

    return 1;
}

sub add_method_vars {
    my FB::Protocol::Response $self = shift;
    my ($meth, $vars) = @_;

    while (my ($key, $val) = each %$vars) {
        $self->{vars}->{"${meth}Response"}->{$key} = $val;
    }

    return 1;
}

sub add_method_error {
    my FB::Protocol::Response $self = shift;
    my ($meth, $err, $extra) = @_;

    my $errmsg = $self->error_msg($err, $extra);
    
    push (@{$self->{vars}->{"${meth}Response"}->{Error}}, {
        code    => $err,
        content => $errmsg,
    });

    return 1;
}

sub validate_user {
    my FB::Protocol::Response $self = shift;
    my $vars = $self->{req}->{vars};

    # validate username given?
    unless (exists $vars->{User}) {
        $self->add_error(101);
        return undef;
    }

    my $user = FB::canonical_username($vars->{User});
    unless ($user) {
        $self->add_error(102);
        return undef;
    }

    # valid user?
    my $dmid = FB::current_domain_id();
    my $u = FB::load_user($user, $dmid, { create => 1, validate => 1 });
    if (! $u || $u->{statusvis} =~ /[DX]/) {
        $self->add_error(103);
        return undef;
    }
    $self->{u} = $u;

    return 1;
}

sub validate_auth {
    my FB::Protocol::Response $self = shift;
    my $vars = $self->{req}->{vars};

    # was user already validated?
    return undef unless $self->{u};

    my $err = sub {
        $self->add_error(@_);
        return undef;
    };

    # auth given?
    return $err->(301) unless exists $vars->{Auth};

    # valid auth?
    return $err->(302)
        unless $vars->{Auth} =~ /^crp:/ && FB::check_auth($self->{u}, $vars->{Auth});

    return 1;
}

1;
