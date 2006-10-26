#!/usr/bin/perl
#

use strict;
use lib "$ENV{'LJHOME'}/src/s2";
use S2;
use S2::Checker;
use S2::Color;
use S2::Compiler;
use Storable;
use Apache::Constants ();
use HTMLCleaner;
use LJ::CSS::Cleaner;
use POSIX ();

use LJ::S2::RecentPage;
use LJ::S2::YearPage;
use LJ::S2::DayPage;
use LJ::S2::FriendsPage;
use LJ::S2::MonthPage;
use LJ::S2::EntryPage;
use LJ::S2::ReplyPage;
use LJ::S2::TagsPage;

use Class::Autouse qw ( LJ::CommPromo );

package LJ::S2;

# TEMP HACK
sub get_s2_reader {
    return LJ::get_dbh("s2slave", "slave", "master");
}

sub make_journal
{
    my ($u, $styleid, $view, $remote, $opts) = @_;

    my $r = $opts->{'r'};
    my $ret;
    $LJ::S2::ret_ref = \$ret;

    my ($entry, $page);
    my $con_opts = {};

    if ($view eq "res") {

        # the s1shortcomings virtual styleid doesn't have a styleid
        # so we're making the rule that it can't have resource URLs.
        if ($styleid eq "s1short") {
            $opts->{'handler_return'} = 404;
            return;
        }

        if ($opts->{'pathextra'} =~ m!/(\d+)/stylesheet$!) {
            $styleid = $1;
            $entry = "print_stylesheet()";
            $opts->{'contenttype'} = 'text/css';
            $con_opts->{'use_modtime'} = 1;
        } else {
            $opts->{'handler_return'} = 404;
            return;
        }
    }

    $u->{'_s2styleid'} = $styleid + 0;

    $con_opts->{'u'} = $u;
    $con_opts->{'style_u'} = $opts->{'style_u'};
    my $ctx = s2_context($r, $styleid, $con_opts);
    unless ($ctx) {
        $opts->{'handler_return'} = Apache::Constants::OK();
        return;
    }

    my $lang = 'en';
    LJ::run_hook('set_s2bml_lang', $ctx, \$lang);

    # note that's it's very important to pass LJ::Lang::get_text here explicitly
    # rather than relying on BML::set_language's fallback mechanism, which won't
    # work in this context since BML::cur_req won't be loaded if no BML requests
    # have been served from this Apache process yet
    BML::set_language($lang, \&LJ::Lang::get_text);

    # let layouts disable EntryPage / ReplyPage, using the BML version
    # instead.
    unless ($styleid eq "s1short") {
        if ($ctx->[S2::PROPS]->{'view_entry_disabled'} && ($view eq "entry" || $view eq "reply")) {
            ${$opts->{'handle_with_bml_ref'}} = 1;
            return;
        }

        # make sure capability supports it
        if (($view eq "entry" || $view eq "reply") &&
            ! LJ::get_cap(($opts->{'checkremote'} ? $remote : $u), "s2view$view")) {
            ${$opts->{'handle_with_bml_ref'}} = 1;
            return;
        }
    }

    # setup tags backwards compatibility
    unless ($ctx->[S2::PROPS]->{'tags_aware'}) {
        $opts->{enable_tags_compatibility} = 1;
    }

    $opts->{'ctx'} = $ctx;
    $LJ::S2::CURR_CTX = $ctx;

    foreach ("name", "url", "urlname") { LJ::text_out(\$u->{$_}); }

    $u->{'_journalbase'} = LJ::journal_base($u->{'user'}, $opts->{'vhost'});

    if ($view eq "lastn") {
        $entry = "RecentPage::print()";
        $page = RecentPage($u, $remote, $opts);
    } elsif ($view eq "calendar") {
        $entry = "YearPage::print()";
        $page = YearPage($u, $remote, $opts);
    } elsif ($view eq "day") {
        $entry = "DayPage::print()";
        $page = DayPage($u, $remote, $opts);
    } elsif ($view eq "friends" || $view eq "friendsfriends") {
        $entry = "FriendsPage::print()";
        $page = FriendsPage($u, $remote, $opts);
    } elsif ($view eq "month") {
        $entry = "MonthPage::print()";
        $page = MonthPage($u, $remote, $opts);
    } elsif ($view eq "entry") {
        $entry = "EntryPage::print()";
        $page = EntryPage($u, $remote, $opts);
    } elsif ($view eq "reply") {
        $entry = "ReplyPage::print()";
        $page = ReplyPage($u, $remote, $opts);
    } elsif ($view eq "tag") {
        $entry = "TagsPage::print()";
        $page = TagsPage($u, $remote, $opts);
    }

    return if $opts->{'suspendeduser'};
    return if $opts->{'handler_return'};

    # the friends mode=live returns raw HTML in $page, in which case there's
    # nothing to "run" with s2_run.  so $page isn't runnable, return it now.
    # but we have to make sure it's defined at all first, otherwise things
    # like print_stylesheet() won't run, which don't have an method invocant
    return $page if $page && ref $page ne 'HASH';

    # Include any head stc or js head content
    $page->{head_content} .= LJ::res_includes();

    s2_run($r, $ctx, $opts, $entry, $page);

    if (ref $opts->{'errors'} eq "ARRAY" && @{$opts->{'errors'}}) {
        return join('',
                    "Errors occurred processing this page:<ul>",
                    map { "<li>$_</li>" } @{$opts->{'errors'}},
                    "</ul>");
    }

    # unload layers that aren't public
    LJ::S2::cleanup_layers($ctx);

    # If there's an entry for contenttype in the context 'scratch'
    # area, copy it into the "real" content type field.
    $opts->{contenttype} = $ctx->[S2::SCRATCH]->{contenttype}
        if defined $ctx->[S2::SCRATCH]->{contenttype};

    return $ret;
}

sub s2_run
{
    my ($r, $ctx, $opts, $entry, $page) = @_;

    my $ctype = $opts->{'contenttype'} || "text/html";
    my $cleaner;
    if ($ctype =~ m!^text/html!) {
        $cleaner = new HTMLCleaner (
                                    'output' => sub { $$LJ::S2::ret_ref .= $_[0]; },
                                    'valid_stylesheet' => \&LJ::valid_stylesheet_url,
                                    );
    }

    my $send_header = sub {
        my $status = $ctx->[S2::SCRATCH]->{'status'} || 200;
        $r->status($status);
        $r->content_type($ctx->[S2::SCRATCH]->{'ctype'} || $ctype);
        $r->send_http_header();
    };

    my $need_flush;

    my $print_ctr = 0;  # every 'n' prints we check the recursion depth

    my $out_straight = sub {
        # Hacky: forces text flush.  see:
        # http://zilla.livejournal.org/906
        if ($need_flush) {
            $cleaner->parse("<!-- -->");
            $need_flush = 0;
        }
        $$LJ::S2::ret_ref .= $_[0];
        S2::check_depth() if ++$print_ctr % 8 == 0;
    };
    my $out_clean = sub {
        $cleaner->parse($_[0]);
        $need_flush = 1;
        S2::check_depth() if ++$print_ctr % 8 == 0;
    };
    S2::set_output($out_straight);
    S2::set_output_safe($cleaner ? $out_clean : $out_straight);

    $LJ::S2::CURR_PAGE = $page;
    $LJ::S2::RES_MADE = 0;  # standard resources (Image objects) made yet

    my $css_mode = $ctype eq "text/css";

    S2::Builtin::LJ::start_css($ctx) if $css_mode;
    eval {
        S2::run_code($ctx, $entry, $page);
    };
    S2::Builtin::LJ::end_css($ctx) if $css_mode;

    $LJ::S2::CURR_PAGE = undef;
    $LJ::S2::CURR_CTX  = undef;

    if ($@) {
        my $error = $@;
        $error =~ s/\n/<br \/>\n/g;
        S2::pout("<b>Error running style:</b> $error");
        return 0;
    }
    $cleaner->eof if $cleaner;  # flush any remaining text/tag not yet spit out
    return 1;
}

# <LJFUNC>
# name: LJ::S2::get_tags_text
# class: s2
# des: Gets text for display in entry for tags compatibility.
# args: ctx, taglistref
# des-ctx: Current S2 context
# des-taglistref: Arrayref containing "Tag" S2 objects
# returns: String; can be appended to entry... undef on error (no context, no taglistref)
# </LJFUNC>
sub get_tags_text {
    my ($ctx, $taglist) = @_;
    return undef unless $ctx && $taglist;
    return "" unless @$taglist;

    # now get the customized tag text and insert the tag list and append to body
    my $tags = join(', ', map { "<a rel='tag' href='$_->{url}'>$_->{name}</a>" } @$taglist);
    my $tagtext = S2::get_property_value($ctx, 'text_tags');
    $tagtext =~ s/#/$tags/;
    return "<div class='ljtags'>$tagtext</div>";
}

# returns hashref { lid => $u }; undef on error
sub get_layer_owners {
    my @lids = map { $_ + 0 } @_;
    return {} unless @lids;

    my $ret = {}; # lid => uid/$u
    my %need = ( map { $_ => 1 } @lids ); # layerid => 1

    # see what we can get out of memcache first
    my @keys;
    push @keys, [ $_, "s2lo:$_" ] foreach @lids;
    my $memc = LJ::MemCache::get_multi(@keys);
    foreach my $lid (@lids) {
        if (my $uid = $memc->{"s2lo:$lid"}) {
            delete $need{$lid};
            $ret->{$lid} = $uid;
        }
    }

    # if we still need any from the database, get them now
    if (%need) {
        my $dbh = LJ::get_db_writer();
        my $in = join(',', keys %need);
        my $res = $dbh->selectall_arrayref("SELECT s2lid, userid FROM s2layers WHERE s2lid IN ($in)");
        die "Database error in LJ::S2::get_layer_owners: " . $dbh->errstr . "\n" if $dbh->err;

        foreach my $row (@$res) {
            # save info and add to memcache
            $ret->{$row->[0]} = $row->[1];
            LJ::MemCache::add([ $row->[0], "s2lo:$row->[0]" ], $row->[1]);
        }
    }

    # now load these users; they're likely process cached anyway, so it should
    # be pretty fast
    my $us = LJ::load_userids(values %$ret);
    foreach my $lid (keys %$ret) {
        $ret->{$lid} = $us->{$ret->{$lid}}
    }
    return $ret;
}

# returns max comptime of all lids requested to be loaded
sub load_layers {
    my @lids = map { $_ + 0 } @_;
    return 0 unless @lids;

    my $maxtime = 0;  # to be returned

    # figure out what is process cached...that goes to DB always
    # if it's not in process cache, hit memcache first
    my @from_db;   # lid, lid, lid, ...
    my @need_memc; # lid, lid, lid, ...

    # initial sweep, anything loaded for less than 60 seconds is golden
    # if dev server, only cache layers for 1 second
    foreach my $lid (@lids) {
        if (my $loaded = S2::layer_loaded($lid, $LJ::IS_DEV_SERVER ? 1 : 60)) {
            # it's loaded and not more than 60 seconds load, so we just go
            # with it and assume it's good... if it's been recompiled, we'll
            # figure it out within the next 60 seconds
            $maxtime = $loaded if $loaded > $maxtime;
        } else {
            push @need_memc, $lid;
        }
    }

    # attempt to get things in @need_memc from memcache
    my $memc = LJ::MemCache::get_multi(map { [ $_, "s2c:$_"] } @need_memc);
    foreach my $lid (@need_memc) {
        if (my $row = $memc->{"s2c:$lid"}) {
            # load the layer from memcache; memcache data should always be correct
            my ($updtime, $data) = @$row;
            if ($data) {
                $maxtime = $updtime if $updtime > $maxtime;
                S2::load_layer($lid, $data, $updtime);
            }
        } else {
            # make it exist, but mark it 0
            push @from_db, $lid;
        }
    }

    # it's possible we don't need to hit the database for anything
    return $maxtime unless @from_db;

    # figure out who owns what we need
    my $us = LJ::S2::get_layer_owners(@from_db);
    my $sysid = LJ::get_userid('system');

    # break it down by cluster
    my %bycluster; # cluster => [ lid, lid, ... ]
    foreach my $lid (@from_db) {
        next unless $us->{$lid};
        if ($us->{$lid}->{userid} == $sysid) {
            push @{$bycluster{0} ||= []}, $lid;
        } else {
            push @{$bycluster{$us->{$lid}->{clusterid}} ||= []}, $lid;
        }
    }

    # big loop by cluster
    foreach my $cid (keys %bycluster) {
        # if we're talking about cluster 0, the global, pass it off to the old
        # function which already knows how to handle that
        unless ($cid) {
            my $dbr = LJ::S2::get_s2_reader();
            S2::load_layers_from_db($dbr, @{$bycluster{$cid}});
            next;
        }

        my $db = LJ::get_cluster_master($cid);
        die "Unable to obtain handle to cluster $cid for LJ::S2::load_layers\n"
            unless $db;

        # create SQL to load the layers we want
        my $where = join(' OR ', map { "(userid=$us->{$_}->{userid} AND s2lid=$_)" } @{$bycluster{$cid}});
        my $sth = $db->prepare("SELECT s2lid, compdata, comptime FROM s2compiled2 WHERE $where");
        $sth->execute;

        # iterate over data, memcaching as we go
        while (my ($id, $comp, $comptime) = $sth->fetchrow_array) {
            LJ::text_uncompress(\$comp);
            LJ::MemCache::set([ $id, "s2c:$id" ], [ $comptime, $comp ])
                if length $comp <= $LJ::MAX_S2COMPILED_CACHE_SIZE;
            S2::load_layer($id, $comp, $comptime);
            $maxtime = $comptime if $comptime > $maxtime;
        }
    }

    # now we have to go through everything again and verify they're all loaded and
    # otherwise do a fallback to the global
    my @to_load;
    foreach my $lid (@from_db) {
        next if S2::layer_loaded($lid);

        unless ($us->{$lid}) {
            print STDERR "Style $lid has no available owner.\n";
            next;
        }

        if ($us->{$lid}->{userid} == $sysid) {
            print STDERR "Style $lid is owned by system but failed load from global.\n";
            next;
        }

        if ($LJ::S2COMPILED_MIGRATION_DONE) {
            LJ::MemCache::set([ $lid, "s2c:$lid" ], [ time(), 0 ]);
            next;
        }

        push @to_load, $lid;
    }
    return $maxtime unless @to_load;

    # get the dbh and start loading these
    my $dbr = LJ::S2::get_s2_reader();
    die "Failure getting S2 database handle in LJ::S2::load_layers\n"
        unless $dbr;

    my $where = join(' OR ', map { "s2lid=$_" } @to_load);
    my $sth = $dbr->prepare("SELECT s2lid, compdata, comptime FROM s2compiled WHERE $where");
    $sth->execute;
    while (my ($id, $comp, $comptime) = $sth->fetchrow_array) {
        S2::load_layer($id, $comp, $comptime);
        $maxtime = $comptime if $comptime > $maxtime;
    }
    return $maxtime;
}

# find existing re-distributed layers that are in the database
# and their styleids.
sub get_public_layers
{
    my $opts = ref $_[0] eq 'HASH' ? shift : {};
    my $sysid = shift;  # optional system userid (usually not used)

    unless ($opts->{force}) {
        $LJ::CACHED_PUBLIC_LAYERS ||= LJ::MemCache::get("s2publayers");
        return $LJ::CACHED_PUBLIC_LAYERS if $LJ::CACHED_PUBLIC_LAYERS;
    }

    $sysid ||= LJ::get_userid("system");
    my $layers = get_layers_of_user($sysid, "is_system", [qw(des note author author_name author_email)]);

    $LJ::CACHED_PUBLIC_LAYERS = $layers if $layers;
    LJ::MemCache::set("s2publayers", $layers, 60*10) if $layers;
    return $LJ::CACHED_PUBLIC_LAYERS;
}

