package LJ::Request::Apache2;
use strict;

use Carp qw//;
use Apache2::Const qw/:methods :common :http/;
use Apache2::RequestRec;
use Apache2::RequestUtil;
use Apache2::Response;
use Apache2::RequestIO;
use Apache2::Request;
use Apache2::Upload;
use Apache2::ServerUtil;
use Apache2::Log;
use Apache2::Access;
use Apache2::Connection;
use Apache2::URI;
use ModPerl::Util;
use URI::Escape;
use APR::Finfo;


sub LJ::Request::OK                        { return Apache2::Const::OK }
sub LJ::Request::REDIRECT                  { return Apache2::Const::REDIRECT }
sub LJ::Request::DECLINED                  { return Apache2::Const::DECLINED }
sub LJ::Request::FORBIDDEN                 { return Apache2::Const::FORBIDDEN }
sub LJ::Request::NOT_FOUND                 { return Apache2::Const::NOT_FOUND }
sub LJ::Request::HTTP_NOT_MODIFIED         { return Apache2::Const::HTTP_NOT_MODIFIED }
sub LJ::Request::HTTP_MOVED_PERMANENTLY    { return Apache2::Const::HTTP_MOVED_PERMANENTLY }
sub LJ::Request::HTTP_MOVED_TEMPORARILY    { return Apache2::Const::HTTP_MOVED_TEMPORARILY }
sub LJ::Request::HTTP_METHOD_NOT_ALLOWED   { return Apache2::Const::HTTP_METHOD_NOT_ALLOWED() }
sub LJ::Request::HTTP_BAD_REQUEST          { return Apache2::Const::HTTP_BAD_REQUEST() }
sub LJ::Request::M_TRACE                   { return Apache2::Const::M_TRACE }
sub LJ::Request::M_OPTIONS                 { return Apache2::Const::M_OPTIONS }
sub LJ::Request::M_PUT                     { return Apache2::Const::M_PUT }
sub LJ::Request::M_POST                    { return Apache2::Const::M_POST() }
sub LJ::Request::SERVER_ERROR              { return Apache2::Const::SERVER_ERROR }
sub LJ::Request::BAD_REQUEST               { return Apache2::Const::HTTP_BAD_REQUEST }


sub LJ::Request::interface_name { 'Apache2' }


my $instance = '';
sub LJ::Request::request { $instance }
sub LJ::Request::r {
    Carp::confess("Request is not provided to LJ::Request") unless $instance;
    return $instance->{r};
}


sub LJ::Request::instance {
    my $class = shift;
    die "use 'request' instead";
}


sub LJ::Request::init {
    my $class = shift;
    my $r     = shift;

    # second init within a same request.
    # Request object may differ between handlers.
    if ($class->is_inited){
        # NOTE. this is not good approach. becouse we would have Apache::Request based on other $r object.
        $instance->{r} = $r;
        return $instance;
    }

    $instance = bless {}, $class;
    $instance->{apr} = Apache2::Request->new($r);
    $instance->{r} = $r;
    return $instance;
}

sub LJ::Request::is_inited {
    return $instance ? 1 : 0;
}

sub LJ::Request::update_mtime {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->update_mtime(@_);
}

sub LJ::Request::set_last_modified {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->set_last_modified(@_);
}

sub LJ::Request::request_time {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->request_time();
}

sub LJ::Request::read {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->read(@_);
}

sub LJ::Request::is_main {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return !$instance->{r}->main;
}

sub LJ::Request::main {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->main(@_);
}

sub LJ::Request::dir_config {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->dir_config(@_);
}

sub LJ::Request::header_only {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->header_only;
}

sub LJ::Request::content_languages {
    my $class = shift;
    die "Request is not provided to LJ::Request" unless $instance;
    return $instance->{r}->content_languages(@_);
}

sub LJ::Request::register_cleanup {
    my $class = shift;
    return $instance->{r}->pool->cleanup_register(@_);
}

sub LJ::Request::path_info {
    my $class = shift;
    return $instance->{r}->path_info(@_);
}

