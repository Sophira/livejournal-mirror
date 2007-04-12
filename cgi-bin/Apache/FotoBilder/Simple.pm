#!/usr/bin/perl
#

package Apache::FotoBilder::Simple;

use strict;
use Apache::Constants qw(:common REDIRECT FORBIDDEN HTTP_NOT_MODIFIED
                         HTTP_MOVED_PERMANENTLY HTTP_METHOD_NOT_ALLOWED
                         M_PUT M_GET M_POST HTTP_BAD_REQUEST
                         );

use FB::Protocol::Request;
use FB::Protocol::Response;

use XML::Simple;

sub handler
{
    my $r = shift;

    # Sometimes we cannot return valid XML to the user:
    # 1) we can only build an XML response with a Response
    #    object, which requires a Request object to be
    #    constructed.
    # 2) if Request or Response object constructors fail,
    #    we must return a generic HTTP 500 error
    # 3) if serialization of XML from a Response object
    #    fails, we must also send an HTTP 500 error

    my $req = new FB::Protocol::Request( r => $r )
        or return _http_err($r, $@);

    my $resp = new FB::Protocol::Response( req => $req )
        or return _http_err($r, $@);

    # try to read user-supplied variables into the request
    $req->read_vars
        or return _xml_err($r, $resp, $@);

    # run_methods could return false but we don't care since all errors are handled
    # within the method and it will add_errors to the response object as they are
    # encountered.  we just need to print out the xml unconditionally here
    $resp->run_methods;

    # send final xml respond to the client
    return _xml_success($r, $resp);
}

# unrecoverable http errors
# - this means we weren't even able to build an xml response
sub _http_err {
    my $r = shift;
    # throw away protocol status code if in $_[0]->[0];
    my $err = ref $_[0] eq 'ARRAY' ? $_[0]->[1] : $_[0];

    $r->content_type("text/plain");
    $r->status(500);
    $r->send_http_header;
    $r->print
        (join(': ', grep { $_ ne '' } 'Server Error', 
              'unrecoverable error in protocol request', $err));

    return OK;
}

sub _xml_err {
    my $r = shift;
    my $resp = shift;
    my ($code, $err) = ref $_[0] eq 'ARRAY' ? @{$_[0]} : (201 => $_[0]);

    return _http_err($r, [$code => $err])
        unless $r && $resp && $code && $err;

    # add error does not indicate failure
    $resp->add_error($code => $err);

    my $xmlret = $resp->get_xml
        or return _http_err($r, $@);

    # response type is text/xml
    $r->content_type("text/xml");
    $r->send_http_header;
    $r->print($xmlret);

    return OK;
}

sub _xml_success {
    my ($r, $resp) = @_;

    # try to serialize the response object to xml
    my $xmlret = $resp->get_xml
        or return _http_err($r, $@);

    # response type is text/xml
    $r->content_type("text/xml");
    $r->send_http_header;
    $r->print($xmlret);

    return OK;
}

1;