# update layers whose b2lids have been remapped to new s2lids
sub b2lid_remap
{
    my ($uuserid, $s2lid, $b2lid) = @_;
    my $b2lid_new = $LJ::S2LID_REMAP{$b2lid};
    return undef unless $uuserid && $s2lid && $b2lid && $b2lid_new;

    my $sysid = LJ::get_userid("system");
    return undef unless $sysid;

    LJ::statushistory_add($uuserid, $sysid, 'b2lid_remap', "$s2lid: $b2lid=>$b2lid_new");

    my $dbh = LJ::get_db_writer();
    return $dbh->do("UPDATE s2layers SET b2lid=? WHERE s2lid=?",
                    undef, $b2lid_new, $s2lid);
}

sub get_layers_of_user
{
    my ($u, $is_system, $infokeys) = @_;
    my $userid = LJ::want_userid($u);
    return undef unless $userid;
    undef $u unless LJ::isu($u);

    return $u->{'_s2layers'} if $u && $u->{'_s2layers'};

    my %layers;    # id -> {hashref}, uniq -> {same hashref}
    my $dbr = LJ::S2::get_s2_reader();

    my $extrainfo = $is_system ? "'redist_uniq', " : "";
    $extrainfo .= join(', ', map { $dbr->quote($_) } @$infokeys).", " if $infokeys;

    my $sth = $dbr->prepare("SELECT i.infokey, i.value, l.s2lid, l.b2lid, l.type ".
                            "FROM s2layers l, s2info i ".
                            "WHERE l.userid=? AND l.s2lid=i.s2lid AND ".
                            "i.infokey IN ($extrainfo 'type', 'name', 'langcode', ".
                            "'majorversion', '_previews')");
    $sth->execute($userid);
    die $dbr->errstr if $dbr->err;
    while (my ($key, $val, $id, $bid, $type) = $sth->fetchrow_array) {
        $layers{$id}->{'b2lid'} = $bid;
        $layers{$id}->{'s2lid'} = $id;
        $layers{$id}->{'type'} = $type;
        $key = "uniq" if $key eq "redist_uniq";
        $layers{$id}->{$key} = $val;
    }

    foreach (keys %layers) {
        # setup uniq alias.
        if ($layers{$_}->{'uniq'} ne "") {
            $layers{$layers{$_}->{'uniq'}} = $layers{$_};
        }

        # setup children keys
        my $bid = $layers{$_}->{b2lid};
        next unless $layers{$_}->{'b2lid'};

        # has the b2lid for this layer been remapped?
        # if so update this layer's specified b2lid
        if ($bid && $LJ::S2LID_REMAP{$bid}) {
            my $s2lid = $layers{$_}->{s2lid};
            b2lid_remap($userid, $s2lid, $bid);
            $layers{$_}->{b2lid} = $LJ::S2LID_REMAP{$bid};
        }

        if ($is_system) {
            my $bid = $layers{$_}->{'b2lid'};
            unless ($layers{$bid}) {
                delete $layers{$layers{$_}->{'uniq'}};
                delete $layers{$_};
                next;
            }
            push @{$layers{$bid}->{'children'}}, $_;
        }
    }

    if ($u) {
        $u->{'_s2layers'} = \%layers;
    }
    return \%layers;
}


# get_style:
#
# many calling conventions:
#    get_style($styleid, $verify)
#    get_style($u,       $verify)
#    get_style($styleid, $opts)
#    get_style($u,       $opts)
#
# opts may contain keys:
#   - 'u' -- $u object
#   - 'verify' --  if verify, the $u->{'s2_style'} key is deleted if style isn't found
sub get_style
{
    my ($arg, $opts) = @_;

    my $verify = 0;
    my ($styleid, $u);

    if (ref $opts eq "HASH") {
        $verify = $opts->{'verify'};
        $u = $opts->{'u'};
    } elsif ($opts) {
        $verify = 1;
        die "Bogus second arg to LJ::S2::get_style" if ref $opts;
    }

    if (ref $arg) {
        $u = $arg;
        $styleid = $u->prop('s2_style');
    } else {
        $styleid = $arg + 0;
    }

    my %style;
    my $have_style = 0;

    if ($verify && $styleid) {
        my $dbr = LJ::S2::get_s2_reader();
        my $style = $dbr->selectrow_hashref("SELECT * FROM s2styles WHERE styleid=$styleid");
        if (! $style && $u) {
            delete $u->{'s2_style'};
            $styleid = 0;
        }
    }

    if ($styleid) {
        my $stylay = $u ?
            LJ::S2::get_style_layers($u, $styleid) :
            LJ::S2::get_style_layers($styleid);
        while (my ($t, $id) = each %$stylay) { $style{$t} = $id; }
        $have_style = scalar %style;
    }

    # this is a hack to add remapping support for s2lids
    # - if a layerid is loaded above but it has a remapping
    #   defined in ljconfig, use the remap id instead and
    #   also save to database using set_style_layers
    if (%LJ::S2LID_REMAP) {
        my @remaps = ();

        # all system layer types (no user layers)
        foreach (qw(core i18nc i18n layout theme)) {
            my $lid = $style{$_};
            if (exists $LJ::S2LID_REMAP{$lid}) {
                $style{$_} = $LJ::S2LID_REMAP{$lid};
                push @remaps, "$lid=>$style{$_}";
            }
        }
        if (@remaps) {
            my $sysid = LJ::get_userid("system");
            LJ::statushistory_add($u, $sysid, 's2lid_remap', join(", ", @remaps));
            LJ::S2::set_style_layers($u, $styleid, %style);
        }
    }

    unless ($have_style) {
        my $public = get_public_layers();
        while (my ($layer, $name) = each %$LJ::DEFAULT_STYLE) {
            next unless $name ne "";
            next unless $public->{$name};
            my $id = $public->{$name}->{'s2lid'};
            $style{$layer} = $id if $id;
        }
    }

    return %style;
}

sub s2_context
{
    my $r = shift;
    my $styleid = shift;
    my $opts = shift || {};

    my $u = $opts->{u};
    my $style_u = $opts->{style_u} || $u;

    # but it doesn't matter if we're using the minimal style ...
    my %style;
    eval {
        my $r = Apache->request;
        if ($r->notes('use_minimal_scheme')) {
            my $public = get_public_layers();
            while (my ($layer, $name) = each %LJ::MINIMAL_STYLE) {
                next unless $name ne "";
                next unless $public->{$name};
                my $id = $public->{$name}->{'s2lid'};
                $style{$layer} = $id if $id;
            }
        }
    };

    # styleid of "s1short" is special in that it makes a
    # dynamically-created s2 context
    if ($styleid eq "s1short") {
        %style = s1_shortcomings_style($u);
    }

    # fall back to the standard call to get a user's styles
    unless (%style) {
        %style = $u ? get_style($styleid, { 'u' => $style_u }) : get_style($styleid);
    }

    my @layers;
    foreach (qw(core i18nc layout i18n theme user)) {
        push @layers, $style{$_} if $style{$_};
    }

    # TODO: memcache this.  only make core S2 (which uses the DB) load
    # when we can't get all the s2compiled stuff from memcache.
    # compare s2styles.modtime with s2compiled.comptime to see if memcache
    # version is accurate or not.
    my $dbr = LJ::S2::get_s2_reader();
    my $modtime = LJ::S2::load_layers(@layers);

    # check that all critical layers loaded okay from the database, otherwise
    # fall back to default style.  if i18n/theme/user were deleted, just proceed.
    my $okay = 1;
    foreach (qw(core layout)) {
        next unless $style{$_};
        $okay = 0 unless S2::layer_loaded($style{$_});
    }
    unless ($okay) {
        # load the default style instead, if we just tried to load a real one and failed
        if ($styleid) { return s2_context($r, 0, $opts); }

        # were we trying to load the default style?
        $r->content_type("text/html");
        $r->send_http_header();
        $r->print("<b>Error preparing to run:</b> One or more layers required to load the stock style have been deleted.");
        return undef;
    }

    if ($opts->{'use_modtime'})
    {
        my $ims = $r->header_in("If-Modified-Since");
        my $ourtime = LJ::time_to_http($modtime);
        if ($ims eq $ourtime) {
            # 304 return; unload non-public layers
            LJ::S2::cleanup_layers(@layers);
            $r->status_line("304 Not Modified");
            $r->send_http_header();
            return undef;
        } else {
            $r->header_out("Last-Modified", $ourtime);
        }
    }

    my $ctx;
    eval {
        $ctx = S2::make_context(@layers);
    };

    if ($ctx) {
        # let's use the scratch field as a hashref
        $ctx->[S2::SCRATCH] ||= {};

        LJ::S2::populate_system_props($ctx);
        S2::set_output(sub {});  # printing suppressed
        S2::set_output_safe(sub {});
        eval { S2::run_code($ctx, "prop_init()"); };
        escape_all_props($ctx, \@layers);

        return $ctx unless $@;
    }

    # failure to generate context; unload our non-public layers
    LJ::S2::cleanup_layers(@layers);

    my $err = $@;
    $r->content_type("text/html");
    $r->send_http_header();
    $r->print("<b>Error preparing to run:</b> $err");
    return undef;

}

sub escape_all_props {
    my ($ctx, $lids) = @_;

    foreach my $lid (@$lids) {
        foreach my $pname (S2::get_property_names($lid)) {
            next unless $ctx->[S2::PROPS]{$pname};

            my $prop = S2::get_property($lid, $pname);
            my $mode = $prop->{string_mode} || "plain";
            escape_prop_value($ctx->[S2::PROPS]{$pname}, $mode);
        }
    }
}

{
    my $css_cleaner = LJ::CSS::Cleaner->new();

    sub escape_prop_value {
        my $mode = $_[1];

        # This function modifies its first parameter in place.

        if (ref $_[0] eq 'ARRAY') {
            for (my $i = 0; $i < scalar(@{$_[0]}); $i++) {
                escape_prop_value($_[0][$i], $mode);
            }
        }
        elsif (ref $_[0] eq 'HASH') {
            foreach my $k (keys %{$_[0]}) {
                escape_prop_value($_[0]{$k}, $mode);
            }
        }
        elsif (! ref $_[0]) {
            if ($mode eq 'simple-html' || $mode eq 'simple-html-oneline') {
                LJ::CleanHTML::clean_subject(\$_[0]);
                $_[0] =~ s!\n!<br />!g if $mode eq 'simple-html';
            }
            elsif ($mode eq 'html' || $mode eq 'html-oneline') {
                LJ::CleanHTML::clean_event(\$_[0]);
                $_[0] =~ s!\n!<br />!g if $mode eq 'html';
            }
            elsif ($mode eq 'css') {
                my $clean = $css_cleaner->clean($_[0]);
                LJ::run_hook('css_cleaner_transform', \$clean);
                $_[0] = $clean;
            }
            elsif ($mode eq 'css-attrib') {
                if ($_[0] =~ /[\{\}]/) {
                    # If the string contains any { and } characters, it can't go in a style="" attrib
                    $_[0] = "/* bad CSS: can't use braces in a style attribute */";
                    return;
                }
                my $clean = $css_cleaner->clean_property($_[0]);
                $_[0] = $clean;
            }
            else { # plain
                $_[0] =~ s/</&lt;/g;
                $_[0] =~ s/>/&gt;/g;
                $_[0] =~ s!\n!<br />!g;
            }
        }
        else {
            $_[0] = undef; # Something's gone very wrong. Zzap the value completely.
        }
    }
}

sub s1_shortcomings_style {
    my $u = shift;
    my %style;

    my $public = get_public_layers();
    %style = (
              core => "core1",
              layout => "s1shortcomings/layout",
              );

    # convert the value names to s2layerid
    while (my ($layer, $name) = each %style) {
        next unless $public->{$name};
        my $id = $public->{$name}->{'s2lid'};
        $style{$layer} = $id;
    }

    return %style;
}

# parameter is either a single context, or just a bunch of layerids
# will then unregister the non-public layers
sub cleanup_layers {
    my $pub = get_public_layers();
    my @unload = ref $_[0] ? S2::get_layers($_[0]) : @_;
    S2::unregister_layer($_) foreach grep { ! $pub->{$_} } @unload;
}

sub clone_layer
{
    die "LJ::S2::clone_layer() has not been ported to use s2compiled2, but this function is not currently in use anywhere; if you use this function, please update it to use s2compiled2.\n";

    my $id = shift;
    return 0 unless $id;

    my $dbh = LJ::get_db_writer();
    my $r;

    $r = $dbh->selectrow_hashref("SELECT * FROM s2layers WHERE s2lid=?", undef, $id);
    return 0 unless $r;
    $dbh->do("INSERT INTO s2layers (b2lid, userid, type) VALUES (?,?,?)",
             undef, $r->{'b2lid'}, $r->{'userid'}, $r->{'type'});
    my $newid = $dbh->{'mysql_insertid'};
    return 0 unless $newid;

    foreach my $t (qw(s2compiled s2info s2source)) {
        $r = $dbh->selectrow_hashref("SELECT * FROM $t WHERE s2lid=?", undef, $id);
        next unless $r;
        $r->{'s2lid'} = $newid;

        # kinda hacky:  we have to update the layer id
        if ($t eq "s2compiled") {
            $r->{'compdata'} =~ s/\$_LID = (\d+)/\$_LID = $newid/;
        }

        $dbh->do("INSERT INTO $t (" . join(',', keys %$r) . ") VALUES (".
                 join(',', map { $dbh->quote($_) } values %$r) . ")");
    }

    return $newid;
}

sub create_style
{
    my ($u, $name, $cloneid) = @_;

    my $dbh = LJ::get_db_writer();
    return 0 unless $dbh && $u->writer;

    my $uid = $u->{userid} + 0
        or return 0;

    my $clone;
    $clone = load_style($cloneid) if $cloneid;

    # can't clone somebody else's style
    return 0 if $clone && $clone->{'userid'} != $uid;

    # can't create name-less style
    return 0 unless $name =~ /\S/;

    $dbh->do("INSERT INTO s2styles (userid, name, modtime) VALUES (?,?, UNIX_TIMESTAMP())",
             undef, $u->{'userid'}, $name);
    my $styleid = $dbh->{'mysql_insertid'};
    return 0 unless $styleid;

    if ($clone) {
        $clone->{'layer'}->{'user'} =
            LJ::clone_layer($clone->{'layer'}->{'user'});

        my $values;
        foreach my $ly ('core','i18nc','layout','theme','i18n','user') {
            next unless $clone->{'layer'}->{$ly};
            $values .= "," if $values;
            $values .= "($uid, $styleid, '$ly', $clone->{'layer'}->{$ly})";
        }
        $u->do("REPLACE INTO s2stylelayers2 (userid, styleid, type, s2lid) ".
               "VALUES $values") if $values;
    }

    return $styleid;
}

sub load_user_styles
{
    my $u = shift;
    my $opts = shift;
    return undef unless $u;

    my $dbr = LJ::S2::get_s2_reader();

    my %styles;
    my $load_using = sub {
        my $db = shift;
        my $sth = $db->prepare("SELECT styleid, name FROM s2styles WHERE userid=?");
        $sth->execute($u->{'userid'});
        while (my ($id, $name) = $sth->fetchrow_array) {
            $styles{$id} = $name;
        }
    };
    $load_using->($dbr);
    return \%styles if scalar(%styles) || ! $opts->{'create_default'};

    # create a new default one for them, but first check to see if they
    # have one on the master.
    my $dbh = LJ::get_db_writer();
    $load_using->($dbh);
    return \%styles if %styles;

    $dbh->do("INSERT INTO s2styles (userid, name, modtime) VALUES (?,?, UNIX_TIMESTAMP())", undef,
             $u->{'userid'}, $u->{'user'});
    my $styleid = $dbh->{'mysql_insertid'};
    return { $styleid => $u->{'user'} };
}

