=head1 NAME

LJ::MemCache - LiveJournal-specific wrapper for various modules working
with memcached servers

=head1 NOTES AND CONVENTIONS

The underlying modules are as follows:

=over 2

=item *

Cache::Memcached

=item *

Cache::Memcached::Fast

=back

Please refer to the documentation of those for information how
get/set/etc functions work.

The methods here are not "class methods"; use LJ::MemCache::method,
not LJ::MemCache->method.

=head1 SUPPORTED METHODS

=head2 READING DATA

=over 2

=item *

get

=item *

gets

=item *

get_multi

=item *

gets_multi

=back

Note that gets and gets_multi may not be supported by the underlying module;
call LJ::MemCached::can_gets to find out.

=head2 WRITING DATA

=over 2

=item *

add

=item *

set

=item *

replace

=item *

incr

=item *

decr

=item *

append

=item *

prepend

=item *

delete

=item *

cas

=back

=head1 LJ-SPECIFIC METHODS

=head2 MAINTENANCE

=over 2

=item *

init()

=item *

set_memcache($handler_class)

=item *

get_memcache()

=item *

reload_conf()

=item *

disconnect_all()

=back

=head2 UTILITY

=over 2

=item *

get_or_set( $key, $coderef, $expire )

=back

=head2 SERIALIZATION AND DESERIALIZATION

=over 2

=item *

array_to_hash($format, $array)

=item *

hash_to_array($format, $hash)

=back

The %LJ::MEMCACHE_ARRAYFMT variable in this modules is a table that defines
formats; the first element of a format list is a numeric version value that
is set when writing and checked when fetching data.

=cut

package LJ::MemCache;
use strict;
use warnings;

use String::CRC32 qw();
use Carp qw();
use Data::Dumper qw();
use IO::Handle qw();

### VARIABLES ###

my @handlers = qw(
    LJ::MemCache::Fast
    LJ::MemCache::PP
);
my $used_handler;

# 'host:port' => handler
my %connections;
## 'host:port' => pid
my %connections_pid;

use vars qw( $GET_DISABLED );
$GET_DISABLED = 0;

%LJ::MEMCACHE_ARRAYFMT = (
    'user'          => [ qw( 2
                             userid user caps clusterid dversion status
                             statusvis statusvisdate name bdate themeid
                             moodthemeid opt_forcemoodtheme allow_infoshow
                             allow_contactshow allow_getljnews
                             opt_showtalklinks opt_whocanreply
                             opt_gettalkemail opt_htmlemail
                             opt_mangleemail useoverrides defaultpicid
                             has_bio txtmsg_status is_system journaltype
                             lang oldenc packed_props ) ],

    'fgrp'          => [ qw( 1
                             userid groupnum groupname sortorder
                             is_public ) ],

    # version #101 because old userpic format in memcached was an arrayref
    # of [width, height, ...] and widths could have been 1 before, although
    # unlikely
    'userpic'       => [ qw( 101
                             width height userid fmt state picdate location
                             flags ) ],

    'userpic2'      => [ qw( 1
                             picid fmt width height state pictime md5base64
                             comment flags location url ) ],

    'talk2row'      => [ qw( 1
                             nodetype nodeid parenttalkid posterid datepost
                             state ) ],

    'usermsg'       => [ qw( 1
                             journalid parent_msgid otherid timesent type ) ],

    'usermsgprop'   => [ qw( 1
                             userpic preformated ) ],
);

my $logfile = undef;

### PRIVATE FUNCTIONS ###

sub _hashfunc {
    my ($what) = @_;
    return ( String::CRC32::crc32($what) >> 16 ) & 0x7fff;
}

sub _connect {
    my ($server) = @_;

    if ($connections{$server} && $connections_pid{$server} ne $$) {
        warn "Connection to $server was established from other PID: old=$connections_pid{$server}, cur=$$"
            if $LJ::IS_DEV_SERVER;

        my $old_handler = delete $connections{$server};
        $old_handler->disconnect_all;
    }

    unless ( exists $connections{$server} ) {
        init()
            unless defined $used_handler;

        $connections{$server}
            = $used_handler->new({ 'servers' => [ $server ] });
        $connections_pid{$server} = $$;
    }

    return $connections{$server};
}

