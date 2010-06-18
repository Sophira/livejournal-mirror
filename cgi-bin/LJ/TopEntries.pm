package LJ::TopEntries;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use LJ::ExtBlock;
use Storable qw//;


my %known_domains = map {$_ => 1} domains();

sub domains { qw/hmp_ontd hmp_spotlight culture entertainment/ }

sub new {
    my $class = shift;
    my %opts = @_;

    my $domain = $opts{domain};
    if (not $domain){ 
        ## prev API to this class
        ## it can be removed after #66 release
        $domain = 'hmp_ontd';
    }
    Carp::confess("unknown domain: $domain")
        unless exists $known_domains{$domain};

    my $self = {domain => $domain};
    $self->{remote}    = $opts{remote}    || LJ::get_remote();
    $self->{timelimit} = $opts{timelimit} || 24 * 3600;

    return bless $self, $class;
}

# key <---> hash. Key - a string with four numbers, hash - full info about post.
sub _key_from_hash {
    my $self = shift;
    my $h = shift;
    return "$h->{'timestamp'}:$h->{'journalid'}:$h->{'jitemid'}:$h->{'userpicid'}";
}

sub _hash_from_key {
    my $self = shift;
    my %args = @_;

    my $timestamp = $args{timestamp};
    my $journalid = $args{journalid};
    my $jitemid   = $args{jitemid};
    my $userpicid = $args{userpicid};
    my $tags      = $args{tags};
    my $vertical_name = $args{vertical_name};
    my $vertical_uri  = $args{vertical_uri};

#    my $key = shift;
#    my ($timestamp, $journalid, $jitemid, $userpicid) = @$key;

    return undef unless $journalid && $jitemid && $userpicid;

    my $entry = LJ::Entry->new($journalid, jitemid => $jitemid);

    return undef unless $entry;

    my $poster = $entry->poster();
    my $journal = LJ::load_userid($journalid);

    return undef unless $poster && $journal;

    # Get userpic from entry
    my $userpic = LJ::Userpic->new($poster, $userpicid);

    return undef unless $userpic && $userpic->valid();

    my $subject = $entry->subject_text();
    my $subject_trimed = LJ::html_trim_4gadgets($subject, 70, '');
    $subject_trimed .= '...' if $subject_trimed ne $subject;

    return
        {
            posterid    => $poster->{'userid'},
            journalid   => $journalid,
            jitemid     => $jitemid,
            userpicid   => $userpicid,

            subj        => $subject_trimed,
            text        => LJ::html_trim_4gadgets($entry->event_text(), 50, $entry->url()),
            #revtime     => $entry->prop('revtime'),
            url         => $entry->url(),
            time        => $entry->logtime_unix(),
            userpic     => $userpic->url(),
            poster      => $poster->ljuser_display(),
            timestamp   => $timestamp,

            comments    => $entry->reply_count,
            comments_url=> $entry->url(anchor => 'comments'),

            logtime     => $entry->logtime_unix,
            tags        => $tags,
            vertical_name => $vertical_name,
            vertical_uri  => $vertical_uri,

            key         => "$journalid:$jitemid",
        };
}

# Clean list before store: remove old elements.
sub _clean_list {
    my $self = shift;
    my %opts = @_;

    my @list = sort {$b->{'timestamp'} <=> $a->{'timestamp'}} @{$self->{'featured_posts'}};

    return @list if $self->{'min_entries'} >= scalar @list; # We already has a minimum.

    # Remove old entries - stay at least 'min_entries' recent and all within 24h from now.
    my $time_edge = time() - $self->{'timelimit'};
    my $count = $self->{'min_entries'};
    @list = grep { ($count-- > 0) || ($time_edge - $_->{'timestamp'} < 0) } @list;

    return @list;
}

sub _sort_list {
    my $self = shift;
    my %opts = @_;
    my @list =
        sort {$b->{'timestamp'} <=> $a->{'timestamp'}}
            grep { $_ && !($_->{'revtime'} && $_->{'revtime'} > $_->{'timestamp'}) }  # Sanity check
                    @{$self->{'featured_posts'}};

    return @list if $opts{'raw'};

    # Remove old entries - stay at least 'min_entries' recent and all within 24h from now.
    my $time_edge = time() - 24 * 3600;
    my $count = $self->{'min_entries'};
    @list = grep { ($count-- > 0) || ($time_edge - $_->{'timestamp'} < 0) } @list;

    # Remove elements below 'max_entries'.
    $count = scalar @list - $self->{'max_entries'};

    return @list if $count <= 0;

    while ($count--) {
        splice @list, int(rand(scalar @list)), 1;
    }

    return @list;
}

