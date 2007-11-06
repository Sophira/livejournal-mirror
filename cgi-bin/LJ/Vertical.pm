#
# LiveJournal Vertical object.
#

package LJ::Vertical;
use strict;
use vars qw/ $AUTOLOAD /;
use Carp qw/ croak /;

# how many entries to query and display in $self->recent_entries;
my $RECENT_ENTRY_LIMIT = 100;

# internal fields:
#
#    vertid:     id of the vertical being represented
#    name:       text name of the vertical
#    createtime: time when vertical was created
#    lastfetch:  time of last fetch from vertical data source
#    entries:    [ journalid, jitemid ] in order of preferred display
#
#    _loaded_row:     loaded vertical row
#    _loaded_entries: count of entries back in time that are loaded
#
# NOT IMPLEMENTED:
#    * tree-based hierarchy of verticals
#
# NOTES:
# * Storage of [ journalid, jitemid, instime ] using storable vs pack:
#
# lj@whitaker:~$ perl -I Storable -e 'use Storable; print length(Storable::nfreeze([ map { (3_500_000_000, 3_500_000_000, 3_500_000_000) } 1..10_000 ])) . "\n";'
# 360007
# lj@whitaker:~$ perl -I Storable -e 'use Storable; print length(pack("(NN)*", map { (3_500_000_000, 3_500_000_000, 3_500_000_000) } 1..10_000 )) . "\n";'
# 120000
#

my %singletons = (); # vertid => singleton

#
# Constructors
#

sub new
{
    my $class = shift;
    my $self  = bless {};

    my $n_arg   = scalar @_;
    croak("wrong number of arguments")
        unless $n_arg && ($n_arg % 2 == 0);

    my %opts = @_;

    $self->{vertid} = delete $opts{vertid};

    croak("need to supply vertid") unless defined $self->{vertid};

    croak("unknown parameters: " . join(", ", keys %opts))
        if %opts;

    # do we have a singleton for this vertical?
    {
        my $vertid = $self->{vertid};
        return $singletons{$vertid} if exists $singletons{$vertid};

        # save the singleton if it doesn't exist
        $singletons{$vertid} = $self;
    }

    return $self;
}
*instance = \&new;

sub create {
    my $class = shift;
    my $self  = bless {};

    my $n_arg   = scalar @_;
    croak("wrong number of arguments")
        unless $n_arg && ($n_arg % 2 == 0);

    my %opts = @_;

    $self->{name} = delete $opts{name};

    croak("need to supply name") unless defined $self->{name};

    croak("unknown parameters: " . join(", ", keys %opts))
        if %opts;
    
    my $dbh = LJ::get_db_writer()
        or die "unable to contact global db master to load vertical";

    $dbh->do("INSERT INTO vertical SET name=?, createtime=UNIX_TIMESTAMP()",
             undef, $self->{name});
    die $dbh->errstr if $dbh->err;

    return LJ::Vertical->new( vertid => $dbh->{mysql_insertid} );
}

#
# Singleton accessors and helper methods
#

sub reset_singletons {
    %singletons = ();
}

sub all_singletons {
    my $class = shift;

    return values %singletons;
}

sub unloaded_singletons {
    my $class = shift;

    return grep { ! $_->{_loaded_row} } $class->all_singletons;
}

#
# Loaders
#

sub memkey {
    my $self = shift;
    return [ $self->{vertid}, "vert:$self->{vertid}" ];
}

sub clear_memcache {
    my $self = shift;
    return LJ::MemCache::delete($self->memkey);
}

sub entries_memkey {
    my $self = shift;
    return [ $self->{vertid}, "vertentries:$self->{vertid}" ];
}

sub clear_entries_memcache {
    my $self = shift;
    return LJ::MemCache::delete($self->entries_memkey);
}


sub absorb_row {
    my ($self, $row) = @_;

    $self->{$_} = $row->{$_} foreach qw(name createtime lastfetch);
    $self->{_loaded_row} = 1;

    return 1;
}

sub absorb_entries {
    # FIXME: do
}