sub _get_connection {
    my ($key) = @_;

    my $hashval     = ref $key eq 'ARRAY' ? int $key->[0]
                                          : _hashfunc($key);

    my $num_server  = $hashval % scalar(@LJ::MEMCACHE_SERVERS);
    my $server      = $LJ::MEMCACHE_SERVERS[$num_server];

    return _connect($server);
}

sub _set_compression {
    my ( $conn, $key ) = @_;

    # currently, we aren't compressing the value only if we get to work
    # with a key as follows:
    #
    #   1. "talk2:$journalu->{'userid'}:L:$itemid"
    if ( $key =~ /^talk2:/ ) {
        $conn->enable_compress(0);
        return;
    }

    $conn->enable_compress(1);
}

my $enable_profiling = $ENV{'LJ_MEMCACHE_PROFILE'};

sub _profile {
    my ( $funcname, $key, $result ) = @_;

    return unless $enable_profiling;

    unless ( defined $logfile ) {
        open $logfile, '>>', "$ENV{LJHOME}/var/memcache-profile/$$.log"
            or die "cannot open log: $!";

        $logfile->autoflush;
    }

    $key =~ s/\b\d+\b/?/g;

    print $logfile "$funcname($key) " .
                   ( defined $result ? '[hit]' : '[miss]' ) .
                   "\n";
}

### MAINTENANCE METHODS ###

sub init {
    undef $used_handler;

    foreach my $handler (@handlers) {
        next unless $handler->can_use;

        $used_handler = $handler;
        last;
    }

    Carp::croak "no memcache handler"
        unless defined $used_handler;
}

sub get_memcache {
    return $used_handler;
}

sub set_memcache {
    my ($new_handler) = @_;
    $used_handler = $new_handler;
}

sub reload_conf {
    %connections = ();
    init();
}

sub disconnect_all {
    foreach my $conn ( values %connections ) {
        $conn->disconnect_all;
    }
    %connections     = ();
    %connections_pid = ();
}

sub list_servers {
    my %ret = @_;

    foreach my $server ( @LJ::MEMCACHE_SERVERS ) {
        $ret{$server} = _connect($server);
    }

    return \%ret;
}

### READING METHODS ###

sub get {
    my ( $key, @params ) = @_;

    return if $GET_DISABLED;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    my $res = $conn->get( $key, @params );

    _profile( 'get', $key, $res ) if $enable_profiling;

    return $res;
}

sub can_gets {
    return $used_handler->can_gets;
}

sub gets {
    my ($key) = @_;

    return if $GET_DISABLED;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    my $res = $conn->gets($key);

    _profile( 'gets', $key, $res ) if $enable_profiling;

    return $res;
}

sub get_multi {
    return {} if $GET_DISABLED;

    my @keys = @_;

    my ( @connections, %keys_map, @keys_normal );

    foreach my $key (@keys) {
        my $conn = _get_connection($key);
        my $cid  = int $conn;

        unless ( exists $keys_map{$cid} ) {
            $keys_map{$cid} = [];
            push @connections, $conn;
        }

        my $key_normal = ref $key eq 'ARRAY' ? $key->[1]
                                             : $key;

        push @{ $keys_map{$cid} }, $key_normal;
        push @keys_normal, $key_normal;
    }

    my %ret;

    foreach my $conn (@connections) {
        my $cid = int $conn;
        my $conn_ret = $conn->get_multi( @{ $keys_map{$cid} } );

        %ret = ( %ret, %$conn_ret );
    }

    _profile( 'get_multi', join(';', @keys_normal) ) if $enable_profiling;

    return \%ret;
}

