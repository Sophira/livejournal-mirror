#
# LiveJournal Vertical object.
#

package LJ::Vertical;
use strict;
use vars qw/ $AUTOLOAD /;
use Carp qw/ croak /;

# how many entries to query and display in $self->recent_entries;
my $RECENT_ENTRY_LIMIT   = 100;
my $MEMCACHE_ENTRY_LIMIT = 1_000;
my $DB_ENTRY_CHUNK       = 1_000; # rows to fetch per quety

# internal fields:
#
#    vertid:     id of the vertical being represented
#    name:       text name of the vertical
#    createtime: time when vertical was created
#    lastfetch:  time of last fetch from vertical data source
#    entries:    [ [ journalid, jitemid ], [ ... ], ... ] in order of preferred display
#
#    _iter_idx:       index position of iterator within $self->{entries}
#    _loaded_row:     loaded vertical row
#    _loaded_entries: length of window which has been queried so far
#
# NOT IMPLEMENTED:
#    * tree-based hierarchy of verticals
#
# NOTES:
# * Storage of [ journalid, jitemid, instime ] using storable vs pack:
#
# lj@whitaker:~$ perl -I Storable -e 'use Storable; print length(pack("(NN)*", map { (3_500_000_000, 3_500_000_000, 3_500_000_000) } 1..1_000 )) . "\n";'
# 12000
# lj@whitaker:~$  perl -I Storable -e 'use Storable; print length(Storable::nfreeze([ map { (3_500_000_000, 3_500_000_000, 3_500_000_000) } 1..1_000 ])) . "\n";'
# 36007
#

my %singletons = (); # vertid => singleton

#
# Constructors
#

sub new
{
    my $class = shift;

    my $n_arg   = scalar @_;
    croak("wrong number of arguments")
        unless $n_arg && ($n_arg % 2 == 0);

    my %opts = @_;

    my $self = bless {
        # arguments
        vertid     => delete $opts{vertid},

        # initialization
        name       => undef,
        createtime => undef,
        lastfetch  => undef,
        entries    => [],

        # internal flags
        _iter_idx       => 0,
        _loaded_row     => 0,
        _loaded_entries => 0,
    };

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
    my ($self, $entries, $window_max) = @_;

    # add given entries to our in-object arrayref
    unshift @{$self->{entries}}, @$entries;

    # update _loaded_entries to reflect new data
    $self->{_loaded_entries} = $window_max;

    return 1;
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
    my %opts = @_;

    # limit is a number of entries that can be returned, so max_idx+1
    my $want_limit = delete $opts{limit};
    croak("must specify limit for loading entries")
        unless $want_limit >= 1;
    croak("limit for loading entries must be reasonable")
        unless $want_limit < 100_000;
    croak("unknown parameters: " . join(",", keys %opts)) if %opts;

    # have we already loaded what we need?
    return 1 if $self->{_loaded_entries} >= $want_limit;

    # can we get all that we need from memcache?
    # -- common case
    my $populate_memcache = 1;
    if ($self->{_loaded_entries} <= $MEMCACHE_ENTRY_LIMIT) {
        my $memval = LJ::MemCache::get($self->entries_memkey);
        if ($memval) {
            my @rows = ();
            my $cur = [];
            foreach my $val (unpack("(NN)*", $memval)) {
                push @$cur, $val;
                next unless @$cur == 2;
                push @rows, $cur;
                $cur = [];
            }

            # got something out of memcache, no need to populate it
            $populate_memcache = 0;

            # this will update $self->{_loaded_entries}
            $self->absorb_entries(\@rows, $MEMCACHE_ENTRY_LIMIT);

            # do we have all we need? can we return now?
            return 1 if $want_limit < $self->{_loaded_entries};
        }
    }

    # two cases get us here:
    # 1: need to go back farther than memcache will go
    # 2: memcache needs to be populated
    my ($db_offset, $db_limit) = $self->calc_db_offset_and_limit($want_limit);
    warn "query: offset=$db_offset, limit=$db_limit\n";

    # now hit the db for what was left
    my $db = $populate_memcache ? LJ::get_db_writer() : LJ::get_db_reader();
    die "unable to contact global db master to load vertical" unless $db;

    my $rows = $db->selectall_arrayref
        ("SELECT journalid, jitemid FROM vertical_entries WHERE vertid=? " . 
         "ORDER BY instime DESC LIMIT $db_offset,$db_limit", undef, $self->{vertid});
    die $db->errstr if $db->err;

    $self->absorb_entries($rows, $db_offset + $db_limit);

    # we loaded first $MEMCACHE_ENTRY_LIMIT rows, need to populate memcache
    if ($populate_memcache) {
        my $pack_data = pack("(NN)*", map { @$_ } @$rows);
        LJ::MemCache::set($self->entries_memkey, $pack_data);
    }

    return 1;
}

