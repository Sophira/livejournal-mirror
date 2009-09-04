#
# Wrapper around MemCachedClient

use lib "$ENV{LJHOME}/cgi-bin";
package LJ::MemCache;
use strict;

my $use_fast = not $LJ::DISABLED{disabled_cache_memcached_fast};
if ($use_fast){
    require Cache::Memcached::Fast;
} else {
    require Cache::Memcached;
}


use vars qw($GET_DISABLED);
$GET_DISABLED = 0;

%LJ::MEMCACHE_ARRAYFMT = (
                          'user' =>
                          [qw[1 userid user caps clusterid dversion email password status statusvis statusvisdate
                              name bdate themeid moodthemeid opt_forcemoodtheme allow_infoshow allow_contactshow
                              allow_getljnews opt_showtalklinks opt_whocanreply opt_gettalkemail opt_htmlemail
                              opt_mangleemail useoverrides defaultpicid has_bio txtmsg_status is_system
                              journaltype lang oldenc]],
                          'fgrp' => [qw[1 userid groupnum groupname sortorder is_public]],
                          # version #101 because old userpic format in memcached was an arrayref of
                          # [width, height, ...] and widths could have been 1 before, although unlikely
                          'userpic' => [qw[101 width height userid fmt state picdate location flags]],
                          'userpic2' => [qw[1 picid fmt width height state pictime md5base64 comment flags location url]],
                          'talk2row' => [qw[1 nodetype nodeid parenttalkid posterid datepost state]],
                          'usermsg' => [qw[1 journalid parent_msgid otherid timesent type]],
                          );


my $memc;  # memcache object

sub init {

    my $opts = _configure_opts();
    if ($use_fast){
        ## Init Fast (written in C) interface to Memcached
        $memc = Cache::Memcached::Fast->new($opts);
    
    } else {
        ## Init pure perl Memcached interface

        ##
        my $parser_class = LJ::conf_test($LJ::MEMCACHE_USE_GETPARSERXS) ? 'Cache::Memcached::GetParserXS'
                                                                        : 'Cache::Memcached::GetParser';
        eval "use $parser_class";

        # Check to see if the 'new' function/method is defined in the proper namespace, othewise don't
        # explicitly set a parser class. Cached::Memcached may have attempted to load the XS module, and
        # failed. This is a reasonable check to make sure it all went OK.
        if (eval 'defined &' . $parser_class . '::new') {
            $opts->{'parser_class'} = $parser_class;
        }

        ## connect
        $memc = Cache::Memcached->new($opts);

        ##
        if (LJ::_using_blockwatch()) {
           eval { LJ::Blockwatch->setup_memcache_hooks($memc) };

            warn "Unable to add Blockwatch hooks to Cache::Memcached client object: $@"
                if $@;
        }

        ##
        if ($LJ::DB_LOG_HOST) {
            my $stat_callback = sub {
                my ($stime, $etime, $host, $action) = @_;
                LJ::blocking_report($host, 'memcache', $etime - $stime, "memcache: $action");
            };
            $memc->set_stat_callback($stat_callback);
        }

    }

    return $memc;
}

sub set_memcache {
    $memc = shift;
}

sub get_memcache {
    init() unless $memc;
    return $memc
}

sub client_stats {
    return $memc->{'stats'} || {};
}


sub _configure_opts {
    my @servers = $use_fast
        ? map { { address => $_, weight => 1 } } @LJ::MEMCACHE_SERVERS
        : @LJ::MEMCACHE_SERVERS;
        
    return {
        servers => \@servers,
        compress_threshold => $LJ::MEMCACHE_COMPRESS_THRESHOLD,
        connect_timeout    => $LJ::MEMCACHE_CONNECT_TIMEOUT,
        nowait => 1,
        ($use_fast
            ? () # Cache::Memcached::Fast specefic options
            : (  
                # Cache::Memcached specific options
                debug           => $LJ::DEBUG{'memcached'},
                pref_ip         => \%LJ::MEMCACHE_PREF_IP,
                cb_connect_fail => $LJ::MEMCACHE_CB_CONNECT_FAIL,
                readonly        => $ENV{LJ_MEMC_READONLY} ? 1 : 0,
                )
        ),
    };
}
sub reload_conf {
    return init();
}

sub forget_dead_hosts { $memc->forget_dead_hosts(); }
sub disconnect_all    { $memc->disconnect_all();    }

sub delete {
    # use delete time if specified
    return $memc->delete(@_) if defined $_[1];

    # else default to 4 seconds:
    # version 1.1.7 vs. 1.1.6
    $memc->delete(@_, 4) || $memc->delete(@_);
}