# store all from blessed hash to journal property.
sub _store_featured_posts {
    my $self = shift;
    my %opts = @_;
 
    # my $prop = $self->{'min_entries'} . ':' . $self->{'max_entries'} . ':0:0|' .
    #    join('|', map { $self->_key_from_hash($_) } $self->_clean_list(%opts));
    #$prop =~ s/\|$//;

    ##
    my @spots = $self->_clean_list(%opts);
    my $struct = {
        min_entries => $self->{min_entries},
        max_entries => $self->{max_entries},
        timelimit   => $self->{timelimit},

        spots       => \@spots,
    };
    my $data = Storable::freeze($struct);
    ##

    my $domain = $self->{domain};
    LJ::ExtBlock->create_or_replace("spts_$domain" => $data);
}

# load all from property to blessed hash.
sub _load_featured_posts {
    my $self = shift;
    my %opts = @_;

    my $domain = $self->{domain};
    my $ext_block = LJ::ExtBlock->load_by_id("spts_$domain");
    my $prop_val = $ext_block ? $ext_block->blocktext : '';
=head
    $prop_val = '3:5:0:0' unless $prop_val;

    my @entities = map { [ split /:/ ] } split(/\|/, $prop_val);

    my ($min_entries, $max_entries, undef, undef) = @{shift @entities};

    $self->{'min_entries'}      = $min_entries;
    $self->{'max_entries'}      = $max_entries;
    $self->{'featured_posts'}   = [ map { $self->_hash_from_key($_) } @entities ];
=cut
    if ($prop_val){
        my $struct = Storable::thaw($prop_val);
        $self->{min_entries}    = $struct->{min_entries};
        $self->{max_entries}    = $struct->{max_entries};
        $self->{featured_posts} = $struct->{spots} || [];
        $self->{timelimit}      = $struct->{timelimit};

        ## Update comments couter
        foreach my $spot (@{ $self->{featured_posts} }){
            my $entry = LJ::Entry->new($spot->{journalid}, jitemid => $spot->{jitemid});
            next unless $entry;
            $spot->{comments} = $entry->reply_count();
            $spot->{logtime}  = $spot->{time} = $entry->logtime_unix();
        }
    }
    $self->{min_entries} ||= 3;
    $self->{max_entries} ||= 5;
    $self->{timelimit}   ||= 24*3600;

    return $self->_sort_list(%opts);
}

# geters/seters
sub get_featured_posts {
    my $self = shift;
    my %opts = @_;
    return $self->{'featured_posts'} ?
        $self->_sort_list(%opts) : $self->_load_featured_posts(%opts);
}

sub min_entries {
    my $self = shift;

    $self->_load_featured_posts() unless $self->{'min_entries'};
    if ($_[0]) {
        my $min_entries = shift;
        if ($self->{'min_entries'} != $min_entries) {
            $self->{'min_entries'} = $min_entries;
            $self->_store_featured_posts();
        }
    }

    return $self->{'min_entries'};
}

sub max_entries {
    my $self = shift;

    $self->_load_featured_posts() unless $self->{'max_entries'};
    if ($_[0]) {
        my $max_entries = shift;
        if ($self->{'max_entries'} != $max_entries) {
            $self->{'max_entries'} = $max_entries;
            $self->_store_featured_posts();
        }
    }

    return $self->{'max_entries'};
}

# Add/del entries.
sub add_entry {
    my $self = shift;
    my %opts = @_;

    my $entry = $opts{'entry'};
    return 'wrong entry' unless $entry;

    my $tags = $opts{tags};
    my $vertical_name = $opts{vertical_name};
    my $vertical_uri  = $opts{vertical_uri};

    my $timestamp = time();

    my ($journalid, $jitemid, $poster, $userpic) =
        ($entry->journalid(), $entry->jitemid(), $entry->poster(), $entry->userpic());

    return 'wrong entry poster' unless $poster;

    my $userpicid   = $userpic ? $userpic->id() : ($poster->{'defaultpicid'} || 0);

    $self->delete_entry(key => "$journalid:$jitemid");

    $self->get_featured_posts(raw => 1, %opts); # make sure we has all fresh data

    ## Fullfill with other data
    my $post = $self->_hash_from_key( 
                timestamp => $timestamp, 
                journalid => $journalid, 
                jitemid   => $jitemid, 
                userpicid => $userpicid,
                tags      => $tags,
                vertical_name => $vertical_name,
                vertical_uri  => $vertical_uri,
                );

    if ($post) {
        push @{$self->{'featured_posts'}}, $post;
        $self->_store_featured_posts(%opts);
        return '';
    }

    # all other error conditions checked before call _hash_from_key()
    return 'userpic missed or does not valid';
}

sub delete_entry {
    my $self = shift;
    my %opts = @_;

    return unless $opts{'key'} =~ /(\d+):(\d+)/;

    my ($journalid, $jitemid) = ($1, $2);
    return unless $journalid && $jitemid;

    @{$self->{'featured_posts'}} = grep {
            ! ( $_->{'journalid'} == $journalid && $_->{'jitemid'}   == $jitemid )
        } $self->get_featured_posts(raw => 1, %opts);

    $self->_store_featured_posts(%opts);
}

1;