sub preload_rows {
    my $self = shift;
    return 1 if $self->{_loaded_row};

    my @to_load = $self->unloaded_singletons;
    my %need = map { $_->{vertid} => $_ } @to_load;

    my @mem_keys = map { $_->memkey } @to_load;
    my $memc = LJ::MemCache::get_multi(@mem_keys);

    # now which of the objects to load did we get a memcache key for?
    foreach my $obj (@to_load) {
        my $row = $memc->{"vert:$obj->{vertid}"};
        next unless $row;

        $obj->absorb_row;
        delete $need{$obj->{vertid}};
    }

    # now hit the db for what was left
    my $dbh = LJ::get_db_writer()
        or die "unable to contact global db master to load vertical";

    my @vals = keys %need;
    my $bind = LJ::bindstr(@vals);
    my $sth = $dbh->prepare("SELECT * FROM vertical WHERE vertid IN ($bind)");
    $sth->execute(@vals);

    while (my $row = $sth->fetchrow_hashref) {

        # what singleton does this DB row represent?
        my $obj = $need{$row->{vertid}};

        # set in memcache
        LJ::MemCache::set($obj->memkey => $row);

        # and update singleton (request cache)
        $obj->absorb_row($row);

        # and delete from %need for error reporting
        delete $need{$obj->{vertid}};

    }

    # weird, vertids that we coulnd't find in memcache or db?
    warn "unknown vertical(s): " . join(",", keys %need) if %need;

    # now memcache and request cache are both updated, we're done
    return 1;
}

# we don't do preloading of entries for all singletons because the assumption that
# calling entries on one vertical means it will be called on many doesn't tend to hold
sub load_entries {
    my $self = shift;
    return 1 if $self->{_loaded_entries};

    my $memval = LJ::MemCache::get_multi($self->entries_memkey);
    if ($memval) {
        $self->absorb_entries($memval);
        return 1;
    }

    # FIXME: Data::ConveyorBelt style which can load older entries by changing
    #        an offset value that spans memcache and db

    # now hit the db for what was left
    my $dbh = LJ::get_db_writer()
        or die "unable to contact global db master to load vertical";

    my $sth = $dbh->prepare("SELECT journalid, jitemid FROM vertical_entries " . 
                            "WHERE vertid=? ORDER BY instime DESC LIMIT 100");
    $sth->execute($self->{vertid});

    my @entries = ();
    while (my $row = $sth->fetchrow_hashref) {
        #
    }

    return 1;
}

# don't call this unless you're serious
sub delete_and_purge {
    my $self = shift;

    my $dbh = LJ::get_db_writer()
        or die "unable to contact global db master to load vertical";

    foreach my $table (qw(vertical vertical_entries)) {
        $dbh->do("DELETE FROM $table WHERE vertid=?", undef, $self->{vertid});
        die $dbh->errstr if $dbh->err;
    }

    $self->clear_memcache;
    $self->clear_entries_memcache;

    delete $singletons{$self->{vertid}};

    return;
}

#
# Accessors
#

sub _get_set {
    my $self = shift;
    my $key  = shift;

    if (@_) { # setter case
        my $val = shift;

        my $dbh = LJ::get_db_writer()
            or die "unable to contact global db master to load vertical";

        $dbh->do("UPDATE vertical SET $key=? WHERE vertid=?",
                 undef, $self->{vertid}, $val);
        die $dbh->errstr if $dbh->err;

        $self->clear_memcache;

        return $self->{$key} = $val;
    }

    # getter case
    $self->preload_rows unless $self->{_loaded_row};

    return $self->{$key};
}

sub vertid         { shift->_get_set('vertid')              }
sub name           { shift->_get_set('name')                }
sub set_name       { shift->_get_set('name' => $_[0])       }
sub createtime     { shift->_get_set('createtime')          }
sub set_createtime { shift->_get_set('createtime' => $_[0]) }
sub lastfetch      { shift->_get_set('lastfetch')           }
sub set_lastfetch  { shift->_get_set('lastfetch' => $_[0])  }


1;
