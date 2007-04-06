#
# Wrapper around MemCachedClient

use lib "$ENV{'FBHOME'}/lib";
use Cache::Memcached;
use strict;

package FB::MemCache;

%FB::MEMCACHE_ARRAYFMT = ( );

my $memc;  # memcache object

sub init {
    $memc = new Cache::Memcached ({ namespace => $FB::MEMCACHE_NAMESPACE || 'fb:' });

    reload_conf();
}

sub client_stats {
    return $memc->{'stats'} || {};
}

sub reload_conf {
    my $stat_callback;

    $memc->set_servers(\@FB::MEMCACHE_SERVERS);
    $memc->set_debug($FB::MEMCACHE_DEBUG);
    $memc->set_compress_threshold($FB::MEMCACHE_COMPRESS_THRESHOLD);
    if ($FB::DB_LOG_HOST) {
        $stat_callback = sub {
            my ($stime, $etime, $host, $action) = @_;
            FB::blocking_report($host, 'memcache', $etime - $stime, "memcache: $action");
        };
    } else {
        $stat_callback = undef;
    }
    $memc->set_stat_callback($stat_callback);
    $memc->set_readonly(1) if $ENV{FB_MEMC_READONLY};
    return $memc;
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

sub add       { $memc->add(@_);       }
sub replace   { $memc->replace(@_);   }
sub set       { $memc->set(@_);       }
sub get       { $memc->get(@_);       }
sub get_multi { $memc->get_multi(@_); }
sub incr      { $memc->incr(@_);      }
sub decr      { $memc->decr(@_);      }

sub _get_sock { $memc->get_sock(@_);   }

sub run_command { $memc->run_command(@_); }


sub array_to_hash {
    my ($fmtname, $ar) = @_;
    my $fmt = $FB::MEMCACHE_ARRAYFMT{$fmtname};
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
    my $fmt = $FB::MEMCACHE_ARRAYFMT{$fmtname};
    return undef unless $fmt;
    return undef unless $hash && ref $hash eq "HASH";
    my $ar = [$fmt->[0]];
    my $ct = scalar(@$fmt);
    for (my $i=1; $i<$ct; $i++) {
        $ar->[$i] = $hash->{$fmt->[$i]};
    }
    return $ar;
}

1;