sub calc_db_offset_and_limit {
    my ($self, $want_limit) = @_;

    my ($db_offset, $db_limit);

    # case 1: we've loaded up to the memcache limit or more, fetch next $DB_ENTRY_LIMIT rows
    if ($self->{_loaded_entries} > $MEMCACHE_ENTRY_LIMIT) {
        $db_offset = $self->{_loaded_entries};

    # case 2: we've not loaded up to memcache limit, fetch up to $MEMCACHE_ENTRY_LIMIT so
    #         we can populate memcache in the next step
    } else {
        $db_offset = 0;
    }

    # how many rows do we need to fetch in order to meet $want_limit?
    my $need_rows   = $want_limit - $db_offset;

    # now, how many chunks is that?
    my $need_chunks = $need_rows % $DB_ENTRY_CHUNK == 0 ? # does $need_rows align exactly to a chunk?
        $need_rows / $DB_ENTRY_CHUNK :                    # simple division to get number of chunks
        int($need_rows / $DB_ENTRY_CHUNK) + 1;            # divide to get n-1 chunk, then add 1
    
    # db_limit should align to a multiple of $DB_ENTRY_CHUNK
    $db_limit = $DB_ENTRY_CHUNK * $need_chunks;

    return ($db_offset, $db_limit)
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

sub add_entry {
    my $self = shift;
    my @entries = @_;

    die "parameters must all be LJ::Entry object"
        if grep { ! ref $_ || ! $_->isa("LJ::Entry") } @entries;

    # add new entries to the db listing for this vertical
    my $dbh = LJ::get_db_writer()
        or die "unable to contact global db master to load vertical";

    my $bind = join(",", map { "(?,?,?,UNIX_TIMESTAMP())" } @entries);
    my @vals = map { $self->{vertid}, $_->journalid, $_->jitemid } @entries;

    $dbh->do("REPLACE INTO vertical_entries (vertid, journalid, jitemid, instime) " . 
             "VALUES $bind", undef, @vals);
    die $dbh->errstr if $dbh->err;

    # FIXME: lazily clean over time?

    # clear memcache for entries so changes will be reflected on next read
    $self->clear_entries_memcache;

    # add entries to current LJ::Vertical object in memory
    if ($self->{_loaded_entries}) {
        $self->absorb_entries([ map { $_->journalid, $_->jitemid } @entries ], $self->{_loaded_entries} + @entries);
    }

    return 1;
}
*add_entries = \&add_entry;

sub entries {
    my $self = shift;
    my %opts = @_;

    # start is 0-based, limit is a count
    my $start = delete $opts{start} || 0;
    my $limit = delete $opts{limit};
    croak("invalid start value: $start")
        if $start < 0;
    croak("must specify limit for loading entries")
        unless $limit >= 1;
    croak("limit for loading entries must be reasonable")
        unless $limit < 100_000;
    croak("unknown parameters: " . join(",", keys %opts)) if %opts;

    my $need_ct  = $start + $limit;
    my $need_idx = $start + $limit - 1; 

    # FIXME: make all of this a bit cleaner... methods for some of this complex logic

    # ensure that we've retrieved entries through need_ct
    unless ($self->{_loaded_entries} >= $need_ct) {
        $self->load_entries( limit => $need_ct );
    }

    # not enough entries?
    my $loaded_entry_ct = $self->loaded_entry_ct;
    warn "start: $start, end: $need_idx, entries: $loaded_entry_ct\n";
    
    return () unless $loaded_entry_ct;
    return () if $start > $loaded_entry_ct - 1;

    # make sure that we don't try to have an index past the end of the entries array
    my $entry_idx = $need_idx > $loaded_entry_ct - 1 ? $loaded_entry_ct - 1 : $need_idx;

    return $self->entry_singletons(@{$self->{entries}}[$start..$entry_idx]);
}

sub loaded_entry_ct {
    my $self = shift;

    return scalar @{$self->{entries}};
}

sub recent_entries {
    my $self = shift;

    # reset iterator to end of list which was just fetched, so ->next_entry will be the next from here
    $self->{_iter_idx} = $RECENT_ENTRY_LIMIT;

    # now return next $RECENT_ENTRY_LIMIT
    return $self->entries( start => 0, limit => $RECENT_ENTRY_LIMIT );
}

sub next_entry {
    my $self = shift;

    # return next, then advance iterator
    return $self->entries( start => $self->{_iter_idx}++, limit => 1 );
}

sub first_entry {
    my $self = shift;

    return $self->entries( start => 0, limit => 1 );
}

sub entry_singletons {
    my $self = shift;

    return map { LJ::Entry->new($_->[0], jitemid => $_->[1]) } @_;
}

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