sub delete_user_style
{
    my ($u, $styleid) = @_;
    return 1 unless $styleid;
    my $dbh = LJ::get_db_writer();
    return 0 unless $dbh && $u->writer;

    my $style = load_style($dbh, $styleid);
    delete_layer($style->{'layer'}->{'user'});

    foreach my $t (qw(s2styles s2stylelayers)) {
        $dbh->do("DELETE FROM $t WHERE styleid=?", undef, $styleid)
    }
    $u->do("DELETE FROM s2stylelayers2 WHERE userid=? AND styleid=?", undef,
           $u->{userid}, $styleid);

    return 1;
}

sub load_style
{
    my $db = ref $_[0] ? shift : undef;
    my $id = shift;
    return undef unless $id;

    my $memkey = [$id, "s2s:$id"];
    my $style = LJ::MemCache::get($memkey);
    unless ($style) {
        $db ||= LJ::S2::get_s2_reader();
        $style = $db->selectrow_hashref("SELECT styleid, userid, name, modtime ".
                                        "FROM s2styles WHERE styleid=?",
                                        undef, $id);
        LJ::MemCache::add($memkey, $style, 3600);
    }
    return undef unless $style;

    my $u = LJ::load_userid($style->{userid})
        or return undef;

    $style->{'layer'} = LJ::S2::get_style_layers($u, $id) || {};

    return $style;
}

sub create_layer
{
    my ($userid, $b2lid, $type) = @_;
    $userid = LJ::want_userid($userid);

    return 0 unless $b2lid;  # caller should ensure b2lid exists and is of right type
    return 0 unless
        $type eq "user" || $type eq "i18n" || $type eq "theme" ||
        $type eq "layout" || $type eq "i18nc" || $type eq "core";

    my $dbh = LJ::get_db_writer();
    return 0 unless $dbh;

    $dbh->do("INSERT INTO s2layers (b2lid, userid, type) ".
             "VALUES (?,?,?)", undef, $b2lid, $userid, $type);
    return $dbh->{'mysql_insertid'};
}

# takes optional $u as first argument... if user argument is specified, will
# look through s2stylelayers and delete all mappings that this user has to
# this particular layer.
sub delete_layer
{
    my $u = LJ::isu($_[0]) ? shift : undef;
    my $lid = shift;
    return 1 unless $lid;
    my $dbh = LJ::get_db_writer();
    foreach my $t (qw(s2layers s2compiled s2info s2source s2checker)) {
        $dbh->do("DELETE FROM $t WHERE s2lid=?", undef, $lid);
    }

    # make sure we have a user object if possible
    unless ($u) {
        my $us = LJ::S2::get_layer_owners($lid);
        $u = $us->{$lid} if $us->{$lid};
    }

    # delete s2compiled2 if this is a layer owned by someone other than system
    if ($u && $u->{user} ne 'system') {
        $u->do("DELETE FROM s2compiled2 WHERE userid = ? AND s2lid = ?",
               undef, $u->{userid}, $lid);
    }

    # now clear memcache of the compiled data
    LJ::MemCache::delete([ $lid, "s2c:$lid" ]);

    # now delete the mappings for this particular layer
    if ($u) {
        my $styles = LJ::S2::load_user_styles($u);
        my @ids = keys %{$styles || {}};
        if (@ids) {
            # map in the ids we got from the user's styles and clear layers referencing
            # this particular layer id
            my $in = join(',', map { $_ + 0 } @ids);
            $dbh->do("DELETE FROM s2stylelayers WHERE styleid IN ($in) AND s2lid = ?",
                     undef, $lid);

            $u->do("DELETE FROM s2stylelayers2 WHERE userid=? AND styleid IN ($in) AND s2lid = ?",
                   undef, $u->{userid}, $lid);

            # now clean memcache so this change is immediately visible
            LJ::MemCache::delete([ $_, "s2sl:$_" ]) foreach @ids;
        }
    }

    return 1;
}

sub get_style_layers
{
    my $u = LJ::isu($_[0]) ? shift : undef;
    my ($styleid, $force) = @_;
    return undef unless $styleid;

    # check memcache unless $force
    my $stylay = undef;
    my $memkey = [$styleid, "s2sl:$styleid"];
    $stylay = LJ::MemCache::get($memkey) unless $force;
    return $stylay if $stylay;

    unless ($u) {
        my $sty = LJ::S2::load_style($styleid) or
            die "couldn't load styleid $styleid";
        $u = LJ::load_userid($sty->{userid}) or
            die "couldn't load userid $sty->{userid} for styleid $styleid";
    }

    my %stylay;

    my $fetch = sub {
        my ($db, $qry, @args) = @_;

        my $sth = $db->prepare($qry);
        $sth->execute(@args);
        die "ERROR: " . $sth->errstr if $sth->err;
        while (my ($type, $s2lid) = $sth->fetchrow_array) {
            $stylay{$type} = $s2lid;
        }
        return 0 unless %stylay;
        return 1;
    };

    unless ($fetch->($u, "SELECT type, s2lid FROM s2stylelayers2 " .
                     "WHERE userid=? AND styleid=?", $u->{userid}, $styleid)) {
        my $dbh = LJ::get_db_writer();
        if ($fetch->($dbh, "SELECT type, s2lid FROM s2stylelayers WHERE styleid=?",
                     $styleid)) {
            LJ::S2::set_style_layers_raw($u, $styleid, %stylay);
        }
    }

    # set in memcache
    LJ::MemCache::set($memkey, \%stylay);
    return \%stylay;
}

# the old interfaces.  handles merging with global database data if necessary.
sub set_style_layers
{
    my ($u, $styleid, %newlay) = @_;
    my $dbh = LJ::get_db_writer();
    return 0 unless $dbh && $u->writer;

    my @lay = ('core','i18nc','layout','theme','i18n','user');
    my %need = map { $_, 1 } @lay;
    delete $need{$_} foreach keys %newlay;
    if (%need) {
        # see if the needed layers are already on the user cluster
        my ($sth, $t, $lid);

        $sth = $u->prepare("SELECT type FROM s2stylelayers2 WHERE userid=? AND styleid=?");
        $sth->execute($u->{'userid'}, $styleid);
        while (($t) = $sth->fetchrow_array) {
            delete $need{$t};
        }

        # if we still don't have everything, see if they exist on the
        # global cluster, and we'll merge them into the %newlay being
        # posted, so they end up on the user cluster
        if (%need) {
            $sth = $dbh->prepare("SELECT type, s2lid FROM s2stylelayers WHERE styleid=?");
            $sth->execute($styleid);
            while (($t, $lid) = $sth->fetchrow_array) {
                $newlay{$t} = $lid;
            }
        }
    }

    set_style_layers_raw($u, $styleid, %newlay);
}

# just set in user cluster, not merging with global
sub set_style_layers_raw {
    my ($u, $styleid, %newlay) = @_;
    my $dbh = LJ::get_db_writer();
    return 0 unless $dbh && $u->writer;

    $u->do("REPLACE INTO s2stylelayers2 (userid,styleid,type,s2lid) VALUES ".
           join(",", map { sprintf("(%d,%d,%s,%d)", $u->{userid}, $styleid,
                                   $dbh->quote($_), $newlay{$_}) }
                keys %newlay));
    return 0 if $u->err;

    $dbh->do("UPDATE s2styles SET modtime=UNIX_TIMESTAMP() WHERE styleid=?",
             undef, $styleid);

    # delete memcache key
    LJ::MemCache::delete([$styleid, "s2sl:$styleid"]);
    LJ::MemCache::delete([$styleid, "s2s:$styleid"]);

    return 1;
}

sub load_layer
{
    my $db = ref $_[0] ? shift : LJ::S2::get_s2_reader();
    my $lid = shift;

    return $db->selectrow_hashref("SELECT s2lid, b2lid, userid, type ".
                                  "FROM s2layers WHERE s2lid=?", undef,
                                  $lid);
}

sub populate_system_props
{
    my $ctx = shift;
    $ctx->[S2::PROPS]->{'SITEROOT'} = $LJ::SITEROOT;
    $ctx->[S2::PROPS]->{'PALIMGROOT'} = $LJ::PALIMGROOT;
    $ctx->[S2::PROPS]->{'SITENAME'} = $LJ::SITENAME;
    $ctx->[S2::PROPS]->{'SITENAMESHORT'} = $LJ::SITENAMESHORT;
    $ctx->[S2::PROPS]->{'SITENAMEABBREV'} = $LJ::SITENAMEABBREV;
    $ctx->[S2::PROPS]->{'IMGDIR'} = $LJ::IMGPREFIX;
    $ctx->[S2::PROPS]->{'STATDIR'} = $LJ::STATPREFIX;
}