sub add       { 
    my ($key, $val, $exp) = @_;
    $key = $key->[1]     # Cache::Memcached::Fast does not support combo [int, key] keys.
        if $use_fast and ref $key eq 'ARRAY';
    $val = '' unless defined $val;
    return $memc->add($key, $val, $exp);
}
sub replace   { 
    my ($key, $val) = @_;
    $key = $key->[1]     # Cache::Memcached::Fast does not support combo [int, key] keys.
        if $use_fast and ref $key eq 'ARRAY';
    $val = '' unless defined $val;
    return $memc->replace($key, $val);
}
sub set       { 
    my ($key, $val, $exp) = @_;
    $key = $key->[1]     # Cache::Memcached::Fast does not support combo [int, key] keys.
        if $use_fast and ref $key eq 'ARRAY';
    $val = '' unless defined $val;
    $memc->set($key, $val, $exp);
}
sub incr      { $memc->incr(@_);      }
sub decr      { $memc->decr(@_);      }

sub get       {
    return undef if $GET_DISABLED;
    if ($use_fast and ref $_[0] eq 'ARRAY'){ # Cache::Memcached::Fast does not support combo [int, key] keys.
        $_[0] = $_[0][1];
    }
    $memc->get(@_);
}

## gets supported only by ::Fast interface
sub can_gets { return $use_fast }

## @@ret: reference to an array [$cas, $value], or nothing.
sub gets {
    return $memc->gets(@_) if $use_fast and not $GET_DISABLED;
    return; 
}
## @ret: reference to hash, where $href->{$key} holds a reference to an array [$cas, $value].
sub gets_multi {
    return $memc->gets_multi(@_) if $use_fast and not $GET_DISABLED;
    return;
}

##
sub get_multi {
    return {} if $GET_DISABLED;
    if ($use_fast){ # Cache::Memcached::Fast does not support combo [int, key] keys.
        @_ = map { ref $_ eq 'ARRAY' ? $_[0][1] : $_ } @_;
    }
    $memc->get_multi(@_);
}

sub append {
    my ($key, $val) = @_;
    $key = $key->[1]     # Cache::Memcached::Fast does not support combo [int, key] keys.
        if $use_fast and ref $key eq 'ARRAY';
    $val = '' unless defined $val;
    return $use_fast
        ? $memc->append($key, $val)
        : _extended_set("append", $key, $val);
}

sub prepend {
    my ($key, $val) = @_;
    $key = $key->[1]     # Cache::Memcached::Fast does not support combo [int, key] keys.
        if $use_fast and ref $key eq 'ARRAY';
    $val = '' unless defined $val;
    return $use_fast
        ? $memc->prepend($key, $val)
        : _extended_set("prepend", $key, $val);
}

sub cas {
    my ($key, $cas, $val) = @_;
    $key = $key->[1]     # Cache::Memcached::Fast does not support combo [int, key] keys.
        if $use_fast and ref $key eq 'ARRAY';
    $val = '' unless defined $val;
    return $use_fast 
        ? $memc->cas($key, $cas, $val)
        : _extended_set("cas", $key, $cas, $val);
}

# Pureperl memcached interface Cache::Memcache v 1.26 does not support some memcached commands.
# this method uses private methods of Cache::Memcache to provide new functionality
sub _extended_set {
    my ($cmd, @args) = @_;
    my $append_func = ref($memc) . "::_set";
    my $res = undef;

    # Cache::Memcached::Fast has usefull flag 'nowt' - no wait for response
    no strict 'refs';
    if (defined wantarray()){ # scalar or list context
        $res = &$append_func("append", $memc, @args);
    } else {
        &$append_func("append", $memc, @args); # void context
    }
    use strict 'refs';
    return $res;
}



sub _get_sock { $memc->get_sock(@_);   }

sub run_command { $memc->run_command(@_); }


sub array_to_hash {
    my ($fmtname, $ar) = @_;
    my $fmt = $LJ::MEMCACHE_ARRAYFMT{$fmtname};
    return undef unless $fmt;
    return undef unless $ar && ref $ar eq "ARRAY" && $ar->[0] == $fmt->[0];
    my $hash = {};
    my $ct = scalar(@$fmt);
    for (my $i=1; $i<$ct; $i++) {
        $hash->{$fmt->[$i]} = $ar->[$i];
    }
    return $hash;
}

sub hash_to_array {
    my ($fmtname, $hash) = @_;
    my $fmt = $LJ::MEMCACHE_ARRAYFMT{$fmtname};
    return undef unless $fmt;
    return undef unless $hash && ref $hash;
    my $ar = [$fmt->[0]];
    my $ct = scalar(@$fmt);
    for (my $i=1; $i<$ct; $i++) {
        $ar->[$i] = $hash->{$fmt->[$i]};
    }
    return $ar;
}

sub get_or_set {
    my ($memkey, $code, $expire) = @_;
    my $val = LJ::MemCache::get($memkey);
    return $val if $val;
    $val = $code->();
    LJ::MemCache::set($memkey, $val, $expire);
    return $val;
}

1;