sub gets_multi {
    return {} if $GET_DISABLED;

    my @keys = @_;

    my ( @connections, %keys_map, @keys_normal );

    foreach my $key (@keys) {
        my $conn = _get_connection($key);
        my $cid  = int $conn;

        unless ( exists $keys_map{$cid} ) {
            $keys_map{$cid} = [];
            push @connections, $conn;
        }

        my $key_normal = ref $key eq 'ARRAY' ? $key->[1]
                                             : $key;

        push @{ $keys_map{$cid} }, $key_normal;
        push @keys_normal, $key_normal;
    }

    my %ret;

    foreach my $conn (@connections) {
        my $cid = int $conn;
        my $conn_ret = $conn->gets_multi( @{ $keys_map{$cid} } );

        %ret = ( %ret, %$conn_ret );
    }

    _profile( 'gets_multi', join(';', @keys_normal) ) if $enable_profiling;

    return \%ret;
}

### WRITING METHODS ###

sub add {
    my ( $key, $value, $expire ) = @_;

    $value = '' unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'add', $key ) if $enable_profiling;

    _set_compression( $conn, $key );
    return $conn->add( $key, $value, $expire );
}

sub set {
    my ( $key, $value, $expire ) = @_;

    $value = '' unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'set', $key ) if $enable_profiling;

    _set_compression( $conn, $key );
    return $conn->set( $key, $value, $expire );
}

sub replace {
    my ( $key, $value, $expire ) = @_;

    $value = '' unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'replace', $key ) if $enable_profiling;

    _set_compression( $conn, $key );
    return $conn->replace( $key, $value, $expire );
}

sub incr {
    my ( $key, $value ) = @_;

    $value = 1 unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'incr', $key ) if $enable_profiling;

    return $conn->incr( $key, $value );
}

sub decr {
    my ( $key, $value ) = @_;

    $value = 1 unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'decr', $key ) if $enable_profiling;

    return $conn->decr( $key, $value );
}

sub append {
    my ( $key, $value ) = @_;

    $value = '' unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'append', $key ) if $enable_profiling;

    my $res = $conn->append( $key, $value );

    unless ($res) {
        # in case memcache failed to append to the value, it doesn't
        # remove the value that is stored; we assume that the client
        # updates memcache because it changed the original data, so
        # let's actually clear the old value ourselves as a fallback
        # mechanism
        $conn->delete($key);
    }

    return $res;
}

sub prepend {
    my ( $key, $value ) = @_;

    $value = '' unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'prepend', $key ) if $enable_profiling;

    my $res = $conn->prepend( $key, $value );

    unless ($res) {
        # in case memcache failed to prepend to the value, it doesn't
        # remove the value that is stored; we assume that the client
        # updates memcache because it changed the original data, so
        # let's actually clear the old value ourselves as a fallback
        # mechanism
        $conn->delete($key);
    }

    return $res;
}

sub delete {
    my ( $key, $expire ) = @_;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    _profile( 'delete', $key ) if $enable_profiling;

    my $res = $conn->delete( $key, $expire );

    return $res;
}

sub cas {
    my ( $key, $cas, $value ) = @_;

    $value = '' unless defined $value;

    my $conn = _get_connection($key);

    $key = $key->[1]
        if ref $key eq 'ARRAY';

    my $res = $conn->cas( $key, $cas, $value );

    _profile( 'cas', $key, $res ) if $enable_profiling;

    return $res;
}

### UTILITY METHODS ###

sub get_or_set {
    my ( $key, $code, $expire ) = @_;

    my $value = LJ::MemCache::get($key);

    unless ( defined $value ) {
        $value = $code->();
        LJ::MemCache::set( $key, $value, $expire );
    }

    return $value;
}

### OBJECT SERIALIZATION METHODS ###