sub layer_compile_user
{
    my ($layer, $overrides) = @_;
    my $dbh = LJ::get_db_writer();
    return 0 unless ref $layer;
    return 0 unless $layer->{'s2lid'};
    return 1 unless ref $overrides;
    my $id = $layer->{'s2lid'};
    my $s2 = "layerinfo \"type\" = \"user\";\n";
    $s2 .= "layerinfo \"name\" = \"Auto-generated Customizations\";\n";

    foreach my $name (keys %$overrides) {
        next if $name =~ /\W/;
        my $prop = $overrides->{$name}->[0];
        my $val = $overrides->{$name}->[1];
        if ($prop->{'type'} eq "int") {
            $val = int($val);
        } elsif ($prop->{'type'} eq "bool") {
            $val = $val ? "true" : "false";
        } else {
            $val =~ s/[\\\$\"]/\\$&/g;
            $val = "\"$val\"";
        }
        $s2 .= "set $name = $val;\n";
    }

    my $error;
    return 1 if LJ::S2::layer_compile($layer, \$error, { 's2ref' => \$s2 });
    return LJ::error($error);
}

sub layer_compile
{
    my ($layer, $err_ref, $opts) = @_;
    my $dbh = LJ::get_db_writer();

    my $lid;
    if (ref $layer eq "HASH") {
        $lid = $layer->{'s2lid'}+0;
    } else {
        $lid = $layer+0;
        $layer = LJ::S2::load_layer($dbh, $lid) or return 0;
    }
    return 0 unless $lid;

    # get checker (cached, or via compiling) for parent layer
    my $checker = get_layer_checker($layer);
    unless ($checker) {
        $$err_ref = "Error compiling parent layer.";
        return undef;
    }

    # do our compile (quickly, since we probably have the cached checker)
    my $s2ref = $opts->{'s2ref'};
    unless ($s2ref) {
        my $s2 = $dbh->selectrow_array("SELECT s2code FROM s2source WHERE s2lid=?", undef, $lid);
        unless ($s2) { $$err_ref = "No source code to compile.";  return undef; }
        $s2ref = \$s2;
    }

    my $is_system = $layer->{'userid'} == LJ::get_userid("system");
    my $untrusted = ! $LJ::S2_TRUSTED{$layer->{'userid'}} && ! $is_system;

    # system writes go to global.  otherwise to user clusters.
    my $dbcm;
    if ($is_system) {
        $dbcm = $dbh;
    } else {
        my $u = LJ::load_userid($layer->{'userid'});
        $dbcm = $u;
    }
    return 0 unless $dbcm;

    my $compiled;
    my $cplr = S2::Compiler->new({ 'checker' => $checker });
    eval {
        $cplr->compile_source({
            'type' => $layer->{'type'},
            'source' => $s2ref,
            'output' => \$compiled,
            'layerid' => $lid,
            'untrusted' => $untrusted,
            'builtinPackage' => "S2::Builtin::LJ",
        });
    };
    if ($@) { $$err_ref = "Compile error: $@"; return undef; }

    # save the source, since it at least compiles
    if ($opts->{'s2ref'}) {
        $dbh->do("REPLACE INTO s2source (s2lid, s2code) VALUES (?,?)",
                 undef, $lid, ${$opts->{'s2ref'}}) or return 0;
    }

    # save the checker object for later
    if ($layer->{'type'} eq "core" || $layer->{'type'} eq "layout") {
        $checker->cleanForFreeze();
        my $chk_frz = Storable::freeze($checker);
        LJ::text_compress(\$chk_frz);
        $dbh->do("REPLACE INTO s2checker (s2lid, checker) VALUES (?,?)", undef,
                 $lid, $chk_frz) or die "replace into s2checker (lid = $lid)";
    }

    # load the compiled layer to test it loads and then get layerinfo/etc from it
    S2::unregister_layer($lid);
    eval $compiled;
    if ($@) { $$err_ref = "Post-compilation error: $@"; return undef; }
    if ($opts->{'redist_uniq'}) {
        # used by update-db loader:
        my $redist_uniq = S2::get_layer_info($lid, "redist_uniq");
        die "redist_uniq value of '$redist_uniq' doesn't match $opts->{'redist_uniq'}\n"
            unless $redist_uniq eq $opts->{'redist_uniq'};
    }

    # put layerinfo into s2info
    my %info = S2::get_layer_info($lid);
    my $values;
    my $notin;
    foreach (keys %info) {
        $values .= "," if $values;
        $values .= sprintf("(%d, %s, %s)", $lid,
                           $dbh->quote($_), $dbh->quote($info{$_}));
        $notin .= "," if $notin;
        $notin .= $dbh->quote($_);
    }
    if ($values) {
        $dbh->do("REPLACE INTO s2info (s2lid, infokey, value) VALUES $values")
            or die "replace into s2info (values = $values)";
        $dbh->do("DELETE FROM s2info WHERE s2lid=? AND infokey NOT IN ($notin)", undef, $lid);
    }
    if ($opts->{'layerinfo'}) {
        ${$opts->{'layerinfo'}} = \%info;
    }

    # put compiled into database, with its ID number
    if ($is_system) {
        $dbh->do("REPLACE INTO s2compiled (s2lid, comptime, compdata) ".
                 "VALUES (?, UNIX_TIMESTAMP(), ?)", undef, $lid, $compiled) or die "replace into s2compiled (lid = $lid)";
    } else {
        my $gzipped = LJ::text_compress($compiled);
        $dbcm->do("REPLACE INTO s2compiled2 (userid, s2lid, comptime, compdata) ".
                  "VALUES (?, ?, UNIX_TIMESTAMP(), ?)", undef,
                  $layer->{'userid'}, $lid, $gzipped) or die "replace into s2compiled2 (lid = $lid)";

        # delete from memcache; we can't store since we don't know the exact comptime
        LJ::MemCache::delete([ $lid, "s2c:$lid" ]);
    }

    # caller might want the compiled source
    if (ref $opts->{'compiledref'} eq "SCALAR") {
        ${$opts->{'compiledref'}} = $compiled;
    }

    S2::unregister_layer($lid);
    return 1;
}

sub get_layer_checker
{
    my $lay = shift;
    my $err_ref = shift;
    return undef unless ref $lay eq "HASH";
    return S2::Checker->new() if $lay->{'type'} eq "core";
    my $parid = $lay->{'b2lid'}+0 or return undef;
    my $dbh = LJ::get_db_writer();

    my $get_cached = sub {
        my $frz = $dbh->selectrow_array("SELECT checker FROM s2checker WHERE s2lid=?",
                                        undef, $parid) or return undef;
        LJ::text_uncompress(\$frz);
        return Storable::thaw($frz); # can be undef, on failure
    };

    # the good path
    my $checker = $get_cached->();
    return $checker if $checker;

    # no cached checker (or bogus), so we have to [re]compile to get it
    my $parlay = LJ::S2::load_layer($dbh, $parid);
    return undef unless LJ::S2::layer_compile($parlay);
    return $get_cached->();
}

sub load_layer_info
{
    my ($outhash, $listref) = @_;
    return 0 unless ref $listref eq "ARRAY";
    return 1 unless @$listref;
    my $in = join(',', map { $_+0 } @$listref);
    my $dbr = LJ::S2::get_s2_reader();
    my $sth = $dbr->prepare("SELECT s2lid, infokey, value FROM s2info WHERE ".
                            "s2lid IN ($in)");
    $sth->execute;
    while (my ($id, $k, $v) = $sth->fetchrow_array) {
        $outhash->{$id}->{$k} = $v;
    }
    return 1;
}

sub get_layout_langs
{
    my $src = shift;
    my $layid = shift;
    my %lang;
    foreach (keys %$src) {
        next unless /^\d+$/;
        my $v = $src->{$_};
        next unless $v->{'langcode'};
        $lang{$v->{'langcode'}} = $src->{$_}
            if ($v->{'type'} eq "i18nc" ||
                ($v->{'type'} eq "i18n" && $layid && $v->{'b2lid'} == $layid));
    }
    return map { $_, $lang{$_}->{'name'} } sort keys %lang;
}

# returns array of hashrefs
sub get_layout_themes
{
    my $src = shift; $src = [ $src ] unless ref $src eq "ARRAY";
    my $layid = shift;
    my @themes;
    foreach my $src (@$src) {
        foreach (sort { $src->{$a}->{'name'} cmp $src->{$b}->{'name'} } keys %$src) {
            next unless /^\d+$/;
            my $v = $src->{$_};
            $v->{b2layer} = $src->{$src->{$_}->{b2lid}}; # include layout information
            push @themes, $v if
                ($v->{'type'} eq "theme" && $layid && $v->{'b2lid'} == $layid);
        }
    }
    return @themes;
}

# src, layid passed to get_layout_themes; u is optional
sub get_layout_themes_select
{
    my ($src, $layid, $u) = @_;
    my (@sel, $last_uid, $text, $can_use_layer, $layout_allowed);

    foreach my $t (get_layout_themes($src, $layid)) {
        # themes should be shown but disabled if you can't use the layout
        unless (defined $layout_allowed) {
            if (defined $u && $t->{b2layer} && $t->{b2layer}->{uniq}) {
                $layout_allowed = LJ::S2::can_use_layer($u, $t->{b2layer}->{uniq});
            } else {
                # if no parent layer information, or no uniq (user style?),
                # then just assume it's allowed
                $layout_allowed = 1;
            }
        }

        $text = $t->{name};
        $can_use_layer = $layout_allowed &&
                         (! defined $u || LJ::S2::can_use_layer($u, $t->{uniq})); # if no u, accept theme; else check policy
        $text = "$text*" unless $can_use_layer;

        if ($last_uid && $t->{userid} != $last_uid) {
            push @sel, 0, '---';  # divider between system & user
        }
        $last_uid = $t->{userid};

        # these are passed to LJ::html_select which can take hashrefs
        push @sel, { 
            value => $t->{s2lid},
            text => $text,
            disabled => ! $can_use_layer,
        };
    }

    return @sel;
}

sub get_policy
{
    return $LJ::S2::CACHE_POLICY if $LJ::S2::CACHE_POLICY;
    my $policy = {};

    # localize $_ so that the while (<P>) below doesn't clobber it and cause problems
    # in anybody that happens to be calling us
    local $_;

    foreach my $infix ("", "-local") {
        my $file = "$LJ::HOME/bin/upgrading/s2layers/policy${infix}.dat";
        my $layer = undef;
        open (P, $file) or next;
        while (<P>) {
            s/\#.*//;
            next unless /\S/;
            if (/^\s*layer\s*:\s*(\S+)\s*$/) {
                $layer = $1;
                next;
            }
            next unless $layer;
            s/^\s+//; s/\s+$//;
            my @words = split(/\s+/, $_);
            next unless $words[-1] eq "allow" || $words[-1] eq "deny";
            my $allow = $words[-1] eq "allow" ? 1 : 0;
            if ($words[0] eq "use" && @words == 2) {
                $policy->{$layer}->{'use'} = $allow;
            }
            if ($words[0] eq "props" && @words == 2) {
                $policy->{$layer}->{'props'} = $allow;
            }
            if ($words[0] eq "prop" && @words == 3) {
                $policy->{$layer}->{'prop'}->{$words[1]} = $allow;
            }
        }
    }

    return $LJ::S2::CACHE_POLICY = $policy;
}

sub can_use_layer
{
    my ($u, $uniq) = @_;  # $uniq = redist_uniq value
    return 1 if LJ::get_cap($u, "s2styles");
    return 1 if LJ::run_hook('s2_can_use_layer', {
        u => $u,
        uniq => $uniq,
    });
    my $pol = get_policy();
    my $can = 0;

    my @try = ($uniq =~ m!/layout$!) ?
              ('*', $uniq)           : # this is a layout
              ('*/themes', $uniq);     # this is probably a theme

    foreach (@try) {
        next unless defined $pol->{$_};
        next unless defined $pol->{$_}->{'use'};
        $can = $pol->{$_}->{'use'};
    }
    return $can;
}

sub can_use_prop
{
    my ($u, $uniq, $prop) = @_;  # $uniq = redist_uniq value
    return 1 if LJ::get_cap($u, "s2styles");
    return 1 if LJ::get_cap($u, "s2props");
    my $pol = get_policy();
    my $can = 0;
    my @layers = ('*');
    my $pub = get_public_layers();
    if ($pub->{$uniq} && $pub->{$uniq}->{'type'} eq "layout") {
        my $cid = $pub->{$uniq}->{'b2lid'};
        push @layers, $pub->{$cid}->{'uniq'} if $pub->{$cid};
    }
    push @layers, $uniq;
    foreach my $lay (@layers) {
        foreach my $it ('props', 'prop') {
            if ($it eq "props" && defined $pol->{$lay}->{'props'}) {
                $can = $pol->{$lay}->{'props'};
            }
            if ($it eq "prop" && defined $pol->{$lay}->{'prop'}->{$prop}) {
                $can = $pol->{$lay}->{'prop'}->{$prop};
            }
        }
    }
    return $can;
}

sub get_journal_day_counts
{
    my ($s2page) = @_;
    return $s2page->{'_day_counts'} if defined $s2page->{'_day_counts'};

    my $u = $s2page->{'_u'};
    my $counts = {};

    my $remote = LJ::get_remote();
    my $days = LJ::get_daycounts($u, $remote) or return {};
    foreach my $day (@$days) {
        $counts->{$day->[0]}->{$day->[1]}->{$day->[2]} = $day->[3];
    }
    return $s2page->{'_day_counts'} = $counts;
}

## S2 object constructors

sub CommentInfo
{
    my $opts = shift;
    $opts->{'_type'} = "CommentInfo";
    $opts->{'count'} += 0;
    return $opts;
}

sub Date
{
    my @parts = @_;
    my $dt = { '_type' => 'Date' };
    $dt->{'year'} = $parts[0]+0;
    $dt->{'month'} = $parts[1]+0;
    $dt->{'day'} = $parts[2]+0;
    $dt->{'_dayofweek'} = $parts[3];
    die "S2 Builtin Date() takes day of week 1-7, not 0-6"
        if defined $parts[3] && $parts[3] == 0;
    return $dt;
}

sub DateTime_unix
{
    my $time = shift;
    my @gmtime = gmtime($time);
    my $dt = { '_type' => 'DateTime' };
    $dt->{'year'} = $gmtime[5]+1900;
    $dt->{'month'} = $gmtime[4]+1;
    $dt->{'day'} = $gmtime[3];
    $dt->{'hour'} = $gmtime[2];
    $dt->{'min'} = $gmtime[1];
    $dt->{'sec'} = $gmtime[0];
    $dt->{'_dayofweek'} = $gmtime[6] + 1;
    return $dt;
}

sub DateTime_tz
{
    # timezone can be scalar timezone name, DateTime::TimeZone object, or LJ::User object
    my ($epoch, $timezone) = @_;
    return undef unless $timezone;

    if (ref $timezone eq "LJ::User") {
        $timezone = $timezone->prop("timezone");
        return undef unless $timezone;
    }

    my $dt = eval {
        DateTime->from_epoch(
                             epoch => $epoch,
                             time_zone => $timezone,
                             );
    };
    return undef unless $dt;

    my $ret = { '_type' => 'DateTime' };
    $ret->{'year'} = $dt->year;
    $ret->{'month'} = $dt->month;
    $ret->{'day'} = $dt->day;
    $ret->{'hour'} = $dt->hour;
    $ret->{'min'} = $dt->minute;
    $ret->{'sec'} = $dt->second;

    # DateTime.pm's dayofweek is 1-based/Mon-Sun, but S2's is 1-based/Sun-Sat,
    # so first we make DT's be 0-based/Sun-Sat, then shift it up to 1-based.
    $ret->{'_dayofweek'} = ($dt->day_of_week % 7) + 1;
    return $ret;
}

sub DateTime_parts
{
    my @parts = split(/\s+/, shift);
    my $dt = { '_type' => 'DateTime' };
    $dt->{'year'} = $parts[0]+0;
    $dt->{'month'} = $parts[1]+0;
    $dt->{'day'} = $parts[2]+0;
    $dt->{'hour'} = $parts[3]+0;
    $dt->{'min'} = $parts[4]+0;
    $dt->{'sec'} = $parts[5]+0;
    # the parts string comes from MySQL which has range 0-6,
    # but internally and to S2 we use 1-7.
    $dt->{'_dayofweek'} = $parts[6] + 1 if defined $parts[6];
    return $dt;
}

sub Tag
{
    my ($u, $kwid, $kw) = @_;
    return undef unless $u && $kwid && $kw;

    my $t = {
        _type => 'Tag',
        _id => $kwid,
        name => LJ::ehtml($kw),
        url => LJ::journal_base($u) . '/tag/' . LJ::eurl($kw),
    };

    return $t;
}

sub TagDetail
{
    my ($u, $kwid, $tag) = @_;
    return undef unless $u && $kwid && ref $tag eq 'HASH';

    my $t = {
        _type => 'TagDetail',
        _id => $kwid,
        name => LJ::ehtml($tag->{name}),
        url => LJ::journal_base($u) . '/tag/' . LJ::eurl($tag->{name}),
        use_count => $tag->{uses},
        visibility => $tag->{security_level},
    };

    my $sum = 0;
    $sum += $tag->{security}->{groups}->{$_}
        foreach keys %{$tag->{security}->{groups} || {}};
    $t->{security_counts}->{$_} = $tag->{security}->{$_}
        foreach qw(public private friends);
    $t->{security_counts}->{groups} = $sum;

    return $t;
}

sub Entry
{
    my ($u, $arg) = @_;
    my $e = {
        '_type' => 'Entry',
        'link_keyseq' => [ 'edit_entry', 'edit_tags' ],
        'metadata' => {},
    };
    foreach (qw(subject text journal poster new_day end_day
                comments userpic permalink_url itemid tags)) {
        $e->{$_} = $arg->{$_};
    }

    $e->{'tags'} ||= [];
    $e->{'time'} = DateTime_parts($arg->{'dateparts'});
    $e->{'system_time'} = DateTime_parts($arg->{'system_dateparts'});
    $e->{'depth'} = 0;  # Entries are always depth 0.  Comments are 1+.

    my $link_keyseq = $e->{'link_keyseq'};
    push @$link_keyseq, 'mem_add' unless $LJ::DISABLED{'memories'};
    push @$link_keyseq, 'tell_friend' unless $LJ::DISABLED{'tellafriend'};
    push @$link_keyseq, 'watch_comments' unless $LJ::DISABLED{'esn'};
    push @$link_keyseq, 'unwatch_comments' unless $LJ::DISABLED{'esn'};

    # Note: nav_prev and nav_next are not included in the keyseq anticipating
    #      that their placement relative to the others will vary depending on
    #      layout.

    if ($arg->{'security'} eq "public") {
        # do nothing.
    } elsif ($arg->{'security'} eq "usemask") {
        $e->{'security'} = "protected";
        $e->{'security_icon'} = Image_std("security-protected");
    } elsif ($arg->{'security'} eq "private") {
        $e->{'security'} = "private";
        $e->{'security_icon'} = Image_std("security-private");
    }

    my $p = $arg->{'props'};
    if ($p->{'current_music'}) {
        $e->{'metadata'}->{'music'} = $p->{'current_music'};
        LJ::CleanHTML::clean_subject(\$e->{'metadata'}->{'music'});
    }
    if (my $mid = $p->{'current_moodid'}) {
        my $theme = defined $arg->{'moodthemeid'} ? $arg->{'moodthemeid'} : $u->{'moodthemeid'};
        my %pic;
        $e->{'mood_icon'} = Image($pic{'pic'}, $pic{'w'}, $pic{'h'})
            if LJ::get_mood_picture($theme, $mid, \%pic);
        if (my $mood = LJ::mood_name($mid)) {
            $e->{'metadata'}->{'mood'} = $mood;
        }
    }
    if ($p->{'current_mood'}) {
        $e->{'metadata'}->{'mood'} = $p->{'current_mood'};
        LJ::CleanHTML::clean_subject(\$e->{'metadata'}->{'mood'});
    }

    if ($p->{'current_location'} || $p->{'current_coords'}) {
        my $loc = eval { LJ::Location->new(coords   => $p->{'current_coords'},
                                           location => $p->{'current_location'}) };
        $e->{'metadata'}->{'location'} = $loc->as_html_current if $loc;
    }

    # TODO: Populate this field more intelligently later, but for now this will
    #   hopefully disuade people from hardcoding logic like this into their S2
    #   layers when they do weird parsing/manipulation of the text member in
    #   untrusted layers.
    $e->{text_must_print_trusted} = 1 if $e->{text} =~ m!<(script|object|applet|embed)\b!i;

    return $e;
}

sub Friend
{
    my ($u) = @_;
    my $o = UserLite($u);
    $o->{'_type'} = "Friend";
    $o->{'bgcolor'} = S2::Builtin::LJ::Color__Color($u->{'bgcolor'});
    $o->{'fgcolor'} = S2::Builtin::LJ::Color__Color($u->{'fgcolor'});
    return $o;
}

sub Null
{
    my $type = shift;
    return {
        '_type' => $type,
        '_isnull' => 1,
    };
}

sub Page
{
    my ($u, $opts) = @_;
    my $styleid = $u->{'_s2styleid'} + 0;
    my $base_url = $u->{'_journalbase'};

    my $get = $opts->{'getargs'};
    my %args;
    foreach my $k (keys %$get) {
        my $v = $get->{$k};
        next unless $k =~ s/^\.//;
        $args{$k} = $v;
    }

    # get MAX(modtime of style layers)
    my $stylemodtime = S2::get_style_modtime($opts->{'ctx'});
    my $style = load_style($u->{'s2_style'});
    $stylemodtime = $style->{'modtime'} if $style->{'modtime'} > $stylemodtime;

    my $linkobj = LJ::Links::load_linkobj($u);
    my $linklist = [ map { UserLink($_) } @$linkobj ];

    my $p = {
        '_type' => 'Page',
        '_u' => $u,
        'view' => '',
        'args' => \%args,
        'journal' => User($u),
        'journal_type' => $u->{'journaltype'},
        'time' => DateTime_unix(time),
        'base_url' => $base_url,
        'stylesheet_url' => "$base_url/res/$styleid/stylesheet?$stylemodtime",
        'view_url' => {
            'recent'   => "$base_url/",
            'userinfo' => $u->profile_url,
            'archive'  => "$base_url/calendar",
            'friends'  => "$base_url/friends",
            'tags'     => "$base_url/tag",
        },
        'linklist' => $linklist,
        'views_order' => [ 'recent', 'archive', 'friends', 'userinfo' ],
        'global_title' =>  LJ::ehtml($u->{'journaltitle'} || $u->{'name'}),
        'global_subtitle' => LJ::ehtml($u->{'journalsubtitle'}),
        'head_content' => '',
        'data_link' => {},
        'data_links_order' => [],
    };

    if ($LJ::UNICODE && $opts && $opts->{'saycharset'}) {
        $p->{'head_content'} .= '<meta http-equiv="Content-Type" content="text/html; charset=' . $opts->{'saycharset'} . "\" />\n";
    }

    if (LJ::are_hooks('s2_head_content_extra')) {
        my $remote = LJ::get_remote();
        $p->{head_content} .= LJ::run_hook('s2_head_content_extra', $remote, $opts->{r});
    }

    # Automatic Discovery of RSS/Atom
    $p->{'head_content'} .= qq{<link rel="alternate" type="application/rss+xml" title="RSS" href="$p->{'base_url'}/data/rss" />\n};
    $p->{'head_content'} .= qq{<link rel="alternate" type="application/atom+xml" title="Atom" href="$p->{'base_url'}/data/atom" />\n};
    $p->{'head_content'} .= qq{<link rel="service.feed" type="application/atom+xml" title="AtomAPI-enabled feed" href="$LJ::SITEROOT/interface/atomapi/$u->{'user'}/feed" />\n};
    $p->{'head_content'} .= qq{<link rel="service.post" type="application/atom+xml" title="Create a new post" href="$LJ::SITEROOT/interface/atomapi/$u->{'user'}/post" />\n};

    # CSS for community promos
    $p->{'head_content'} .= qq{<link rel='stylesheet' href='$LJ::STATPREFIX/comm_promo.css' type='text/css' />\n};

    # Ads and control strip
    my $show_ad = LJ::run_hook('should_show_ad', {
        ctx  => "journal",
        user => $u->{user},
    });
    $p->{'head_content'} .= qq{<link rel='stylesheet' href='$LJ::STATPREFIX/ad_base.css' type='text/css' />\n} if $show_ad;

    my $show_control_strip = LJ::run_hook('show_control_strip', {
        user => $u->{user},
    });
    if ($show_control_strip) {
        LJ::run_hook('control_strip_stylesheet_link', {
            user => $u->{user},
        });
        $p->{'head_content'} .= LJ::control_strip_js_inject( user => $u->{user} );
    }

    # FOAF autodiscovery
    my $foafurl = $u->{external_foaf_url} ? LJ::eurl($u->{external_foaf_url}) : "$p->{base_url}/data/foaf";
    my $digest = Digest::SHA1::sha1_hex('mailto:' . $u->{email});
    $p->{head_content} .= qq{<link rel="meta" type="application/rdf+xml" title="FOAF" href="$foafurl" />\n};
    $p->{head_content} .= qq{<meta name="foaf:maker" content="foaf:mbox_sha1sum '$digest'" />\n};

    # Identity (type I) accounts only have friends views
    $p->{'views_order'} = [ 'friends', 'userinfo' ] if $u->{'journaltype'} eq 'I';

    return $p;
}

sub Link {
    my ($url, $caption, $icon) = @_;

    my $lnk = {
        '_type'   => 'Link',
        'caption' => $caption,
        'url'     => $url,
        'icon'    => $icon,
    };

    return $lnk;
}

sub Image
{
    my ($url, $w, $h, $alttext, %extra) = @_;
    return {
        '_type' => 'Image',
        'url' => $url,
        'width' => $w,
        'height' => $h,
        'alttext' => $alttext,
        'extra' => {%extra},
    };
}

sub Image_std
{
    my $name = shift;
    my $ctx = $LJ::S2::CURR_CTX or die "No S2 context available ";

    unless ($LJ::S2::RES_MADE++) {
        $LJ::S2::RES_CACHE = {
            'security-protected' => Image("$LJ::IMGPREFIX/icon_protected.gif", 14, 15, $ctx->[S2::PROPS]->{'text_icon_alt_protected'}),
            'security-private' => Image("$LJ::IMGPREFIX/icon_private.gif", 16, 16, $ctx->[S2::PROPS]->{'text_icon_alt_private'}),
        };
    }
    return $LJ::S2::RES_CACHE->{$name};
}

sub Image_userpic
{
    my ($u, $picid, $kw) = @_;

    $picid ||= LJ::get_picid_from_keyword($u, $kw);

    my $pi = LJ::get_userpic_info($u);
    my $p = $pi->{'pic'}->{$picid};

    return Null("Image") unless $p;
    return {
        '_type' => "Image",
        'url' => "$LJ::USERPIC_ROOT/$picid/$u->{'userid'}",
        'width' => $p->{'width'},
        'height' => $p->{'height'},
        'alttext' => "",
    };
}

sub ItemRange_fromopts
{
    my $opts = shift;
    my $ir = {};

    my $items = $opts->{'items'};
    my $page_size = ($opts->{'pagesize'}+0) || 25;
    my $page = $opts->{'page'}+0 || 1;
    my $num_items = scalar @$items;

    my $pages = POSIX::ceil($num_items / $page_size) || 1;
    if ($page > $pages) { $page = $pages; }

    splice(@$items, 0, ($page-1)*$page_size) if $page > 1;
    splice(@$items, $page_size) if @$items > $page_size;

    $ir->{'current'} = $page;
    $ir->{'total'} = $pages;
    $ir->{'total_subitems'} = $num_items;
    $ir->{'from_subitem'} = ($page-1) * $page_size + 1;
    $ir->{'num_subitems_displayed'} = @$items;
    $ir->{'to_subitem'} = $ir->{'from_subitem'} + $ir->{'num_subitems_displayed'} - 1;
    $ir->{'all_subitems_displayed'} = ($pages == 1);
    $ir->{'_url_of'} = $opts->{'url_of'};
    return ItemRange($ir);
}

sub ItemRange
{
    my $h = shift;  # _url_of = sub($n)
    $h->{'_type'} = "ItemRange";

    my $url_of = ref $h->{'_url_of'} eq "CODE" ? $h->{'_url_of'} : sub {"";};

    $h->{'url_next'} = $url_of->($h->{'current'} + 1)
        unless $h->{'current'} >= $h->{'total'};
    $h->{'url_prev'} = $url_of->($h->{'current'} - 1)
        unless $h->{'current'} <= 1;
    $h->{'url_first'} = $url_of->(1)
        unless $h->{'current'} == 1;
    $h->{'url_last'} = $url_of->($h->{'total'})
        unless $h->{'current'} == $h->{'total'};

    return $h;
}

sub User
{
    my ($u) = @_;
    my $o = UserLite($u);
    $o->{'_type'} = "User";
    $o->{'default_pic'} = Image_userpic($u, $u->{'defaultpicid'});
    $o->{'userpic_listing_url'} = "$LJ::SITEROOT/allpics.bml?user=".$u->{'user'};
    $o->{'website_url'} = LJ::ehtml($u->{'url'});
    $o->{'website_name'} = LJ::ehtml($u->{'urlname'});
    return $o;
}

sub UserLink
{
    my $link = shift; # hashref

    # a dash means pass to s2 as blank so it will just insert a blank line
    $link->{'title'} = '' if $link->{'title'} eq "-";

    return {
        '_type' => 'UserLink',
        'is_heading' => $link->{'url'} ? 0 : 1,
        'url' => LJ::ehtml($link->{'url'}),
        'title' => LJ::ehtml($link->{'title'}),
        'children' => $link->{'children'} || [], # TODO: implement parent-child relationships
    };
}

sub UserLite
{
    my ($u) = @_;
    my $o;
    return $o unless $u;

    $o = {
        '_type' => 'UserLite',
        '_u' => $u,
        'username' => LJ::ehtml($u->display_name),
        'name' => LJ::ehtml($u->{'name'}),
        'journal_type' => $u->{'journaltype'},
        'data_link' => {
            'foaf' => Link("$LJ::SITEROOT/users/" . LJ::ehtml($u->{'user'}) . '/data/foaf',
                           "FOAF",
                           Image("$LJ::IMGPREFIX/data_foaf.gif", 32, 15, "FOAF")),
        },
        'data_links_order' => [ "foaf" ],
        'link_keyseq' => [ ],
    };
    my $lks = $o->{link_keyseq};
    push @$lks, qw(add_friend post_entry todo memories);
    push @$lks, "tell_friend"  unless $LJ::DISABLED{'tellafriend'};
    push @$lks, "search"  unless $LJ::DISABLED{'offsite_journal_search'};
    push @$lks, "nudge"  unless $LJ::DISABLED{'nudge'};

    # TODO: Figure out some way to use the userinfo_linkele hook here?

    return $o;
}


###############

package S2::Builtin::LJ;
use strict;

sub UserLite {
    my ($ctx,$username) = @_;
    my $u = LJ::load_user($username);
    return LJ::S2::UserLite($u);
}

sub start_css {
    my ($ctx) = @_;
    my $sc = $ctx->[S2::SCRATCH];
    $sc->{_start_css_pout}   = S2::get_output();
    $sc->{_start_css_pout_s} = S2::get_output_safe();
    $sc->{_start_css_buffer} = "";
    my $printer = sub {
        $sc->{_start_css_buffer} .= shift;
    };
    S2::set_output($printer);
    S2::set_output_safe($printer);
}

sub end_css {
    my ($ctx) = @_;
    my $sc = $ctx->[S2::SCRATCH];

    # restore our printer/safe printer
    S2::set_output($sc->{_start_css_pout});
    S2::set_output_safe($sc->{_start_css_pout_s});

    # our CSS to clean:
    my $css = $sc->{_start_css_buffer};
    my $cleaner = LJ::CSS::Cleaner->new;

    my $clean = $cleaner->clean($css);
    LJ::run_hook('css_cleaner_transform', \$clean);

    $sc->{_start_css_pout}->("/* Cleaned CSS: */\n" .
                             $clean .
                             "\n");
}

sub alternate
{
    my ($ctx, $one, $two) = @_;

    my $scratch = $ctx->[S2::SCRATCH];

    $scratch->{alternate}{"$one\0$two"} = ! $scratch->{alternate}{"$one\0$two"};
    return $scratch->{alternate}{"$one\0$two"} ? $one : $two;
}

sub set_content_type
{
    my ($ctx, $type) = @_;

    die "set_content_type is not yet implemented";
    $ctx->[S2::SCRATCH]->{contenttype} = $type;
}

sub striphtml
{
    my ($ctx, $s) = @_;

    $s =~ s/<.*?>//g;
    return $s;
}

sub ehtml
{
    my ($ctx, $text) = @_;
    return LJ::ehtml($text);
}

sub eurl
{
    my ($ctx, $text) = @_;
    return LJ::eurl($text);
}

# escape tags only
sub etags {
    my ($ctx, $text) = @_;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    return $text;
}

# sanitize URLs
sub clean_url {
    my ($ctx, $text) = @_;
    unless ($text =~ m!^https?://[^\'\"\\]*$!) {
        $text = "";
    }
    return $text;
}

sub get_page
{
    return $LJ::S2::CURR_PAGE;
}

sub get_plural_phrase
{
    my ($ctx, $n, $prop) = @_;
    my $form = S2::run_function($ctx, "lang_map_plural(int)", $n);
    my $a = $ctx->[S2::PROPS]->{"_plurals_$prop"};
    unless (ref $a eq "ARRAY") {
        $a = $ctx->[S2::PROPS]->{"_plurals_$prop"} = [ split(m!\s*//\s*!, $ctx->[S2::PROPS]->{$prop}) ];
    }
    my $text = $a->[$form];

    # this fixes missing plural forms for russians (who have 2 plural forms)
    # using languages like english with 1 plural form
    $text = $a->[-1] unless defined $text;

    $text =~ s/\#/$n/;
    return LJ::ehtml($text);
}

sub get_url
{
    my ($ctx, $obj, $view) = @_;
    my $user;

    # now get data from one of two paths, depending on if we were given a UserLite
    # object or a string for the username, so make sure we have the username.
    if (ref $obj eq 'HASH') {
        $user = $obj->{username};
    } else {
        $user = $obj;
    }

    my $u = LJ::load_user($user);
    return "" unless $u;

    # construct URL to return
    $view = "profile" if $view eq "userinfo";
    $view = "calendar" if $view eq "archive";
    $view = "" if $view eq "recent";
    my $base = $u->journal_base;
    return "$base/$view";
}

sub htmlattr
{
    my ($ctx, $name, $value) = @_;
    return "" if $value eq "";
    $name = lc($name);
    return "" if $name =~ /[^a-z]/;
    return " $name=\"" . LJ::ehtml($value) . "\"";
}

sub rand
{
    my ($ctx, $aa, $bb) = @_;
    my ($low, $high);
    if (ref $aa eq "ARRAY") {
        ($low, $high) = (0, @$aa - 1);
    } elsif (! defined $bb) {
        ($low, $high) = (1, $aa);
    } else {
        ($low, $high) = ($aa, $bb);
    }
    return int(rand($high - $low + 1)) + $low;
}

sub viewer_logged_in
{
    my ($ctx) = @_;
    my $remote = LJ::get_remote();
    return defined $remote;
}

sub viewer_is_owner
{
    my ($ctx) = @_;
    my $remote = LJ::get_remote();
    return 0 unless $remote;
    return 0 unless defined($LJ::S2::CURR_PAGE);
    return $remote->{'userid'} == $LJ::S2::CURR_PAGE->{'_u'}->{'userid'};
}

sub viewer_is_friend
{
    my ($ctx) = @_;
    my $remote = LJ::get_remote();
    return 0 unless $remote;
    return 0 unless defined($LJ::S2::CURR_PAGE);

    my $ju = $LJ::S2::CURR_PAGE->{'_u'};
    return 0 if $ju->{journaltype} eq 'C';
    return LJ::is_friend($ju, $remote);
}

sub viewer_is_member
{
    my ($ctx) = @_;
    my $remote = LJ::get_remote();
    return 0 unless $remote;
    return 0 unless defined($LJ::S2::CURR_PAGE);

    my $ju = $LJ::S2::CURR_PAGE->{'_u'};
    return 0 if $ju->{journaltype} ne 'C';
    return LJ::is_friend($ju, $remote);
}

sub viewer_sees_control_strip
{
    return 0 unless $LJ::USE_CONTROL_STRIP;

    my $r = Apache->request;
    return LJ::run_hook('show_control_strip', {
        userid => $r->notes("journalid"),
    });
}

sub viewer_sees_vbox
{
    my $r = Apache->request;
    my $u = LJ::load_userid($r->notes("journalid"));
    return 0 unless $u;

    if (viewer_sees_ads() and ($u->prop('journal_box_placement') eq 'v' or $u->prop('journal_box_placement') eq '')) {
        return 1;
    }

    return $u->should_display_comm_promo ? 1 : 0;
}

sub viewer_sees_hbox_top
{
    my $r = Apache->request;
    my $u = LJ::load_userid($r->notes("journalid"));
    return 0 unless $u;

    if (viewer_sees_ads() and $u->prop('journal_box_placement') eq 'h') {
        return 1;
    }

    return 0;
}

sub viewer_sees_hbox_bottom
{
    my $r = Apache->request;
    my $u = LJ::load_userid($r->notes("journalid"));
    return 0 unless $u;

    return viewer_sees_ads();
}

sub viewer_sees_ads
{
    return 0 unless $LJ::USE_ADS;

    my $r = Apache->request;
    return LJ::run_hook('should_show_ad', {
        ctx  => 'journal',
        userid => $r->notes("journalid"),
    });
}

sub control_strip_logged_out_userpic_css
{
    my $r = Apache->request;
    my $u = LJ::load_userid($r->notes("journalid"));
    return '' unless $u;

    return LJ::run_hook('control_strip_userpic', $u);
}

sub weekdays
{
    my ($ctx) = @_;
    return [ 1..7 ];  # FIXME: make this conditionally monday first: [ 2..7, 1 ]
}

sub set_handler
{
    my ($ctx, $hook, $stmts) = @_;
    my $p = $LJ::S2::CURR_PAGE;
    return unless $hook =~ /^\w+\#?$/;
    $hook =~ s/\#$/ARG/;

    $S2::pout->("<script> function userhook_$hook () {\n");
    foreach my $st (@$stmts) {
        my ($cmd, @args) = @$st;

        my $get_domexp = sub {
            my $domid = shift @args;
            my $domexp = "";
            while ($domid ne "") {
                $domexp .= " + " if $domexp;
                if ($domid =~ s/^(\w+)//) {
                    $domexp .= "\"$1\"";
                } elsif ($domid =~ s/^\#//) {
                    $domexp .= "arguments[0]";
                } else {
                    return undef;
                }
            }
            return $domexp;
        };

        my $get_color = sub {
            my $color = shift @args;
            return undef unless
                $color =~ /^\#[0-9a-f]{3,3}$/ ||
                $color =~ /^\#[0-9a-f]{6,6}$/ ||
                $color =~ /^\w+$/ ||
                $color =~ /^rgb(\d+,\d+,\d+)$/;
            return $color;
        };

        #$S2::pout->("  // $cmd: @args\n");
        if ($cmd eq "style_bgcolor" || $cmd eq "style_color") {
            my $domexp = $get_domexp->();
            my $color = $get_color->();
            if ($domexp && $color) {
                $S2::pout->("setStyle($domexp, 'background', '$color');\n") if $cmd eq "style_bgcolor";
                $S2::pout->("setStyle($domexp, 'color', '$color');\n") if $cmd eq "style_color";
            }
        } elsif ($cmd eq "set_class") {
            my $domexp = $get_domexp->();
            my $class = shift @args;
            if ($domexp && $class =~ /^\w+$/) {
                $S2::pout->("setAttr($domexp, 'class', '$class');\n");
            }
        } elsif ($cmd eq "set_image") {
            my $domexp = $get_domexp->();
            my $url = shift @args;
            if ($url =~ m!^http://! && $url !~ /[\'\"\n\r]/) {
                $url = LJ::eurl($url);
                $S2::pout->("setAttr($domexp, 'src', \"$url\");\n");
            }
        }
    }
    $S2::pout->("} </script>\n");
}

sub zeropad
{
    my ($ctx, $num, $digits) = @_;
    $num += 0;
    $digits += 0;
    return sprintf("%0${digits}d", $num);
}
*int__zeropad = \&zeropad;

sub int__compare
{
    my ($ctx, $this, $other) = @_;
    return $other <=> $this;
}

sub Color__update_hsl
{
    my ($this, $force) = @_;
    return if $this->{'_hslset'}++;
    ($this->{'_h'}, $this->{'_s'}, $this->{'_l'}) =
        S2::Color::rgb_to_hsl($this->{'r'}, $this->{'g'}, $this->{'b'});
    $this->{$_} = int($this->{$_} * 255 + 0.5) foreach qw(_h _s _l);
}

sub Color__update_rgb
{
    my ($this) = @_;

    ($this->{'r'}, $this->{'g'}, $this->{'b'}) =
        S2::Color::hsl_to_rgb( map { $this->{$_} / 255 } qw(_h _s _l) );
    Color__make_string($this);
}

sub Color__make_string
{
    my ($this) = @_;
    $this->{'as_string'} = sprintf("\#%02x%02x%02x",
                                  $this->{'r'},
                                  $this->{'g'},
                                  $this->{'b'});
}

# public functions
sub Color__Color
{
    my ($s) = @_;
    $s =~ s/^\#//;
    $s =~ s/^(\w)(\w)(\w)$/$1$1$2$2$3$3/s;  #  'c30' => 'cc3300'
    return if $s =~ /[^a-fA-F0-9]/ || length($s) != 6;

    my $this = { '_type' => 'Color' };
    $this->{'r'} = hex(substr($s, 0, 2));
    $this->{'g'} = hex(substr($s, 2, 2));
    $this->{'b'} = hex(substr($s, 4, 2));
    $this->{$_} = $this->{$_} % 256 foreach qw(r g b);

    Color__make_string($this);
    return $this;
}

sub Color__clone
{
    my ($ctx, $this) = @_;
    return { %$this };
}

sub Color__set_hsl
{
    my ($this, $h, $s, $l) = @_;
    $this->{'_h'} = $h % 256;
    $this->{'_s'} = $s % 256;
    $this->{'_l'} = $l % 256;
    $this->{'_hslset'} = 1;
    Color__update_rgb($this);
}

sub Color__red {
    my ($ctx, $this, $r) = @_;
    if (defined $r) {
        $this->{'r'} = $r % 256;
        delete $this->{'_hslset'};
        Color__make_string($this);
    }
    $this->{'r'};
}

sub Color__green {
    my ($ctx, $this, $g) = @_;
    if (defined $g) {
        $this->{'g'} = $g % 256;
        delete $this->{'_hslset'};
        Color__make_string($this);
    }
    $this->{'g'};
}

sub Color__blue {
    my ($ctx, $this, $b) = @_;
    if (defined $b) {
        $this->{'b'} = $b % 256;
        delete $this->{'_hslset'};
        Color__make_string($this);
    }
    $this->{'b'};
}

sub Color__hue {
    my ($ctx, $this, $h) = @_;

    if (defined $h) {
        $this->{'_h'} = $h % 256;
        $this->{'_hslset'} = 1;
        Color__update_rgb($this);
    } elsif (! $this->{'_hslset'}) {
        Color__update_hsl($this);
    }
    $this->{'_h'};
}

sub Color__saturation {
    my ($ctx, $this, $s) = @_;
    if (defined $s) {
        $this->{'_s'} = $s % 256;
        $this->{'_hslset'} = 1;
        Color__update_rgb($this);
    } elsif (! $this->{'_hslset'}) {
        Color__update_hsl($this);
    }
    $this->{'_s'};
}

sub Color__lightness {
    my ($ctx, $this, $l) = @_;

    if (defined $l) {
        $this->{'_l'} = $l % 256;
        $this->{'_hslset'} = 1;
        Color__update_rgb($this);
    } elsif (! $this->{'_hslset'}) {
        Color__update_hsl($this);
    }

    $this->{'_l'};
}

sub Color__inverse {
    my ($ctx, $this) = @_;
    my $new = {
        '_type' => 'Color',
        'r' => 255 - $this->{'r'},
        'g' => 255 - $this->{'g'},
        'b' => 255 - $this->{'b'},
    };
    Color__make_string($new);
    return $new;
}

sub Color__average {
    my ($ctx, $this, $other) = @_;
    my $new = {
        '_type' => 'Color',
        'r' => int(($this->{'r'} + $other->{'r'}) / 2 + .5),
        'g' => int(($this->{'g'} + $other->{'g'}) / 2 + .5),
        'b' => int(($this->{'b'} + $other->{'b'}) / 2 + .5),
    };
    Color__make_string($new);
    return $new;
}

sub Color__blend {
    my ($ctx, $this, $other, $value) = @_;
    my $multiplier = $value / 100;
    my $new = {
        '_type' => 'Color',
        'r' => int($this->{'r'} - (($this->{'r'} - $other->{'r'}) * $multiplier) + .5),
        'g' => int($this->{'g'} - (($this->{'g'} - $other->{'g'}) * $multiplier) + .5),
        'b' => int($this->{'b'} - (($this->{'b'} - $other->{'b'}) * $multiplier) + .5),
    };
    Color__make_string($new);
    return $new;
}

sub Color__lighter {
    my ($ctx, $this, $amt) = @_;
    $amt = defined $amt ? $amt : 30;

    Color__update_hsl($this);

    my $new = {
        '_type' => 'Color',
        '_hslset' => 1,
        '_h' => $this->{'_h'},
        '_s' => $this->{'_s'},
        '_l' => ($this->{'_l'} + $amt > 255 ? 255 : $this->{'_l'} + $amt),
    };

    Color__update_rgb($new);
    return $new;
}

sub Color__darker {
    my ($ctx, $this, $amt) = @_;
    $amt = defined $amt ? $amt : 30;

    Color__update_hsl($this);

    my $new = {
        '_type' => 'Color',
        '_hslset' => 1,
        '_h' => $this->{'_h'},
        '_s' => $this->{'_s'},
        '_l' => ($this->{'_l'} - $amt < 0 ? 0 : $this->{'_l'} - $amt),
    };

    Color__update_rgb($new);
    return $new;
}

sub _Comment__get_link
{
    my ($ctx, $this, $key) = @_;
    my $page = get_page();
    my $u = $page->{'_u'};
    my $post_user = $page->{'entry'} ? $page->{'entry'}->{'poster'}->{'username'} : undef;
    my $com_user = $this->{'poster'} ? $this->{'poster'}->{'username'} : undef;
    my $remote = LJ::get_remote();
    my $null_link = { '_type' => 'Link', '_isnull' => 1 };

    if ($key eq "delete_comment") {
        return $null_link unless LJ::Talk::can_delete($remote, $u, $post_user, $com_user);
        return LJ::S2::Link("$LJ::SITEROOT/delcomment.bml?journal=$u->{'user'}&amp;id=$this->{'talkid'}",
                            $ctx->[S2::PROPS]->{"text_multiform_opt_delete"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_del.gif", 22, 20));
    }
    if ($key eq "freeze_thread") {
        return $null_link if $this->{'frozen'};
        return $null_link unless LJ::Talk::can_freeze($remote, $u, $post_user, $com_user);
        return LJ::S2::Link("$LJ::SITEROOT/talkscreen.bml?mode=freeze&amp;journal=$u->{'user'}&amp;talkid=$this->{'talkid'}",
                            $ctx->[S2::PROPS]->{"text_multiform_opt_freeze"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_freeze.gif", 22, 20));
    }
    if ($key eq "unfreeze_thread") {
        return $null_link unless $this->{'frozen'};
        return $null_link unless LJ::Talk::can_unfreeze($remote, $u, $post_user, $com_user);
        return LJ::S2::Link("$LJ::SITEROOT/talkscreen.bml?mode=unfreeze&amp;journal=$u->{'user'}&amp;talkid=$this->{'talkid'}",
                            $ctx->[S2::PROPS]->{"text_multiform_opt_unfreeze"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_unfreeze.gif", 22, 20));
    }
    if ($key eq "screen_comment") {
        return $null_link if $this->{'screened'};
        return $null_link unless LJ::Talk::can_screen($remote, $u, $post_user, $com_user);
        return LJ::S2::Link("$LJ::SITEROOT/talkscreen.bml?mode=screen&amp;journal=$u->{'user'}&amp;talkid=$this->{'talkid'}",
                            $ctx->[S2::PROPS]->{"text_multiform_opt_screen"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_scr.gif", 22, 20));
    }
    if ($key eq "unscreen_comment") {
        return $null_link unless $this->{'screened'};
        return $null_link unless LJ::Talk::can_unscreen($remote, $u, $post_user, $com_user);
        return LJ::S2::Link("$LJ::SITEROOT/talkscreen.bml?mode=unscreen&amp;journal=$u->{'user'}&amp;talkid=$this->{'talkid'}",
                            $ctx->[S2::PROPS]->{"text_multiform_opt_unscreen"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_unscr.gif", 22, 20));
    }
    if ($key eq "watch_thread" || $key eq "unwatch_thread" || $key eq "watching_parent") {
        return $null_link if $LJ::DISABLED{'esn'};
        return $null_link unless $remote && $remote->can_use_esn;

        my $comment = LJ::Comment->new($u, dtalkid => $this->{talkid});

        if ($key eq "unwatch_thread") {
            return $null_link unless $remote->has_subscription(journal => $u, event => "JournalNewComment", arg2 => $comment->jtalkid);

            return LJ::S2::Link("$LJ::SITEROOT/manage/subscriptions/comments.bml?journal=$u->{'user'}&amp;talkid=$this->{talkid}",
                                $ctx->[S2::PROPS]->{"text_multiform_opt_untrack"},
                                LJ::S2::Image("$LJ::IMGPREFIX/btn_tracking.gif", 22, 20));
        }

        return $null_link if $remote->has_subscription(journal => $u, event => "JournalNewComment", arg2 => $comment->jtalkid);

        # at this point, we know that the thread is either not being watched or its parent is being watched
        # in other words, the user is not subscribed to this particular comment

        # see if any parents are being watched
        my $watching_parent = 0;
        while ($comment && $comment->valid && $comment->parenttalkid) {
            # check cache
            $comment->{_watchedby} ||= {};
            my $thread_watched = $comment->{_watchedby}->{$u->{userid}};

            # not cached
            if (! defined $thread_watched) {
                $thread_watched = $remote->has_subscription(journal => $u, event => "JournalNewComment", arg2 => $comment->parenttalkid);
            }

            $watching_parent = 1 if ($thread_watched);

            # cache in this comment object if it's being watched by this user
            $comment->{_watchedby}->{$u->{userid}} = $thread_watched;

            $comment = $comment->parent;
        }

        if ($key eq "watch_thread" && !$watching_parent) {
            return LJ::S2::Link("$LJ::SITEROOT/manage/subscriptions/comments.bml?journal=$u->{'user'}&amp;talkid=$this->{talkid}",
                                $ctx->[S2::PROPS]->{"text_multiform_opt_track"},
                                LJ::S2::Image("$LJ::IMGPREFIX/btn_track.gif", 22, 20));
        }
        if ($key eq "watching_parent" && $watching_parent) {
            return LJ::S2::Link("$LJ::SITEROOT/manage/subscriptions/comments.bml?journal=$u->{'user'}&amp;talkid=$this->{talkid}",
                                $ctx->[S2::PROPS]->{"text_multiform_opt_track"},
                                LJ::S2::Image("$LJ::IMGPREFIX/btn_tracking_thread.gif", 22, 20));
        }
        return $null_link;
    }
}

sub Comment__print_multiform_check
{
    my ($ctx, $this) = @_;
    my $tid = $this->{'talkid'} >> 8;
    $S2::pout->("<input type='checkbox' name='selected_$tid' class='ljcomsel' id='ljcomsel_$this->{'talkid'}' />");
}

sub Comment__print_reply_link
{
    my ($ctx, $this, $opts) = @_;
    $opts ||= {};

    my $basesubject = $this->{'subject'};
    $opts->{'basesubject'} = $basesubject;
    $opts->{'target'} ||= $this->{'talkid'};

    _print_quickreply_link($ctx, $this, $opts);
}

*Page__print_reply_link = \&_print_quickreply_link;
*EntryPage__print_reply_link = \&_print_quickreply_link;

sub _print_quickreply_link
{
    my ($ctx, $this, $opts) = @_;

    $opts ||= {};

    # one of these had better work
    my $replyurl =  $opts->{'reply_url'} || $this->{'reply_url'} || $this->{'entry'}->{'comments'}->{'post_url'};

    # clean up input:
    my $linktext = LJ::ehtml($opts->{'linktext'}) || "";

    my $target = $opts->{'target'};
    return unless $target =~ /^\w+$/; # if no target specified bail the fuck out

    my $opt_class = $opts->{'class'};
    undef $opt_class unless $opt_class =~ /^[\w\s]+$/;

    my $opt_img = LJ::CleanHTML::canonical_url($opts->{'img_url'});
    $replyurl = LJ::CleanHTML::canonical_url($replyurl);

    # if they want an image change the text link to the image,
    # and add the text after the image if they specified it as well
    if ($opt_img) {
        # hella robust img options. (width,height,align,alt,title)
        # s2quickreply does it all. like whitaker's mom.
        my $width = $opts->{'img_width'} + 0;
        my $height = $opts->{'img_height'} + 0;
        my $align = $opts->{'img_align'};
        my $alt = LJ::ehtml($opts->{'alt'});
        my $title = LJ::ehtml($opts->{'title'});
        my $border = $opts->{'img_border'} + 0;

        $width  = $width  ? "width=$width" : "";
        $height = $height ? "height=$height" : "";
        $border = $border ne "" ? "border=$border" : "";
        $alt    = $alt    ? "alt=\"$alt\"" : "";
        $title  = $title  ? "title=\"$title\"" : "";
        $align  = $align =~ /^\w+$/ ? "align=\"$align\"" : "";

        $linktext = "<img src=\"$opt_img\" $width $height $align $title $alt $border />$linktext";
    }

    my $basesubject = $opts->{'basesubject'}; #cleaned later

    if ($opt_class) {
        $opt_class = "class=\"$opt_class\"";
    }

    my $page = get_page();
    my $remote = LJ::get_remote();
    LJ::load_user_props($remote, "opt_no_quickreply");
    my $onclick = "";
    unless ($remote->{'opt_no_quickreply'}) {
        my $pid = (int($target)&&$page->{'_type'} eq 'EntryPage') ? int($target /256) : 0;

        $basesubject =~ s/^(Re:\s*)*//i;
        $basesubject = "Re: $basesubject" if $basesubject;
        $basesubject = LJ::ejs($basesubject);
        $onclick = "return quickreply(\"$target\", $pid, \"$basesubject\")";
        $onclick = "onclick='$onclick'";
    }

    $onclick = "" unless $page->{'_type'} eq 'EntryPage';
    $onclick = "" if $LJ::DISABLED{'s2quickreply'};

    # See if we want to force them to change their password
    my $bp = LJ::bad_password_redirect({ 'returl' => 1 });

    if ($bp) {
        $S2::pout->("<a href='$bp'>$linktext</a>");
    } else {
        $S2::pout->("<a $onclick href='$replyurl' $opt_class>$linktext</a>");
    }
}

sub _print_reply_container
{
    my ($ctx, $this, $opts) = @_;

    my $page = get_page();
    return unless $page->{'_type'} eq 'EntryPage';

    my $target = $opts->{'target'};
    undef $target unless $target =~ /^\w+$/;

    my $class = $opts->{'class'} || undef;

    # set target to the dtalkid if no target specified (link will be same)
    my $dtalkid = $this->{'talkid'} || undef;
    $target ||= $dtalkid;
    return if !$target;

    undef $class unless $class =~ /^([\w\s]+)$/;

    if ($class) {
        $class = "class=\"$class\"";
    }

    $S2::pout->("<div $class id=\"ljqrt$target\" style=\"display: none;\"></div>");

    # unless we've already inserted the big qrdiv ugliness, do it.
    unless ($ctx->[S2::SCRATCH]->{'quickreply_printed_div'}++) {
        my $u = $page->{'_u'};
        my $ditemid = $page->{'entry'}{'itemid'} || 0;

        my $userpic = LJ::ehtml($page->{'_picture_keyword'}) || "";
        my $thread = $page->{'viewing_thread'} + 0 || "";
        $S2::pout->(LJ::create_qr_div($u, $ditemid, $page->{'_stylemine'} || 0, $userpic, $thread));
    }
}

*Comment__print_reply_container = \&_print_reply_container;
*EntryPage__print_reply_container = \&_print_reply_container;
*Page__print_reply_container = \&_print_reply_container;

sub Page__print_trusted
{
    my ($ctx, $this, $key) = @_;

    my $username = $this->{journal}->{username};
    my $fullkey = "$username-$key";
    
    return $S2::pout->("Error, no print_trusted key '$fullkey' defined.") unless exists ($LJ::TRUSTED_S2_WHITELIST{$fullkey});

    $S2::pout->($LJ::TRUSTED_S2_WHITELIST{$fullkey});
}

# class 'date'
sub Date__day_of_week
{
    my ($ctx, $dt) = @_;
    return $dt->{'_dayofweek'} if defined $dt->{'_dayofweek'};
    return $dt->{'_dayofweek'} = LJ::day_of_week($dt->{'year'}, $dt->{'month'}, $dt->{'day'}) + 1;
}
*DateTime__day_of_week = \&Date__day_of_week;

sub Date__compare
{
    my ($ctx, $this, $other) = @_;

    return $other->{year} <=> $this->{year}
           || $other->{month} <=> $this->{month}
           || $other->{day} <=> $this->{day}
           || $other->{hour} <=> $this->{hour}
           || $other->{min} <=> $this->{min}
           || $other->{sec} <=> $this->{sec};
}
*DateTime__compare = \&Date__compare;

my %dt_vars = (
               'm' => "\$time->{month}",
               'mm' => "sprintf('%02d', \$time->{month})",
               'd' => "\$time->{day}",
               'dd' => "sprintf('%02d', \$time->{day})",
               'yy' => "sprintf('%02d', \$time->{year} % 100)",
               'yyyy' => "\$time->{year}",
               'mon' => "\$ctx->[S2::PROPS]->{lang_monthname_short}->[\$time->{month}]",
               'month' => "\$ctx->[S2::PROPS]->{lang_monthname_long}->[\$time->{month}]",
               'da' => "\$ctx->[S2::PROPS]->{lang_dayname_short}->[Date__day_of_week(\$ctx, \$time)]",
               'day' => "\$ctx->[S2::PROPS]->{lang_dayname_long}->[Date__day_of_week(\$ctx, \$time)]",
               'dayord' => "S2::run_function(\$ctx, \"lang_ordinal(int)\", \$time->{day})",
               'H' => "\$time->{hour}",
               'HH' => "sprintf('%02d', \$time->{hour})",
               'h' => "(\$time->{hour} % 12 || 12)",
               'hh' => "sprintf('%02d', (\$time->{hour} % 12 || 12))",
               'min' => "sprintf('%02d', \$time->{min})",
               'sec' => "sprintf('%02d', \$time->{sec})",
               'a' => "(\$time->{hour} < 12 ? 'a' : 'p')",
               'A' => "(\$time->{hour} < 12 ? 'A' : 'P')",
            );

sub Date__date_format
{
    my ($ctx, $this, $fmt) = @_;
    $fmt ||= "short";
    my $c = \$ctx->[S2::SCRATCH]->{'_code_datefmt'}->{$fmt};
    return $$c->($this) if ref $$c eq "CODE";
    if (++$ctx->[S2::SCRATCH]->{'_code_datefmt_count'} > 15) { return "[too_many_fmts]"; }
    my $realfmt = $fmt;
    if (defined $ctx->[S2::PROPS]->{"lang_fmt_date_$fmt"}) {
        $realfmt = $ctx->[S2::PROPS]->{"lang_fmt_date_$fmt"};
    } elsif ($fmt eq "iso") {
        $realfmt = "%%yyyy%%-%%mm%%-%%dd%%";
    }
    my @parts = split(/\%\%/, $realfmt);
    my $code = "\$\$c = sub { my \$time = shift; return join('',";
    my $i = 0;
    foreach (@parts) {
        if ($i % 2) { $code .= $dt_vars{$_} . ","; }
        else { $_ = LJ::ehtml($_); $code .= "\$parts[$i],"; }
        $i++;
    }
    $code .= "); };";
    eval $code;
    return $$c->($this);
}
*DateTime__date_format = \&Date__date_format;

sub DateTime__time_format
{
    my ($ctx, $this, $fmt) = @_;
    $fmt ||= "short";
    my $c = \$ctx->[S2::SCRATCH]->{'_code_timefmt'}->{$fmt};
    return $$c->($this) if ref $$c eq "CODE";
    if (++$ctx->[S2::SCRATCH]->{'_code_timefmt_count'} > 15) { return "[too_many_fmts]"; }
    my $realfmt = $fmt;
    if (defined $ctx->[S2::PROPS]->{"lang_fmt_time_$fmt"}) {
        $realfmt = $ctx->[S2::PROPS]->{"lang_fmt_time_$fmt"};
    }
    my @parts = split(/\%\%/, $realfmt);
    my $code = "\$\$c = sub { my \$time = shift; return join('',";
    my $i = 0;
    foreach (@parts) {
        if ($i % 2) { $code .= $dt_vars{$_} . ","; }
        else { $_ = LJ::ehtml($_); $code .= "\$parts[$i],"; }
        $i++;
    }
    $code .= "); };";
    eval $code;
    return $$c->($this);
}

sub UserLite__ljuser
{
    my ($ctx, $UserLite) = @_;
    return LJ::ljuser($UserLite->{_u});
}

sub UserLite__get_link
{
    my ($ctx, $this, $key) = @_;

    my $u = $this->{_u};
    my $user = $u->{user};
    my $remote = LJ::get_remote();
    my $is_remote = defined($remote) && $remote->{userid} eq $u->{userid};
    my $has_journal = $u->{journaltype} ne 'I';

    my $button = sub {
        return LJ::S2::Link($_[0], $_[1], LJ::S2::Image("$LJ::IMGPREFIX/$_[2]", 22, 20));
    };

    if ($key eq 'add_friend' && defined($remote)) {
        return $button->("$LJ::SITEROOT/friends/add.bml?user=$user", "Add $user to friends list", "btn_addfriend.gif");
    }
    if ($key eq 'post_entry') {
        return undef unless $has_journal and LJ::can_use_journal($remote->{'userid'}, $user);

        my $caption = $is_remote ? "Update your journal" : "Post in $user";
        return $button->("$LJ::SITEROOT/update.bml?usejournal=$user", $caption, "btn_edit.gif");
    }
    if ($key eq 'todo') {
        my $caption = $is_remote ? "Your to-do list" : "${user}'s to-do list";
        return $button->("$LJ::SITEROOT/todo/?user=$user", $caption, "btn_todo.gif");
    }
    if ($key eq 'memories') {
        my $caption = $is_remote ? "Your memories" : "${user}'s memories";
        return $button->("$LJ::SITEROOT/tools/memories.bml?user=$user", $caption, "btn_memories.gif");
    }
    if ($key eq 'tell_friend' && $has_journal && !$LJ::DISABLED{'tellafriend'}) {
        my $caption = $is_remote ? "Tell a friend about your journal" : "Tell a friend about $user";
        return $button->("$LJ::SITEROOT/tools/tellafriend.bml?user=$user", $caption, "btn_tellfriend.gif");
    }
    if ($key eq 'search' && $has_journal && !$LJ::DISABLED{'offsite_journal_search'}) {
        my $caption = $is_remote ? "Search your journal" : "Search $user";
        return $button->("$LJ::SITEROOT/tools/search.bml?user=$user", $caption, "btn_search.gif");
    }
    if ($key eq 'nudge' && !$is_remote && $has_journal && $u->{journaltype} ne 'C') {
        return $button->("$LJ::SITEROOT/friends/nudge.bml?user=$user", "Nudge $user", "btn_nudge.gif");
    }

    # Else?
    return undef;
}
*User__get_link = \&UserLite__get_link;

sub EntryLite__get_link
{
    my ($ctx, $this, $key) = @_;
    my $null_link = { '_type' => 'Link', '_isnull' => 1 };

    if ($this->{_type} eq 'Entry') {
        return _Entry__get_link($ctx, $this, $key);
    }
    elsif ($this->{_type} eq 'Comment') {
        return _Comment__get_link($ctx, $this, $key);
    }
    else {
        return $null_link;
    }
}
*Entry__get_link = \&EntryLite__get_link;
*Comment__get_link = \&EntryLite__get_link;

sub EntryLite__get_tags_text
{
    my ($ctx, $this) = @_;
    return LJ::S2::get_tags_text($ctx, $this->{tags}) || "";
}
*Entry__get_tags_text = \&EntryLite__get_tags_text;

sub EntryLite__get_plain_subject
{
    my ($ctx, $this) = @_;
    return $this->{'_plainsubject'} if $this->{'_plainsubject'};
    my $subj = $this->{'subject'};
    LJ::CleanHTML::clean_subject_all(\$subj);
    return $this->{'_plainsubject'} = $subj;
}
*Entry__get_plain_subject = \&EntryLite__get_plain_subject;
*Comment__get_plain_subject = \&EntryLite__get_plain_subject;

sub _Entry__get_link
{
    my ($ctx, $this, $key) = @_;
    my $journal = $this->{'journal'}->{'username'};
    my $poster = $this->{'poster'}->{'username'};
    my $remote = LJ::get_remote();
    my $null_link = { '_type' => 'Link', '_isnull' => 1 };
    my $journalu = LJ::load_user($journal);

    if ($key eq "edit_entry") {
        return $null_link unless $remote && ($remote->{'user'} eq $journal ||
                                        $remote->{'user'} eq $poster ||
                                        LJ::can_manage($remote, LJ::load_user($journal)));
        return LJ::S2::Link("$LJ::SITEROOT/editjournal.bml?journal=$journal&amp;itemid=$this->{'itemid'}",
                            $ctx->[S2::PROPS]->{"text_edit_entry"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_edit.gif", 22, 20));
    }
    if ($key eq "edit_tags") {
        return $null_link unless $remote && LJ::Tags::can_add_tags(LJ::load_user($journal), $remote);
        return LJ::S2::Link("$LJ::SITEROOT/edittags.bml?journal=$journal&amp;itemid=$this->{'itemid'}",
                            $ctx->[S2::PROPS]->{"text_edit_tags"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_edittags.gif", 22, 20));
    }
    if ($key eq "tell_friend") {
        return $null_link if $LJ::DISABLED{'tellafriend'};
        return LJ::S2::Link("$LJ::SITEROOT/tools/tellafriend.bml?journal=$journal&amp;itemid=$this->{'itemid'}",
                            $ctx->[S2::PROPS]->{"text_tell_friend"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_tellfriend.gif", 22, 20));
    }
    if ($key eq "mem_add") {
        return $null_link if $LJ::DISABLED{'memories'};
        return LJ::S2::Link("$LJ::SITEROOT/tools/memadd.bml?journal=$journal&amp;itemid=$this->{'itemid'}",
                            $ctx->[S2::PROPS]->{"text_mem_add"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_memories.gif", 22, 20));
    }
    if ($key eq "nav_prev") {
        return LJ::S2::Link("$LJ::SITEROOT/go.bml?journal=$journal&amp;itemid=$this->{'itemid'}&amp;dir=prev",
                            $ctx->[S2::PROPS]->{"text_entry_prev"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_prev.gif", 22, 20));
    }
    if ($key eq "nav_next") {
        return LJ::S2::Link("$LJ::SITEROOT/go.bml?journal=$journal&amp;itemid=$this->{'itemid'}&amp;dir=next",
                            $ctx->[S2::PROPS]->{"text_entry_next"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_next.gif", 22, 20));
    }
    if ($key eq "watch_comments") {
        return $null_link if $LJ::DISABLED{'esn'};
        return $null_link unless $remote && $remote->can_use_esn;
        return $null_link if $remote->has_subscription(
                                                       journal => LJ::load_user($journal),
                                                       event   => "JournalNewComment",
                                                       arg1    => $this->{'itemid'},
                                                       arg2    => 0,
                                                       require_active => 1,
                                                       );

        return LJ::S2::Link("$LJ::SITEROOT/manage/subscriptions/entry.bml?journal=$journal&amp;itemid=$this->{'itemid'}",
                            $ctx->[S2::PROPS]->{"text_watch_comments"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_track.gif", 22, 20, 'Track This',
                                          'lj:journalid' => $journalu->id,
                                          'lj:etypeid'   => 'LJ::Event::JournalNewComment'->etypeid,
                                          'lj:arg1'      => $this->{itemid},
                                          'class'        => 'TrackButton'));
    }
    if ($key eq "unwatch_comments") {
        return $null_link if $LJ::DISABLED{'esn'};
        return $null_link unless $remote && $remote->can_use_esn;
        my @subs = $remote->has_subscription(
                                             journal => LJ::load_user($journal),
                                             event => "JournalNewComment",
                                             arg1 => $this->{'itemid'},
                                             arg2 => 0,
                                             require_active => 1,
                                             );
        my $subscr = $subs[0];
        return $null_link unless $subscr;

        return LJ::S2::Link("$LJ::SITEROOT/manage/subscriptions/entry.bml?journal=$journal&amp;itemid=$this->{'itemid'}",
                            $ctx->[S2::PROPS]->{"text_unwatch_comments"},
                            LJ::S2::Image("$LJ::IMGPREFIX/btn_tracking.gif", 22, 20, 'Untrack this',
                                          'lj:subid' => $subscr->id,
                                          'class'    => 'TrackButton'));
    }
}

sub Entry__plain_subject
{
    my ($ctx, $this) = @_;
    return $this->{'_subject_plain'} if defined $this->{'_subject_plain'};
    $this->{'_subject_plain'} = $this->{'subject'};
    LJ::CleanHTML::clean_subject_all(\$this->{'_subject_plain'});
    return $this->{'_subject_plain'};
}

sub EntryPage__print_multiform_actionline
{
    my ($ctx, $this) = @_;
    return unless $this->{'multiform_on'};
    my $pr = $ctx->[S2::PROPS];
    $S2::pout->($pr->{'text_multiform_des'} . "\n" .
                LJ::html_select({'name' => 'mode' },
                                "" => "",
                                map { $_ => $pr->{"text_multiform_opt_$_"} }
                                qw(unscreen screen delete deletespam)) . "\n" .
                LJ::html_submit('', $pr->{'text_multiform_btn'},
                                { "onclick" =>
                                      'return ((document.multiform.mode.value != "delete" ' .
                                      '&& document.multiform.mode.value != "deletespam")) ' .
                                      "|| confirm(\"" . LJ::ejs($pr->{'text_multiform_conf_delete'}) . "\");" }));
}

sub EntryPage__print_multiform_end
{
    my ($ctx, $this) = @_;
    return unless $this->{'multiform_on'};
    $S2::pout->("</form>");
}

sub EntryPage__print_multiform_start
{
    my ($ctx, $this) = @_;
    return unless $this->{'multiform_on'};
    $S2::pout->("<form style='display: inline' method='post' action='$LJ::SITEROOT/talkmulti.bml' name='multiform'>\n" .
                LJ::html_hidden("ditemid", $this->{'entry'}->{'itemid'},
                                "journal", $this->{'entry'}->{'journal'}->{'username'}) . "\n");
}

sub Page__print_control_strip
{
    my ($ctx, $this) = @_;

    return "" unless $LJ::USE_CONTROL_STRIP;
    my $control_strip = LJ::control_strip(user => $LJ::S2::CURR_PAGE->{'journal'}->{'_u'}->{'user'});

    return "" unless $control_strip;
    $S2::pout->($control_strip);
}

sub Page__print_hbox_top
{
    my ($ctx, $this) = @_;

    my $user = $this->{journal}->{username};
    my $journalu = LJ::load_user($this->{journal}->{username})
        or die "unable to load journal user: $user";

    # get ad with site-specific hook
    {
        my $ad_html = LJ::run_hook('hbox_top_ad_content', {
            journalu => $journalu,
            pubtext  => $LJ::REQ_GLOBAL{first_public_text},
        });
        $S2::pout->($ad_html) if $ad_html;
    }
}

sub Page__print_hbox_bottom
{
    my ($ctx, $this) = @_;

    my $user = $this->{journal}->{username};
    my $journalu = LJ::load_user($this->{journal}->{username})
        or die "unable to load journal user: $user";

    # get ad with site-specific hook
    {
        my $ad_html;
        if ($journalu->prop('journal_box_placement') eq 'h') {
            $ad_html = LJ::run_hook('hbox_bottom_ad_content', {
                journalu => $journalu,
                pubtext  => $LJ::REQ_GLOBAL{first_public_text},
            });
        } else {
            $ad_html = LJ::run_hook('hbox_with_vbox_ad_content', {
                journalu => $journalu,
                pubtext  => $LJ::REQ_GLOBAL{first_public_text},
            });
        }
        $S2::pout->($ad_html) if $ad_html;
    }
}

sub Page__print_vbox
{
    my ($ctx, $this) = @_;

    my $user = $this->{journal}->{username};
    my $journalu = LJ::load_user($this->{journal}->{username})
        or die "unable to load journal user: $user";

    # community promo box goes on top of skyscraper on community pages
    # that have ads
    if ($journalu->should_display_comm_promo) {
        my $promo_html = $journalu->render_comm_promo;
        $S2::pout->($promo_html) if $promo_html;
    }

    # next standard ad calls specified by site-specific hook
    {
        my $ad_html = LJ::run_hook('vbox_ad_content', {
            journalu => $journalu,
            pubtext  => $LJ::REQ_GLOBAL{first_public_text},
        });
        $S2::pout->($ad_html) if $ad_html;
    }
}

# deprecated, should use print_(v|h)box
sub Page__print_ad
{
    my ($ctx, $this, $type) = @_;

    my $ad = LJ::ads(
                     type    => 'journal',
                     orient  => $type,
                     user    => $LJ::S2::CURR_PAGE->{'journal'}->{'username'},
                     pubtext => $LJ::REQ_GLOBAL{'first_public_text'},
                     );
    return '' unless $ad;

    $S2::pout->($ad);
}

# map vbox/hbox methods into *Page classes
foreach my $class (qw(RecentPage FriendsPage YearPage MonthPage DayPage EntryPage ReplyPage TagsPage)) {
    foreach my $func (qw(print_ad print_vbox print_hbox_top print_hbox_bottom)) {
        eval "*${class}__$func = \&Page__$func";
    }
}


sub Page__visible_tag_list
{
    my ($ctx, $this) = @_;
    return $this->{'_visible_tag_list'}
        if defined $this->{'_visible_tag_list'};

    my $remote = LJ::get_remote();
    my $u = $LJ::S2::CURR_PAGE->{'_u'};
    return [] unless $u;

    my $tags = LJ::Tags::get_usertags($u, { remote => $remote });
    return [] unless $tags;

    my @taglist;
    foreach my $kwid (keys %{$tags}) {
        # only show tags for display
        next unless $tags->{$kwid}->{display};

        # create tag object
        push @taglist, LJ::S2::TagDetail($u, $kwid => $tags->{$kwid});
    }

    @taglist = sort { $a->{name} cmp $b->{name} } @taglist;
    return $this->{'_visible_tag_list'} = \@taglist;
}
*RecentPage__visible_tag_list = \&Page__visible_tag_list;
*DayPage__visible_tag_list = \&Page__visible_tag_list;
*MonthPage__visible_tag_list = \&Page__visible_tag_list;
*YearPage__visible_tag_list = \&Page__visible_tag_list;
*FriendsPage__visible_tag_list = \&Page__visible_tag_list;
*EntryPage__visible_tag_list = \&Page__visible_tag_list;
*ReplyPage__visible_tag_list = \&Page__visible_tag_list;
*TagsPage__visible_tag_list = \&Page__visible_tag_list;

sub Page__get_latest_month
{
    my ($ctx, $this) = @_;
    return $this->{'_latest_month'} if defined $this->{'_latest_month'};
    my $counts = LJ::S2::get_journal_day_counts($this);
    my ($year, $month);
    my @years = sort { $a <=> $b } keys %$counts;
    if (@years) {
        # year/month of last post
        $year = $years[-1];
        $month = (sort { $a <=> $b } keys %{$counts->{$year}})[-1];
    } else {
        # year/month of current date, if no posts
        my @now = gmtime(time);
        ($year, $month) = ($now[5]+1900, $now[4]+1);
    }
    return $this->{'_latest_month'} = LJ::S2::YearMonth($this, {
        'year' => $year,
        'month' => $month,
    });
}
*RecentPage__get_latest_month = \&Page__get_latest_month;
*DayPage__get_latest_month = \&Page__get_latest_month;
*MonthPage__get_latest_month = \&Page__get_latest_month;
*YearPage__get_latest_month = \&Page__get_latest_month;
*FriendsPage__get_latest_month = \&Page__get_latest_month;
*EntryPage__get_latest_month = \&Page__get_latest_month;
*ReplyPage__get_latest_month = \&Page__get_latest_month;

sub palimg_modify
{
    my ($ctx, $filename, $items) = @_;
    return undef unless $filename =~ /^\w[\w\/\-]*\.(gif|png)$/;
    my $url = "$LJ::PALIMGROOT/$filename";
    return $url unless $items && @$items;
    return undef if @$items > 7;
    $url .= "/p";
    foreach my $pi (@$items) {
        die "Can't modify a palette index greater than 15 with palimg_modify\n" if
            $pi->{'index'} > 15;
        $url .= sprintf("%1x%02x%02x%02x",
                        $pi->{'index'},
                        $pi->{'color'}->{'r'},
                        $pi->{'color'}->{'g'},
                        $pi->{'color'}->{'b'});
    }
    return $url;
}

sub palimg_tint
{
    my ($ctx, $filename, $bcol, $dcol) = @_;  # bright color, dark color [opt]
    return undef unless $filename =~ /^\w[\w\/\-]*\.(gif|png)$/;
    my $url = "$LJ::PALIMGROOT/$filename";
    $url .= "/pt";
    foreach my $col ($bcol, $dcol) {
        next unless $col;
        $url .= sprintf("%02x%02x%02x",
                        $col->{'r'}, $col->{'g'}, $col->{'b'});
    }
    return $url;
}

sub palimg_gradient
{
    my ($ctx, $filename, $start, $end) = @_;
    return undef unless $filename =~ /^\w[\w\/\-]*\.(gif|png)$/;
    my $url = "$LJ::PALIMGROOT/$filename";
    $url .= "/pg";
    foreach my $pi ($start, $end) {
        next unless $pi;
        $url .= sprintf("%02x%02x%02x%02x",
                        $pi->{'index'},
                        $pi->{'color'}->{'r'},
                        $pi->{'color'}->{'g'},
                        $pi->{'color'}->{'b'});
    }
    return $url;
}

sub userlite_base_url
{
    my ($ctx, $UserLite) = @_;
    my $u = $UserLite->{_u};
    return $u->journal_base;
}

sub userlite_as_string
{
    my ($ctx, $UserLite) = @_;
    return LJ::ljuser($UserLite->{'_u'});
}

sub PalItem
{
    my ($ctx, $idx, $color) = @_;
    return undef unless $color && $color->{'_type'} eq "Color";
    return undef unless $idx >= 0 && $idx <= 255;
    return {
        '_type' => 'PalItem',
        'color' => $color,
        'index' => $idx+0,
    };
}

sub YearMonth__month_format
{
    my ($ctx, $this, $fmt) = @_;
    $fmt ||= "long";
    my $c = \$ctx->[S2::SCRATCH]->{'_code_monthfmt'}->{$fmt};
    return $$c->($this) if ref $$c eq "CODE";
    if (++$ctx->[S2::SCRATCH]->{'_code_timefmt_count'} > 15) { return "[too_many_fmts]"; }
    my $realfmt = $fmt;
    if (defined $ctx->[S2::PROPS]->{"lang_fmt_month_$fmt"}) {
        $realfmt = $ctx->[S2::PROPS]->{"lang_fmt_month_$fmt"};
    }
    my @parts = split(/\%\%/, $realfmt);
    my $code = "\$\$c = sub { my \$time = shift; return join('',";
    my $i = 0;
    foreach (@parts) {
        if ($i % 2) { $code .= $dt_vars{$_} . ","; }
        else { $_ = LJ::ehtml($_); $code .= "\$parts[$i],"; }
        $i++;
    }
    $code .= "); };";
    eval $code;
    return $$c->($this);
}

sub Image__set_url {
    my ($ctx, $img, $newurl) = @_;
    $img->{'url'} = LJ::eurl($newurl);
}

sub ItemRange__url_of
{
    my ($ctx, $this, $n) = @_;
    return "" unless ref $this->{'_url_of'} eq "CODE";
    return $this->{'_url_of'}->($n+0);
}

sub UserLite__equals
{
    return $_[1]->{'_u'}{'userid'} == $_[2]->{'_u'}{'userid'};
}
*User__equals = \&UserLite__equals;
*Friend__equals = \&UserLite__equals;

sub string__substr
{
    my ($ctx, $this, $start, $length) = @_;
    use utf8;
    return substr($this, $start, $length);
}

sub string__length
{
    use utf8;
    my ($ctx, $this) = @_;
    return length($this);
}

sub string__lower
{
    use utf8;
    my ($ctx, $this) = @_;
    return lc($this);
}

sub string__upper
{
    use utf8;
    my ($ctx, $this) = @_;
    return uc($this);
}

sub string__upperfirst
{
    use utf8;
    my ($ctx, $this) = @_;
    return ucfirst($this);
}

sub string__starts_with
{
    use utf8;
    my ($ctx, $this, $str) = @_;
    return $this =~ /^\Q$str\E/;
}

sub string__ends_with
{
    use utf8;
    my ($ctx, $this, $str) = @_;
    return $this =~ /\Q$str\E$/;
}

sub string__contains
{
    use utf8;
    my ($ctx, $this, $str) = @_;
    return $this =~ /\Q$str\E/;
}

sub string__repeat
{
    use utf8;
    my ($ctx, $this, $num) = @_;
    $num += 0;
    my $size = length($this) * $num;
    return "[too large]" if $size > 5000;
    return $this x $num;
}

sub string__compare
{
    use utf8; # Does this actually make any difference here?
    my ($ctx, $this, $other) = @_;
    return $other cmp $this;
}

sub string__css_length_value
{
    my ($ctx, $this) = @_;

    $this =~ s/^\s+//g;
    $this =~ s/\s+$//g;

    # Is it one of the acceptable keywords?
    my %allowed_keywords = map { $_ => 1 } qw(larger smaller xx-small x-small small medium large x-large xx-large auto inherit);
    return $this if $allowed_keywords{$this};

    # Is it a number followed by an acceptable unit?
    my %allowed_units = map { $_ => 1 } qw(em ex px in cm mm pt pc %);
    return $this if $this =~ /^[\-\+]?(\d*\.)?\d+([a-z]+|\%)$/ && $allowed_units{$2};

    # Is it zero?
    return "0" if $this =~ /^(0*\.)?0+$/;

    return '';
}

sub string__css_string
{
    my ($ctx, $this) = @_;

    $this =~ s/\\/\\\\/g;
    $this =~ s/\"/\\\"/g;

    return '"'.$this.'"';

}

sub string__css_url_value
{
    my ($ctx, $this) = @_;

    return '' if $this !~ m!^https?://!;
    return '' if $this =~ /[^a-z0-9A-Z\.\@\$\-_\.\+\!\*'\(\),&=#;:\?\/\%~]/;
    return 'url('.string__css_string($ctx, $this).')';
}

sub string__css_keyword
{
    my ($ctx, $this, $allowed) = @_;

    $this =~ s/^\s+//g;
    $this =~ s/\s+$//g;

    return '' if $this =~ /[^a-z\-]/i;

    if ($allowed) {
        # If we've got an arrayref, transform it into a hashref.
        $allowed = { map { $_ => 1 } @$allowed } if ref $allowed eq 'ARRAY';
        return '' unless $allowed->{$this};
    }

    return lc($this);
}

sub string__css_keyword_list
{
    my ($ctx, $this, $allowed) = @_;

    $this =~ s/^\s+//g;
    $this =~ s/\s+$//g;

    my @in = split(/\s+/, $this);
    my @out = ();

    # Do the transform of $allowed to a hash once here rather than once for each keyword
    $allowed = { map { $_ => 1 } @$allowed } if ref $allowed eq 'ARRAY';

    foreach my $kw (@in) {
        $kw = string__css_keyword($ctx, $kw, $allowed);
        push @out, $kw if $kw;
    }

    return join(' ', @out);
}


1;