# $r->args in 2.0 returns the query string without parsing and splitting it into an array. 
sub LJ::Request::args {
    my $class = shift;
    if (wantarray()){
        my $qs = $instance->{r}->args(@_);
        my @args = 
            map { URI::Escape::uri_unescape ($_) }
            map { split /=/ => $_, 2 }
            split /[\&\;]/ => $qs;
        return @args;
    } else {
        return $instance->{r}->args(@_);
    }
}

sub LJ::Request::method {
    my $class = shift;
    $instance->{r}->method;
}

sub LJ::Request::bytes_sent {
    my $class = shift;
    $instance->{r}->bytes_sent(@_);
}

sub LJ::Request::document_root {
    my $class = shift;
    $instance->{r}->document_root;
}

sub LJ::Request::finfo {
    my $class = shift;
    $instance->{apr}->finfo;
}

sub LJ::Request::filename {
    my $class = shift;
    $instance->{r}->filename(@_);
}

sub LJ::Request::add_httpd_conf {
    my $class = shift;
    my @confs = @_;
    Apache2::ServerUtil->server->add_config(\ @confs);
}

sub LJ::Request::is_initial_req {
    my $class = shift;
    $instance->{r}->is_initial_req(@_);
}

sub LJ::Request::push_handlers_global {
    my $class = shift;
    my @handlers = map {
            my $el = $_;
            $el =~ s/PerlHandler/PerlResponseHandler/g;
            $el;
        } @_;
    Apache2::ServerUtil->server->push_handlers(@handlers);
}

sub LJ::Request::push_handlers {
    my $class = shift;
    my @handlers = map {
            my $el = $_;
            $el =~ s/PerlHandler/PerlResponseHandler/g;
            $el;
        } @_;
    return $instance->{r}->push_handlers(@handlers);
}

sub LJ::Request::set_handlers {
    my $class = shift;
    my @handlers = map {
            my $el = $_;
            $el =~ s/PerlHandler/PerlResponseHandler/g;
            $el;
        } @_;
    $instance->{r}->set_handlers(@handlers);
}

sub LJ::Request::handler {
    my $class = shift;
    $instance->{r}->handler(@_);
}

sub LJ::Request::method_number {
    my $class = shift;
    return $instance->{r}->method_number(@_);
}

sub LJ::Request::status {
    my $class = shift;
    return $instance->{r}->status(@_);
}

sub LJ::Request::status_line {
    my $class = shift;
    return $instance->{r}->status_line(@_);
}

##
##
##
sub LJ::Request::free {
    my $class = shift;
    $instance = undef;
}


sub LJ::Request::notes {
    my $class = shift;
    return $instance->{r}->pnotes(@_);
}

sub LJ::Request::pnotes {
    my $class = shift;
    $instance->{r}->pnotes (@_);
}

sub LJ::Request::parse {
    my $class = shift;
    $instance->{r}->parse (@_);
}

sub LJ::Request::uri {
    my $class = shift;
    $instance->{r}->uri (@_);
}

sub LJ::Request::hostname {
    my $class = shift;
    $instance->{r}->hostname (@_);
}

sub LJ::Request::header_out {
    my $class = shift;
    my $header = shift;
    if (@_ > 0){
        return $instance->{r}->err_headers_out->{$header} = shift;
    } else {
        return $instance->{r}->err_headers_out->{$header};
    }
}

sub LJ::Request::headers_out {
    my $class = shift;
    $instance->{r}->headers_out (@_);
}

sub LJ::Request::header_in {
    my $class = shift;
    my $header = shift;
    if (@_ > 0){
        return $instance->{r}->headers_in->{$header} = shift;
    } else {
        return $instance->{r}->headers_in->{$header};
    }
}

sub LJ::Request::headers_in {
    my $class = shift;
    $instance->{r}->headers_in();
}

sub LJ::Request::param {
    my $class = shift;
    $instance->{r}->param (@_);
}

