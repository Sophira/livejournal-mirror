package LJ::JSON::RPC;

use strict;
use warnings;

use LJ::JSON;
use LJ::JSON::RPC::Item;
use LJ::Response::JSON;

sub new {
    my ($class, $uri, $request, $callback) = @_;
    my $self = bless {}, $class;

    $self->{'callback'} = $callback;

    eval {
        my $data = LJ::JSON->from_json($request);
        
        $self->{'is_array'} = ref $data eq 'ARRAY';

        if ($self->{'is_array'}) {
            foreach my $entry (@$data) {
                my $item = LJ::JSON::RPC::Item->new($uri, $entry);
                push @{$self->{'items'}}, { 'item' => $item, };
            }

            unless (@$data) {
                my $fatal = { 'error_code'    => -32600, 
                              'error_message' => 'Invalid Request' };
                              
                my $item = LJ::JSON::RPC::Item->new( { 'fatal' =>  $fatal } );
                $self->{'items'} = { 'item' => $item, };
            }
        } else {
            my $item = LJ::JSON::RPC::Item->new($uri, $data);
            $self->{'items'} = { 'item' => $item, };
        }
    };

    if ($@) {
        warn $@ if $LJ::IS_DEV_SERVER;
        my $fatal = { 'error_code'    => -32700, 
                      'error_message' => 'Parse error' };

        my $item = LJ::JSON::RPC::Item->new({ 'fatal' =>  $fatal });
        $self->{'items'} = { 'item' => $item };
    }

    return $self;
}

sub call {
    my ($self, $callback) = @_;
    my $items = $self->{'items'};
    
    if ($self->{'is_array'}){
        $self->__call_array($items, $callback);
    } else {
        $self->__call_item($items, $callback);
    }
}

sub __call_array {
    my ($self, $items, $callback) = @_;

    foreach my $entry (@$items) {
        $self->__call_item($entry, $callback);
    } 
}

sub __call_item {
    my ($self, $entry, $callback) = @_;

    my $item   = $entry->{'item'};
    return if $item->error;

    my $method = $item->method;
    my $params = $item->params;

    my $call_info = {
        'source'        => 'jsonrpc',
        'type'          => $self->{'callback'} ? 'jsonp' : 'CORS',
        'access_data'   => $item->access_data,
        'access_type'   => $item->access_type,
    };

    $entry->{'result'} = $callback->($method, $params, $call_info);
}

sub response {
    my ($self) = @_;
    my $items = $self->{'items'};
    my $resp_data;
    my $headers = {};
    
    if ($self->{'is_array'}) {
        foreach my $entry (@$items) {
            my $item     = $entry->{'item'};
            my $response = $item->response($entry->{'result'});

            push @{$resp_data}, $response if $response;
        }
    } else {
        my $item = $items->{'item'};
        my $result = $items->{'result'};

        $resp_data = $item->response($result);
        if ($self->{'callback'} && !$resp_data->{'error'}) {
            $headers = $self->__get_headers($result);
        }
    }

    return LJ::Response::JSON->new( 
                'data'          => $resp_data,
                'callback'      => $self->{'callback'},
                'javascript'    => ! !$self->{'callback'},
                'http_headers'  => $headers, );

}

sub __get_headers {
    my ($self, $result) = @_;

    if (LJ::API::RpcAuth::is_stat_domain( LJ::Request->hostname ) ) {
        if ($result->{'properties'}) {
            my $properties = $result->{'properties'};
            if ($properties->{'cache-time'}) {
                my $max_age = $properties->{'cache-time'};
                my $expires_out = HTTP::Date::time2str( time + $max_age );

                return  { 'Cache-Control' => "public, max-age=$max_age",
                          'Expires'       => $expires_out, };
            }
        }

        return { 'Cache-Control' => 'private, must-revalidate',
                 'Expires'       => '0', };

    }

    return;
}

1;
