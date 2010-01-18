package LJ::Request::Apache2;
use strict;

use constant MP2 => (exists $ENV{MOD_PERL_API_VERSION} &&
                     $ENV{MOD_PERL_API_VERSION} == 2) ? 1 : 0;

BEGIN {
    if (MP2){
        require Apache2::Const;
        import Apache2::Const qw/REDIRECT/;
        *OK        = \&Apache2::Const::OK;
        *REDIRECT  = \&REDIRECT;
        *DONE      = \&Apache2::Const::DONE;
        *NOT_FOUND = \&Apache2::Const::NOT_FOUND;
    } else {
        require Apache::Constants;
        *OK        = \&Apache::Constants::OK;
        *REDIRECT  = \&Apache::Constants::REDIRECT;
        *DONE      = \&Apache::Constants::DONE;
        *NOT_FOUND = \&Apache::Constants::NOT_FOUND;
    }
}

BEGIN {
    if (MP2){
        require Apache2::Request;
        require Apache2::RequestUtil;
        require Apache2::RequestRec;
    } else {
        require Apache::Request;
        require Apache::URI;
    }
}

my $instance = '';

sub new {
    my $class = shift;
    my $apr   = shift;
    
    $instance ||= bless {}, $class;
    $instance->{apr} = MP2
                      ? Apache2::Request->new($apr)
                      : Apache::Request->new($apr,
                                             DISABLE_UPLOADS => 1
                                            );
    $instance->{r} = $apr;
    return $instance;
}

sub content {
}

sub args {
    my $self = shift;
    $self->{apr}->args;
}

sub method {
    my $self = shift;
    $self->{apr}->method;
}

sub document_root {
    my $self = shift;
    if (MP2) {
        ;
    } else {
        $self->{apr}->document_root;
    }
}

sub finfo {
    my $self = shift;
    if (MP2) {
        require APR::Finfo;
        stat $self->{apr}->filename;
        \*_;
    } else {
        $self->{apr}->finfo;
    }
}

sub filename {
    my $self = shift;
    $self->{apr}->filename;
}

sub httpd_conf {
    my $class = shift;
    unless (MP2) {
        Apache->httpd_conf(@_);
    } else {
####    Apache2::ServerUtil->server->add_config( [ split /\n/, $text ] );
        Apache2::ServerUtil->server->add_config(@_);
    }
}

sub is_initial_req {
    my $self = shift;
    $self->{apr}->is_initial_req(@_);
}

sub push_handlers {
    my $self = shift;
    if (MP2) {
        Apache2::ServerUtil->push_handlers(@_);
    } else {
        Apache->push_handlers(@_);
    }
}

sub set_handlers {
    my $self = shift;
    $self->{apr}->set_handlers(@_);
}

sub free {
    my $class = shift;
    $instance = undef;
}

sub instance {
    my $class = shift;
    return $instance ? $instance : undef;
}

sub notes {
    my $self = shift;
    $self->{apr}->pnotes (@_);
}

sub pnotes {
    my $self = shift;
    $self->{apr}->pnotes (@_);
}

sub parse {
    my $self = shift;
    $self->{apr}->parse (@_);
}

sub uri {
    my $self = shift;
    $self->{apr}->uri (@_);
}

sub hostname {
    my $self = shift;
    $self->{apr}->hostname (@_);
}

sub header_out {
    my $self = shift;
    if (MP2) {
        $self->{apr}->headers_out->add (@_);
    } else {
        $self->{apr}->header_out (@_);
    }
}

sub headers_out {
    my $self = shift;
    $self->{apr}->headers_out (@_);
}

sub header_in {
    my $self = shift;
    if (MP2) {
        my $header = shift;
        $self->{apr}->headers_in->{$header} || '';
    } else {
        $self->{apr}->header_in (@_);
    }
}

sub headers_in {
    my $self = shift;
    $self->{apr}->headers_in (@_);
}

sub param {
    my $self = shift;
    $self->{apr}->param (@_);
}

sub no_cache {
    my $self = shift;
    $self->{apr}->no_cache (@_);
}

sub content_type {
    my $self = shift;
    $self->{apr}->content_type (@_);
}

sub pool {
    my $self = shift;
    $self->{apr}->pool;
}

sub connection {
    my $self = shift;
    $self->{apr}->connection;
}

sub output_filters {
    my $self = shift;
    $self->{apr}->output_filters;
}

sub print {
    my $self = shift;
    $self->{r}->print (@_);
}

sub dir_config {
    my $self = shift;
    $self->{r}->dir_config (@_);
}

sub send_http_header {
    my $self = shift;
    $self->{apr}->send_http_header (@_)
        unless MP2;

}

1;