sub array_to_hash {
    my ( $format, $array, $key ) = @_;

    my $format_info = $LJ::MEMCACHE_ARRAYFMT{$format};
    return unless $format_info;

    my $format_version = $format_info->[0];

    return unless defined $array;

    unless ($array) {
        Carp::cluck "trying to unserialize $format from memcache, "
                  . Data::Dumper::Dumper([$key, $array]) . " is not a true value; "
                  . "stacktrace follows";
        return;
    }

    unless ( ref $array eq 'ARRAY' ) {
        Carp::cluck "trying to unserialize $format from memcache, "
                  . Data::Dumper::Dumper([$key, $array]) . " is not an array value; "
                  . "stacktrace follows";
        return;
    }

    unless ( @$array ) {
        Carp::cluck "trying to unserialize $format from memcache, "
                  . Data::Dumper::Dumper([$key, $array]) . " is an empty arrayref; "
                  . "stacktrace follows";
        return;
    }

    unless ( $array->[0] =~ /^\d+$/ ) {
        Carp::cluck "trying to unserialize $format from memcache, "
                  . Data::Dumper::Dumper([$key, $array]) . " has a non-numeric "
                  . "'$array->[0]' as its version string; "
                  . "stacktrace follows";
        return;
    }

    return unless $array->[0] == $format_version;

    my %ret;
    foreach my $i ( 1 .. $#$format_info ) {
        $ret{ $format_info->[$i] } = $array->[$i];
    }

    return \%ret;
}

sub hash_to_array {
    my ( $format, $hash ) = @_;

    my $format_info = $LJ::MEMCACHE_ARRAYFMT{$format};
    return unless $format_info;

    my $format_version = $format_info->[0];
    return unless $hash
              and (ref $hash eq "HASH" 
                   or ref $hash eq 'LJ::User');

    my @ret = ( $format_version );
    foreach my $i ( 1 .. $#$format_info ) {
        push @ret, $hash->{ $format_info->[$i] };
    }

    return \@ret;
}

package LJ::MemCache::Fast;

BEGIN { our @ISA = qw( Cache::Memcached::Fast ); }

sub can_use {
    return unless LJ::is_enabled('cache_memcached_fast');

    eval { require Cache::Memcached::Fast };
    return if $@;

    return 1;
}

sub new {
    my ( $class, $opts ) = @_;

    return $class->SUPER::new({
        %$opts,
        'compress_threshold' => $LJ::MEMCACHE_COMPRESS_THRESHOLD,
        'connect_timeout'    => $LJ::MEMCACHE_CONNECT_TIMEOUT,
        'nowait'             => 1,
        'max_failures'       => 1,
        'failure_timeout'    => 25,
    });
}

sub can_gets { 1 }

package LJ::MemCache::PP;

BEGIN { our @ISA = qw( Cache::Memcached ); }

sub can_use {
    eval { require Cache::Memcached };
    1;
}

sub new {
    my ( $class, $opts ) = @_;

    my $conn = $class->SUPER::new({
        %$opts,
        'compress_threshold' => $LJ::MEMCACHE_COMPRESS_THRESHOLD,
        'connect_timeout'    => $LJ::MEMCACHE_CONNECT_TIMEOUT,
        'nowait'             => 1,

        # Cache::Memcached specific options
        'debug'              => $LJ::DEBUG{'memcached'},
        'pref_ip'            => \%LJ::MEMCACHE_PREF_IP,
        'cb_connect_fail'    => $LJ::MEMCACHE_CB_CONNECT_FAIL,
        'readonly'           => $ENV{'LJ_MEMC_READONLY'} ? 1 : 0,
    });

    if ($LJ::DB_LOG_HOST) {
        $conn->set_stat_callback(sub {
            my ($stime, $etime, $host, $action) = @_;

            LJ::blocking_report( $host, 'memcache', $etime - $stime,
                                 "memcache: $action" );
        });
    }

    return $conn;
}

sub can_gets { 0 }

sub append {
    return Cache::Memcached::_set( 'append', @_ );
}

sub prepend {
    return Cache::Memcached::_set( 'prepend', @_ );
}

sub cas {
    return Cache::Memcached::_set( 'cas', @_ );
}

1;