sub LJ::Request::no_cache {
    my $class = shift;
    $instance->{r}->no_cache (@_);
}

sub LJ::Request::content_type {
    my $class = shift;
    $instance->{r}->content_type (@_);
}

sub LJ::Request::pool {
    my $class = shift;
    $instance->{r}->pool;
}

sub LJ::Request::connection {
    my $class = shift;
    $instance->{r}->connection;
}

sub LJ::Request::output_filters {
    my $class = shift;
    $instance->{r}->output_filters(@_);
}

sub LJ::Request::print {
    my $class = shift;
    $instance->{r}->print (@_);
}

sub LJ::Request::content_encoding {
    my $class = shift;
    $instance->{r}->content_encoding(@_);
}

sub LJ::Request::send_http_header {
    my $class = shift;
    # http://perl.apache.org/docs/2.0/user/porting/compat.html#C____r_E_gt_send_http_header___
    # This method is not needed in 2.0,
    1
}


sub LJ::Request::err_headers_out {
    my $class = shift;
    $instance->{r}->err_headers_out (@_)
}



## Returns Array (Key, Value, Key, Value) which can be converted to HASH.
## But there can be some params with the same name!
#
# TODO: do we need this and 'args' methods? they are much the same.
sub LJ::Request::get_params {
    my $class = shift;
    if (wantarray()){
        my $qs = $instance->{r}->args(@_);
        my @args =
            map { URI::Escape::uri_unescape ($_) }
            map { split /=/ => $_, 2 }
            split /[\&\;]/ => $qs;
        return @args;
    } else {
        return $instance->{r}->args(@_);
    }
}
sub LJ::Request::post_params {
    my $class = shift;

    return @{ $instance->{params} } if $instance->{params};
    my @params = ();
    foreach my $name ($instance->{apr}->body){
        foreach my $val ($instance->{apr}->body($name)){
            push @params => $name, $val;
        }
    }
    $instance->{params} = \@params;
    return @params;

}


sub LJ::Request::add_header_out {
    my $class  = shift;
    my $header = shift;
    my $value  = shift;

    $instance->{r}->err_headers_out->add($header, $value);
    $instance->{r}->headers_out->add($header, $value);

    return 1;
}

# TODO: maybe remove next method and use 'header_out' instead?
sub LJ::Request::set_header_out {
    my $class  = shift;
    my $header = shift;
    my $value  = shift;

    $instance->{r}->err_headers_out->set($header, $value);
    $instance->{r}->headers_out->set($header, $value);

    return 1;
}

sub LJ::Request::unset_headers_in {
    my $class = shift;
    my $header = shift;
    $instance->{r}->headers_in->unset($header);
}

sub LJ::Request::log_error {
    my $class = shift;
    return $instance->{r}->log_error(@_);
}

sub LJ::Request::remote_ip {
    my $class = shift;
    return $instance->{r}->connection()->remote_ip(@_);
}

sub LJ::Request::remote_host {
    my $class = shift;
    return $instance->{r}->connection()->remote_host;
}

sub LJ::Request::user {
    my $class = shift;
    return $instance->{r}->auth_name();
}

sub LJ::Request::aborted {
    my $class = shift;
    return $instance->{r}->connection()->aborted;
}

sub LJ::Request::upload {
    my $class = shift;
    return $instance->{apr}->upload(@_);
}
sub LJ::Request::sendfile {
    my $class = shift;
    my $filename = shift;
    my $fh       = shift; # used in Apache v.1

    return $instance->{r}->sendfile($filename);
}

sub LJ::Request::parsed_uri {
    my $class = shift;
    $instance->{r}->parsed_uri; # Apache2::URI
}

sub LJ::Request::current_callback {
    my $class = shift;
    return ModPerl::Util::current_callback();
}

sub LJ::Request::child_terminate {
    my $class = shift;
    return $instance->{r}->child_terminate;
}

sub LJ::Request::meets_conditions {
    my $class = shift;
        return $instance->{r}->meets_conditions;
}

1;
