#!/usr/bin/perl
#

use strict;
use lib "$ENV{'FBHOME'}/lib";
use S2;
use S2::Color;
use S2::EXIF;

package FB;

sub s2_run
{
    my ($r, $ctx, $opts, $entry, $page) = @_;

    my $ctype = $opts->{'content_type'} || "text/html";
    my $cleaner;
    my $ret;   # the return scalar, in non-chunked mode

    if ($FB::CHUNKED_OUTPUT) {
        if ($ctype =~ m!^text/html!) {
            $cleaner = new HTMLCleaner ('output' => sub { $r->print($_[0]); });
        }

        my $send_header = sub {
            my $status = $ctx->[3]->{'status'} || 200;
            $r->status($status);
            $r->content_type($ctx->[3]->{'ctype'} || $ctype);
            $r->send_http_header();
        };

        if ($cleaner) {
            S2::set_output_safe(sub {
                $send_header->();
                $cleaner->parse($_[0]);
                S2::set_output(sub { $r->print($_[0]); });
                S2::set_output_safe(sub { $cleaner->parse($_[0]); });
            });
            S2::set_output(sub {
                $send_header->();
                $r->print($_[0]);
                S2::set_output(sub { $r->print($_[0]); });
                S2::set_output_safe(sub { $cleaner->parse($_[0]); });
            });
        } else {
            S2::set_output_safe(sub {
                $send_header->();
                $r->print($_[0]);
                S2::set_output(sub { $r->print($_[0]); });
                S2::set_output_safe(sub { $r->print($_[0]); });
            });
            S2::set_output(sub {
                $send_header->();
                $r->print($_[0]);
                S2::set_output(sub { $r->print($_[0]); });
                S2::set_output_safe(sub { $r->print($_[0]); });
            });
        }
    } else {
        if ($ctype =~ m!^text/html!) {
            $cleaner = new HTMLCleaner ('output' => sub { $ret .= $_[0]; });
        }

        S2::set_output(sub { $ret .= $_[0]; });
        if ($cleaner) {
            S2::set_output_safe(sub { $cleaner->parse($_[0]); });
        } else {
            S2::set_output_safe(sub { $ret .= $_[0]; });
        }
    }

    $S2FotoBilder::CURR_PAGE = $page;
    eval {
        S2::run_code($ctx, $entry, $page);
    };
    if ($@) {
        my $error = FB::ehtml($@);
        $error =~ s/\n/<br>\n/g;
        S2::pout("<b>Error running style:</b> $error");
        return 0;
    } else {
        S2::pout(undef);  # send the HTTP header, if it hasn't been already
        $cleaner->eof if $cleaner;  # flush any remaining text/tag not yet spit out
    }

    unless ($FB::CHUNKED_OUTPUT) {
        my $status = $ctx->[3]->{'status'} || 200;
        $r->status($status);
        $r->content_type($ctx->[3]->{'ctype'} || $ctype);
        $r->header_out('Content-Length', length($ret));
        $r->send_http_header();
        $r->print($ret);
    }

    return 1;
}

sub s2_context
{
    my $r = shift;
    my $styleid = shift;
    my $opts = shift;

    my $dbr = FB::get_db_reader();

    my %style;
    my $have_style = 0;
    if ($styleid) {
        my $sth = $dbr->prepare("SELECT type, s2lid FROM s2stylelayers ".
                                "WHERE styleid=?");
        $sth->execute($styleid);
        while (my ($t, $id) = $sth->fetchrow_array) { $style{$t} = $id; }
        $have_style = scalar %style;
    }

    unless ($have_style) {
        my $public = FB::get_public_layers();
        while (my ($layer, $name) = each %$FB::DEFAULT_STYLE) {
            next unless $name ne "";
            next unless $public->{$name};
            my $id = $public->{$name}->{'s2lid'};
            $style{$layer} = $id if $id;
        }
    }

    my @layers;
    foreach (qw(core i18nc layout i18n theme user)) {
        push @layers, $style{$_} if $style{$_};
    }

    my $modtime = S2::load_layers_from_db($dbr, @layers);

    # check that all critical layers loaded okay from the database, otherwise
    # fall back to default style.  if i18n/theme/user were deleted, just proceed.
    my $okay = 1;
    foreach (qw(core layout)) {
        next unless $style{$_};
        $okay = 0 unless S2::layer_loaded($style{$_});
    }
    unless ($okay) {
        # load the default style instead.
        if ($have_style) { return FB::s2_context($r, 0, $opts); }

        # were we trying to load the default style?
        $r->content_type("text/html");
        $r->send_http_header();
        $r->print("<b>Error preparing to run:</b> One or more layers required to load the stock style have been deleted.");
        return undef;
    }

    if ($opts->{'use_modtime'})
    {
        my $ims = $r->header_in("If-Modified-Since");
        my $ourtime = FB::date_unix_to_http($opts->{'modtime'});
        if ($ims eq $ourtime) {
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
        S2::set_output(sub {});  # printing suppressed
        eval { S2::run_code($ctx, "prop_init()"); };
        return $ctx unless $@;
    }

    my $err = $@;
    $r->content_type("text/html");
    $r->send_http_header();
    $r->print("<b>Error preparing to run:</b> $err");
    return undef;

}

sub clone_layer
{
    my $id = shift;
    return 0 unless $id;

    my $dbh = FB::get_db_writer();
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

    my $dbh = FB::get_db_writer();
    my $clone;
    $clone = FB::load_style($cloneid) if $cloneid;

    # can't clone somebody else's style
    return 0 if $clone && $clone->{'userid'} != $u->{'userid'};

    # can't create name-less style
    return 0 unless $name =~ /\S/;

    $dbh->do("INSERT INTO s2styles (userid, name) VALUES (?,?)", undef,
             $u->{'userid'}, $name);
    my $styleid = $dbh->{'mysql_insertid'};
    return 0 unless $styleid;

    if ($clone) {
        $clone->{'layer'}->{'user'} =
            FB::clone_layer($clone->{'layer'}->{'user'});

        my $values;
        foreach my $ly ('core','i18nc','layout','theme','i18n','user') {
            next unless $clone->{'layer'}->{$ly};
            $values .= "," if $values;
            $values .= "($styleid, '$ly', $clone->{'layer'}->{$ly})";
        }
        $dbh->do("REPLACE INTO s2stylelayers (styleid, type, s2lid) ".
                 "VALUES $values") if $values;
    }

    return $styleid;
}

sub load_user_styles
{
    my $u = shift;
    my $opts = shift;
    return undef unless $u;

    my $dbr = FB::get_db_reader();

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
    my $dbh = FB::get_db_writer();
    $load_using->($dbh);
    return \%styles if %styles;

    $dbh->do("INSERT INTO s2styles (userid, name) VALUES (?,?)", undef,
             $u->{'userid'}, $u->{'user'});
    my $styleid = $dbh->{'mysql_insertid'};
    return { $styleid => $u->{'user'} };
}

sub delete_user_style
{
    my ($u, $styleid) = @_;
    return 1 unless $styleid;
    my $dbh = FB::get_db_writer();

    my $style = FB::load_style($dbh, $styleid);
    FB::delete_layer($style->{'layer'}->{'user'});

    foreach my $t (qw(s2styles s2stylelayers)) {
        $dbh->do("DELETE FROM $t WHERE styleid=?", undef, $styleid)
    }

    # TODO: update any of their galleries using it, perhaps.
    return 1;
}

sub load_style
{
    my $db = ref $_[0] ? shift : undef;
    my $id = shift;
    return undef unless $id;

    $db ||= FB::get_db_reader();
    my $style = $db->selectrow_hashref("SELECT styleid, userid, name ".
                                       "FROM s2styles WHERE styleid=?",
                                       undef, $id);
    return undef unless $style;

    $style->{'layer'} = {};
    my $sth = $db->prepare("SELECT type, s2lid FROM s2stylelayers ".
                           "WHERE styleid=?");
    $sth->execute($id);
    while (my ($type, $s2lid) = $sth->fetchrow_array) {
        $style->{'layer'}->{$type} = $s2lid;
    }
    return $style;
}

# if verify, the $u->{'styleid'} key is deleted if style isn't found
sub get_style
{
    my ($arg, $verify) = @_;

    my ($styleid, $u);
    if (ref $arg) {
        $u = $arg;
        $styleid = $u->prop('styleid') + 0;
    } else {
        $styleid = $arg + 0;
    }

    my %style;
    my $have_style = 0;

    if ($verify && $styleid) {
        my $dbr = FB::get_db_reader();
        my $style = $dbr->selectrow_hashref("SELECT * FROM s2styles WHERE styleid=?", undef, $styleid);
        if (! $style && $u) {
            delete $u->{'styleid'};
            $styleid = 0;
        }
    }

    if ($styleid) {
        my $stylay = FB::get_style_layers($styleid);
        while (my ($t, $id) = each %$stylay) { $style{$t} = $id; }
        $have_style = scalar %style;
    }

    unless ($have_style) {
        my $public = FB::get_public_layers();
        while (my ($layer, $name) = each %$FB::DEFAULT_STYLE) {
            next unless $name ne "";
            next unless $public->{$name};
            my $id = $public->{$name}->{'s2lid'};
            $style{$layer} = $id if $id;
        }
    }

    return %style;
}

# find existing re-distributed layers that are in the database
# and their styleids.
sub get_public_layers
{
    my $sysid = shift;  # optional system userid (usually not used)
    return $FB::CACHED_PUBLIC_LAYERS if $FB::CACHED_PUBLIC_LAYERS;

    $sysid ||= FB::get_sysid();
    my $layers = FB::get_layers_of_user($sysid, "is_system");

    return $layers if $FB::LESS_CACHING;
    $FB::CACHED_PUBLIC_LAYERS = $layers if $layers;
    return $FB::CACHED_PUBLIC_LAYERS;
}

sub get_layers_of_user
{
    my ($u, $is_system) = @_;
    my $userid;
    if (ref $u) {
        $userid = $u->{'userid'}+0;
    } else {
        $userid = $u + 0;
        undef $u;
    }
    return undef unless $userid;

    return $u->{'_s2layers'} if $u && $u->{'_s2layers'};

    my %layers;    # id -> {hashref}, uniq -> {same hashref}
    my $dbr = FB::get_db_reader();

    my $extrainfo = $is_system ? "'redist_uniq', " : "";
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
        next unless $layers{$_}->{'b2lid'};
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

sub create_layer
{
    my ($userid, $b2lid, $type) = @_;
    $userid = want_userid($userid);

    return 0 unless $b2lid;  # caller should ensure b2lid exists and is of right type
    return 0 unless
        $type eq "user" || $type eq "i18n" || $type eq "theme" ||
        $type eq "layout" || $type eq "i18nc" || $type eq "core";

    my $dbh = FB::get_db_writer();
    return 0 unless $dbh;

    $dbh->do("INSERT INTO s2layers (b2lid, userid, type) ".
             "VALUES (?,?,?)", undef, $b2lid, $userid, $type);
    return $dbh->{'mysql_insertid'};
}

sub delete_layer
{
    my $lid = shift;
    return 1 unless $lid;
    my $dbh = FB::get_db_writer();
    foreach my $t (qw(s2layers s2compiled s2info s2source s2checker)) {
        $dbh->do("DELETE FROM $t WHERE s2lid=?", undef, $lid);
    }
    return 1;
}

sub set_style_layers
{
    my ($u, $styleid, %newlay) = @_;

    my $dbh = FB::get_db_writer() or return 0;

    my @vals = map { $styleid, $_, $newlay{$_} } keys %newlay;

    my $bind = join(",", map { "(?,?,?)" } 1..(@vals/3));

    $dbh->do("REPLACE INTO s2stylelayers (styleid,type,s2lid) VALUES $bind", undef, @vals) or return 0;

    return 1;
}

sub load_layer
{
    my $db = ref $_[0] ? shift : FB::get_db_reader();
    my $lid = shift;

    return $db->selectrow_hashref("SELECT s2lid, b2lid, userid, type ".
                                  "FROM s2layers WHERE s2lid=?", undef,
                                  $lid);
}

sub layer_compile_user
{
    my ($layer, $overrides) = @_;
    my $dbh = FB::get_db_writer();
    return 0 unless ref $layer;
    return 0 unless $layer->{'s2lid'};
    return 1 unless ref $overrides;
    my $id = $layer->{'s2lid'};
    my $s2 = "layerinfo \"type\" = \"user\";\n";

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
    return 1 if FB::layer_compile($layer, \$error, { 's2ref' => \$s2 });
    return FB::error($error);
}

sub layer_compile
{
    my ($layer, $err_ref, $opts) = @_;
    my $dbh = FB::get_db_writer();

    my $lid;
    if (ref $layer eq "HASH") {
        $lid = $layer->{'s2lid'}+0;
    } else {
        $lid = $layer+0;
        $layer = FB::load_layer($dbh, $lid) or return 0;
    }
    return 0 unless $lid;

    # get checker (cached, or via compiling) for parent layer
    my $checker = FB::get_layer_checker($layer);
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

    my $trusted = ($layer->{userid} == FB::get_sysid()) || $FB::S2_TRUSTED{$layer->{userid}};

    my $compiled;
    my $cplr = S2::Compiler->new({ 'checker' => $checker });
    eval {
        $cplr->compile_source({
            'type' => $layer->{'type'},
            'source' => $s2ref,
            'output' => \$compiled,
            'layerid' => $lid,
            'untrusted' => ! $trusted,
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
        my $chk_frz = Storable::nfreeze($checker);
        $dbh->do("REPLACE INTO s2checker (s2lid, checker) VALUES (?,?)", undef,
                 $lid, $chk_frz) or die;
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
        $dbh->do("REPLACE INTO s2info (s2lid, infokey, value) VALUES $values") or die;
        $dbh->do("DELETE FROM s2info WHERE s2lid=? AND infokey NOT IN ($notin)", undef, $lid);
    }

    # put compiled into database, with its ID number
    $dbh->do("REPLACE INTO s2compiled (s2lid, comptime, compdata) ".
             "VALUES (?, UNIX_TIMESTAMP(), ?)", undef, $lid, $compiled) or die;

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
    my $dbh = FB::get_db_writer();

    my $get_cached = sub {
        my $frz = $dbh->selectrow_array("SELECT checker FROM s2checker WHERE s2lid=?",
                                        undef, $parid) or return undef;
        return eval { Storable::thaw($frz) }; # can be undef, on failure
    };

    # the good path
    my $checker = $get_cached->();
    return $checker if $checker;

    # no cached checker (or bogus), so we have to [re]compile to get it
    my $parlay = FB::load_layer($dbh, $parid);
    return undef unless FB::layer_compile($parlay);
    return $get_cached->();
}

sub load_layer_info
{
    my ($outhash, $listref) = @_;
    return 0 unless ref $listref eq "ARRAY";
    return 1 unless @$listref;
    my $in = join(',', map { $_+0 } @$listref);
    my $dbr = FB::get_db_reader();
    my $sth = $dbr->prepare("SELECT s2lid, infokey, value FROM s2info WHERE ".
                            "s2lid IN ($in)");
    $sth->execute;
    while (my ($id, $k, $v) = $sth->fetchrow_array) {
        $outhash->{$id}->{$k} = $v;
    }
    return 1;
}

package FB::S2;

sub Date
{
    my $date = shift;  # yyyy-mm-dd
    return Null("Date") unless
        $date =~ /^(\d\d\d\d)-(\d\d)-(\d\d)/ && $1;
    return {
        '_type' => "Date",
        'year' => $1 || "0000", 'month' => $2, 'day' => $3,
    };
}

sub DateTime
{
    my $date = shift;  # yyyy-mm-dd hh:mm:ss
    return Null("DateTime") unless
        $date =~ /^(\d\d\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$/ && $1;
    return {
        '_type' => "DateTime",
        'year' => $1 || "0000", 'month' => $2, 'day' => $3,
        'hour' => $4, 'min' => $5, 'sec' => $6,
    };
}

sub DateTime_fromunix
{
    my $time = shift;  # unix time
    my $timezone = shift;
    my @ltime = localtime($time);  # TODO: do timezone stuff
    return Null("DateTime") unless $time;
    return {
        '_type' => "DateTime",
        'year' => $ltime[5]+1900, 'month' => $ltime[4]+1, 'day' => $ltime[3],
        'hour' => $ltime[2], 'min' => $ltime[1], 'sec' => $ltime[0],
    };
}

sub GalleryBasic
{
    my $o = shift; # u, name, gallid, randauth
    my $gal = {
        '_type' => "GalleryBasic",
        '_gallid' => $o->{'gallid'},
        'name' => FB::ehtml($o->{'name'}),
        'url' => FB::url_gallery($o->{'u'}, $o),
    };
    return $gal;
}

sub Gallery
{
    # FIXME: make this take either old ghetto hashref of crap or new
    # FB::Gallery object.  for now, coerce old args into an
    # FB::Gallery object

    my $o = shift; # u, name, gallid, numpics, dategal, timeupdate

    my $u = $o->{u} || FB::load_userid($o->{userid});

    Carp::confess("No u passed in") unless $u;
    Carp::confess("No gallid passed in") unless $o->{'gallid'};
    Carp::confess("bogus \$u to Gallery S2") unless ref $u eq "FB::User";
    my $galobj = FB::Gallery->new($u, $o->{'gallid'});

    my $gal = {
        '_type' => "Gallery",
        '_gallid' => $o->{'gallid'},
        '_galobj' => $galobj,
        'children' => [],  # populated elsewhere
        'date' => DateTime($o->{'dategal'}),
        'dateupdate' => DateTime_fromunix($o->{'timeupdate'}),
        'name' => FB::ehtml($o->{'name'}),
        'numpics' => $o->{'numpics'}+0,
        'url' => $galobj->url,
        'security' => $o->{'secid'},
        'manage_url' => "$LJ::SITEROOT/manage/media/gal.bml?id=$o->{gallid}",
    };
    return $gal;
}

sub GalleryPage
{
    my $o = shift;  # gal, pictures
    my $pg = Page($o);
    $pg->{'view'} = "gallery";
    $pg->{'_type'} = "GalleryPage";

    my $u = $o->{'u'};

    my $gal = $o->{'gal'};
    $gal->{'u'} = $u;

    # populate the copy url if
    #    remote exists and isn't the owner
    #    remote has copy security for this gallery
    my $remote = FB::get_remote();
    FB::load_gallery_props($u, $gal, 'exportable_sec');
    $pg->{'copy_url'} = "$LJ::SITEROOT/manage/media/makecopy.bml?user=$u->{usercs}&type=gal&id=$gal->{'gallid'}"
        if $remote && $remote->{user} ne $u->{user} &&
           FB::can_view_secid($u, $remote, $gal->{exportable_sec}+0);

    $pg->{'manage_url'} = "$LJ::SITEROOT/manage/media/gal.bml?id=$gal->{'gallid'}";
    $pg->{'self_link'} = Link({ 'current_page' => 1,
                                'dest_view' => 'gallery',
                                'caption' => $gal->{'name'},
                                'url' => FB::url_gallery($u, $gal) });
    $pg->{'gallery'} = Gallery($gal);
    $pg->{'pictures'} = $o->{'pictures'};
    $pg->{'pages'} = $o->{'pages'};
    $pg->{'dup_pictures'} = $o->{'dup_pictures'};
    $pg->{'des'} = $gal->{'des'};
    $pg->{'security'} = $gal->{'secid'};

    return $pg;
}

sub Image
{
    my ($url, $w, $h) = @_;
    return {
        '_type' => 'Image',
        'width' => $w,
        'height' => $h,
        'url' => $url,
    };
}

sub IndexPage
{
    my $o = shift;  # u, r
    my $pg = Page($o);
    $pg->{'view'} = "index";
    $pg->{'_type'} = "IndexPage";

    my $u = $o->{'u'};
    my $base_url = $u->media_base_url;

    $pg->{'galleries'} = [];
    FB::S2::add_child_galleries($pg, $pg->{'galleries'}, 0);

    # make trails
    my $link = FB::S2::Link({ 'caption' => "Top", # <-- FIXME: use some userprop
                              'current_page' => 1,
                              'dest_view' => 'index',
                              'url' => $base_url, });
    $pg->{'self_link'} = $link;
    $pg->{'trail'} = [ $link ];
    $pg->{'trails'} = [ $pg->{'trail'} ];
    $pg->{'manage_url'} = "$LJ::SITEROOT/manage/media/";

    # do filtering/sorting/paging
    my %valid = ('top' => 1, 'alpha' => 1, 'recent' => 1, 'date' => 1);
    # TODO: based on owner's userprops, delete valid options
    my $sort_mode = $pg->{'_args'}->{'sort'};
    $sort_mode = "top" unless $valid{$sort_mode};
    $pg->{'sort_mode'} = $sort_mode;
    $pg->{'sort_link'} = {};
    foreach (keys %valid) {
        $pg->{'sort_link'}->{$_} = FB::S2::Link({
            'caption' => $_,
            'current_page' => $_ eq $sort_mode,
            'dest_view' => 'index',
            'url' => "$base_url?sort=$_",
        });
    }

    my @sg;

    my $num = (S2::get_property_value($FB::S2::curr_ctx, "index_page_max_size")+0) || 25;
    if ($sort_mode eq "top") {
        foreach (@{$pg->{'_galchildren'}->{0}}) {
            push @sg, $pg->{'_gals'}->{$_};
        }
    } elsif ($sort_mode eq "alpha") {
        @sg = sort { $a->{'name'} cmp $b->{'name'} } values %{$pg->{'_gals'}};
    } elsif ($sort_mode eq "recent") {
        @sg = (sort { $b->{'timeupdate'} <=> $a->{'timeupdate'} }
               values %{$pg->{'_gals'}});
    } elsif ($sort_mode eq "date") {
        @sg = (sort { $a->{'dategal'} cmp $b->{'dategal'} }
               grep { $_->{'dategal'} } values %{$pg->{'_gals'}});
    }

    # remove "Tag: foo" ones (Temporary, until policy worked out)
    @sg = grep { $_->{name} !~ /^Tag: / } @sg;

    # Paging
    $pg->{'sorted_pages'} = FB::S2::ItemRange_fromopts({
        'page' => $pg->{'_args'}->{'page'},
        'pagesize' => $num,
        'items' => \@sg,
        'url_of' => sub { "$base_url?sort=$sort_mode&page=$_[0]"; },
    });

    # now that @sg is truncated, turn the hashrefs into S2 Gallery objects
    @sg = map { FB::S2::Gallery($_) } @sg;
    foreach (@sg) { FB::S2::add_child_galleries($pg, $_); }

    # load descriptions for the sorted ones (assume those will be shown)
    my $ids = join(",", map { $_->{'_gallid'}+0 } @sg);
    if ($ids) {
        my %des;
        my $sth = $u->prepare("SELECT itemid, des FROM des WHERE userid=? AND itemtype='G' AND itemid IN ($ids)",
                              $u->{userid});
        $sth->execute;
        while (my ($id, $des) = $sth->fetchrow_array) { $des{$id} = $des; }
        foreach (@sg) {
            my $des = $des{$_->{'_gallid'}};
            if ($des) {
                $_->{'des'} = $des;
                FB::format_des($_);
            } else {
                $_->{'des'} =  "";  # always defined.
            }
        }
    }

    $pg->{'sorted_galleries'} = \@sg;

    # load each subgallery and print out a link to the xmlinfo pages
    foreach my $gal (@{$pg->{galleries}}) {
        my $galobj = $gal->{_galobj} or next;
        my $infourl = $galobj->info_url();

        $pg->{head_content} .= qq {
            <link rel="Subsection" type="application/fbinfo+xml" title="Fotobilder Subgallery Info" href="$infourl" />};
    }

    return $pg;
}

sub ItemRange_fromopts
{
    my $opts = shift;
    my $ir = {};

    my $items = $opts->{'items'};
    my $page_size = ($opts->{'pagesize'}+0) || 25;
    my $page = $opts->{'page'}+0 || 1;
    my $num_items = scalar @$items;

    my $pages = POSIX::ceil($num_items / $page_size);
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

sub Link
{
    my $h = shift;
    $h->{'_type'} = "Link";
    $h->{'caption'} = FB::ehtml($h->{'caption'});
    return $h;
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
    my $o = shift;

    my $u = $o->{'u'};
    my $base_url = $u->media_base_url;
    my $styleid = defined $o->{'styleid'} ? $o->{'styleid'} : $u->prop('styleid');

    # Set notes for DB logging.
    my $remote = FB::get_remote();
    eval { Apache->request->notes('fb_ownerid' => $u->{'userid'}); };

    my %args;
    my %all_args;
    if ($o->{'r'}) {
        my @args = $o->{'r'}->args;
        while (my ($k, $v) = splice(@args, 0, 2)) {
            $all_args{$k} = $v;
            next unless $k =~ s/^\.//;
            $args{$k} = $v;
        }
    }

    my $pl;
    {
        my $link = $o->{'parent_link'};
        if ( $o->{'parent_links'} && @{ $o->{'parent_links'} } ) {
            $link ||= $o->{'parent_links'}->[0];
        }
        $pl = $link unless FB::gal_is_unsorted( $link->{caption} );
    }

    my $h = {
        '_type' => 'Page',
        '_args' => \%all_args,
        '_u' => $u,
        'args' => \%args,
        'parent_link' => $pl,
        'parent_links' => $o->{'parent_links'} || [],
        'stylesheeturl' => "/media/res/$styleid/stylesheet",
        'user'  => User($u),
        'view' => '',
        'manage_account' => FB::S2::Link({ 'current_page' => 0,
                                           'dest_view' => 'manage',
                                           'caption' => "Manage Your Account",
                                           'url' => "$LJ::SITEROOT/manage/",
                                       }),
        'tags' => $o->{'tags'},
        'head_content' => $o->{'head_content'} ? $o->{'head_content'} : '',
    };

    return $h;
}

sub Picture
{
    my $o = shift; # u, gal?
    my $u = $o->{'u'};
    my $up = $o->{'pic'};

    if (ref $up eq "HASH") {
        # upgrade it to a real upic object:
        if ($FB::DEBUG) {
            warn "Got up = $up\n from " . join(",", caller(0)) . "\n";
        }
        $up = FB::Upic->new($u, $up->{upicid});
    }

    if (ref $o->{gal} eq "HASH") {
        $o->{gal} = FB::Gallery->new($u, $o->{gal}{gallid});
    }

    my $h = {
        '_type' => "Picture",
        'fullimage' => Image($up->url_full, $up->width, $up->height),
        'piccode' => $up->piccode,
        'thumbnails' => {},
        'title' => FB::ehtml($up->prop('pictitle')),
        'manage_url' => $up->manage_url,
        'bytes' => $up->bytes,
        'url' => $up->url_picture_page($o->{'gal'}),
        '_upicid' => $up->id,
        '_upic' => $up,
        'security' => $up->secid,
    };

    # set the thumbnails
    my %fmts_by_name = FB::get_thumb_formats($FB::S2::curr_ctx);
    foreach my $thumbname (keys %fmts_by_name) {
        my $sty = $fmts_by_name{$thumbname};
        my ($url, $nw, $nh) = $up->url_thumbnail($sty);
        $h->{'thumbnails'}->{$thumbname} = FB::S2::Image($url, $nw, $nh);
    }

    return $h;
}

sub string__is_printable
{
    my ($ctx, $this) = @_;

    # CR, LF, HT, SP-~
    return $this !~ /[^\x09\x0a\x0d\x20-\x7e]/;
}

sub PicturePage
{
    my $o = shift;  # pic, gal(see Gallery reqs)
    my $pg = Page($o);
    $pg->{'view'} = "picture";
    $pg->{'_type'} = "PicturePage";

    my $u = $o->{'u'};
    my $up = $o->{'pic'};

    # gallery needs to have its u set (for callees later), but don't
    # auto-vivify it!
    $o->{'gal'}->{'u'} = $u if $o->{'gal'};

    $pg->{'picture'} = Picture({ 'u' => $u, 'pic' => $up, 'gal' => $o->{'gal'} });
    $pg->{'picture_prev'} = $o->{'picture_prev'} ?
                            Picture({ 'u' => $u, 'pic' => $o->{'picture_prev'}, 'gal' => $o->{'gal'} }) :
                            Null('Picture');
    $pg->{'picture_next'} = $o->{'picture_next'} ?
                            Picture({ 'u' => $u, 'pic' => $o->{'picture_next'}, 'gal' => $o->{'gal'} }) :
                            Null('Picture');

    # copy_url appears if remote exists. if the remote user didn't have access
    # to the pict, they wouldn't be able to view it at all.
    my $remote = FB::get_remote();
    $pg->{'copy_url'} = "$LJ::SITEROOT/manage/makecopy?user=$u->{usercs}&type=pic&id=" . $up->id
        if $remote && $remote->{user} ne $u->{user};

    $pg->{'manage_url'} = $up->manage_url;
    $pg->{'self_link'} = Link({ 'current_page' => 1,
                                'dest_view' => 'picture',
                                # FIXME: piccode is worst caption ever
                                'caption' => FB::ehtml($up->prop("pictitle") || $up->piccode),
                                'url' => $up->url_picture_page,
                            });
    $pg->{'gallery'} = $o->{'gal'} ? Gallery($o->{'gal'}) : Null("Gallery");
    $pg->{'pictures'} = $o->{'pictures'};
    $pg->{'des'} = $up->des_html;
    $pg->{'security'} = $up->secid;

    return $pg;
}

sub User
{
    my $u = shift;
    return {
        '_type' => 'User',
        '_userid' => $u->{'userid'},
        '_domainid' => $u->{'domainid'},
        'user' => $u->{'user'},
        'usercs' => $u->{'usercs'},
    };
}

sub load_gallery_data
{
    my $page = shift;
    return if $page->{'_gals'};  # already have it?
    my $sth;
    my $userid = $page->{'user'}->{'_userid'};
    my $u = $page->{'_u'};
    my $secin = $u->secin;

    # galleries
    my %gals;
    $sth = $u->prepare("SELECT * FROM gallery WHERE userid=? AND secid IN ($secin)",
                       $u->{userid});
    $sth->execute;
    while (my $g = $sth->fetchrow_hashref) {
        next if $g->{'name'} eq ":FB_in";
        $gals{$g->{'gallid'}} = $g;
    }
    $page->{'_gals'} = \%gals;

    # number of pictures in galleries
    $sth = $u->prepare("SELECT gallid, SUM(count) FROM gallerysize ".
                       "WHERE userid=? AND secid IN ($secin) GROUP BY gallid",
                       $u->{userid});
    $sth->execute;
    while (my ($id, $num) = $sth->fetchrow_array) {
        $gals{$id}->{'numpics'} = $num
            if $gals{$id};
    }

    # load relations
    my %children;
    $sth = $u->prepare("SELECT gallid, gallid2 FROM galleryrel ".
                       "WHERE userid=? AND type='C'", $u->{userid});
    $sth->execute;
    while (my ($from, $to) = $sth->fetchrow_array) {
        next unless ($from == 0 || exists $gals{$from});
        next unless exists $gals{$to};
        push @{$children{$from}}, $to;
    }
    $page->{'_galchildren'} = \%children;
}

sub add_child_galleries
{
    my $page = shift;
    my ($list, $gallid);
    if (ref $_[0] eq "HASH") {
        ($list, $gallid) = ($_[0]->{'children'}, $_[0]->{'_gallid'});
    } else {
        ($list, $gallid) = @_;
    }

    FB::S2::load_gallery_data($page);

    my $children = $page->{'_galchildren'};
    my $gals = $page->{'_gals'};

    my $add_children = sub {
        my ($self, $parentid, $list, $seen) = @_;

        return unless $children->{$parentid};
        foreach my $cid (sort {
            $gals->{$a}->{'name'} cmp $gals->{$b}->{'name'}
        } @{$children->{$parentid}}) {
            next if $seen->{$cid};
            my $seencopy = { %{$seen} };
            $seencopy->{$cid} = 1;

            my $g = $gals->{$cid};

            $g->{'u'} = $page->{'_u'};
            my $s2gal = FB::S2::Gallery($g);
            my $childlist = $s2gal->{'children'};

            $self->($self, $cid, $childlist, $seencopy);

            push @$list, $s2gal;
        }
    };

    my %seen;
    $add_children->($add_children, $gallid, $list, \%seen);
}

sub load_gallery_pics
{
    my ($page, $gallery) = @_;

    return if $gallery->{'_pics'};  # already have it?
    my $u = $page->{'_u'};
    my $userid = $u->{'userid'};
    my $gallid = $gallery->{'_gallid'};

    my @pics = FB::get_gallery_pictures($u, $gallid, $u->secin);
    $gallery->{'_pics'} = \@pics;
}

sub set_context
{
    $FB::S2::curr_ctx = shift;
}

package S2::Builtin;

sub int__zeropad
{
    my ($ctx, $this, $digits) = @_;
    $digits += 0;
    sprintf("%0${digits}d", $this);
}

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

sub string__startswith
{
    use utf8;
    my ($ctx, $this, $str) = @_;
    return $this =~ /^\Q$str\E/;
}

sub string__endswith
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

sub alter_url
{
    my $ctx = shift;
    my $url = ref $_[0] eq "HASH" ? undef : shift;
    my $newargs = shift;

    # get URL of current page
    my $args;
    my %args;
    if ($url) {
        ($url, $args) = split(/\?/, $url);
        foreach my $pair (split(/&/, $args)) {
            my ($k, $v) = split(/=/, $pair);
            $args{FB::durl($k)} = FB::durl{$v};
        }
    } else {
        $url = Apache->request->uri;
        %args = Apache->request->args;
    }

    foreach (keys %$newargs) {
        $args{$_} = $newargs->{$_};
    }

    if (%args) {
        $url .= "?";
        while (my ($k, $v) = each %args) {
            $url .= FB::eurl($k) . "=" . FB::eurl($v) . "&";
        }
        chop $url;
    }

    return $url;
}

sub viewer_logged_in
{
    return FB::get_remote() ? 1 : 0;
}

sub viewer_is_owner
{
    my $remote = FB::get_remote();
    return 0 unless $remote;
    return 0 unless $S2FotoBilder::CURR_PAGE->{'user'};
    return 0 unless $remote->{'user'} eq $S2FotoBilder::CURR_PAGE->{'user'}->{'user'};
}

sub ehtml
{
    my ($ctx, $text) = @_;
    return FB::ehtml($text);
}

sub ejs
{
    my ($ctx, $text) = @_;
    return FB::ejs($text);
}

sub get_page
{
    return $S2FotoBilder::CURR_PAGE;
}

sub load_gallery_previews
{
    # TODO: implement
}

sub palimg_create
{
    my ($ctx, $spec) = @_;
    my ($res, $w, $h, @pals) = split(/\|/, $spec);

    # absolute URLs stay (reference to GIF/PNG upics, perhaps), but rest go to img dir
    $res = "/img/$res" unless $res =~ m!^http://!;

    $res .= "/p";
    my $idx = -1;
    foreach my $prop (@pals) {
        $idx++;
        next unless $prop;
        $res .= sprintf("%1x", $idx);
        $res .= substr($ctx->[2]->{$prop}->{'as_string'}, 1, 6);
    }

    my $pic = {
        '_type' => 'Image',
        'width' => $w,
        'height' => $h,
        'url' => $res,
    };

    return $pic;
}

sub palimg_modify
{
    my ($ctx, $filename, $items) = @_;
    return undef unless $filename =~ /^\w[\w\/\-]*\.(gif|png)$/;
    my $url = "$FB::SITEROOT/img/$filename";
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
    my $url = "$FB::SITEROOT/img/$filename";
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
    my $url = "$FB::SITEROOT/img/$filename";
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

sub rand_pic
{
    my ($ctx, $pics) = @_;
    return $pics->[S2::Builtin::rand($ctx, $pics)];
}

sub set_content_type
{
    my ($ctx, $type) = @_;
    $ctx->[3]->{'ctype'} = $type;
}

sub set_http_status
{
    my ($ctx, $num) = @_;
    $ctx->[3]->{'status'} = $num;
}

sub GalleryPage__load_pict_descriptions
{
    my ($ctx, $this) = @_;
    return undef if $this->{'_loaded_pict_descs'};

    my @pic_ids;
    foreach my $pic (@{$this->{'pictures'}}) {
        next if $pic->{'des'};
        push @pic_ids, $pic->{'_upicid'};
    }

    my $u = $this->{'_u'};
    my $getdes = $u->prepare("SELECT itemid,des FROM des WHERE userid=? AND ".
                             "itemtype='P' AND itemid IN (" .
                             (join ', ', @pic_ids) .
                             ")", $u->{userid});
    $getdes->execute;
    while (my @dpair = $getdes->fetchrow_array) {
        my ($itemid, $des) = @dpair;
        foreach my $pic (@{$this->{'pictures'}}) {
            next if $itemid != $pic->{'_upicid'};
            if ($des) {
                $des = FB::ehtml($des);
                $des =~ s!\n!<br />!g;
                $pic->{'des'} = $des;
            }
        }
    }

    $this->{'_loaded_pict_descs'} = 1;
}

sub GalleryBasic__get_preview_image
{
    my ($ctx, $this, $style) = @_;

    my %fmts_by_name = FB::get_thumb_formats($ctx);
    return undef unless %fmts_by_name;
    return undef unless $fmts_by_name{$style};

    my $gallid = $this->{'_gallid'}+0;
    return undef unless $gallid;

    my $page = $S2FotoBilder::CURR_PAGE;
    my $u = $page->{'_u'};
    my $userid = $u->{'userid'};
    my $s2u = $page->{'user'};
    my $remote = FB::get_remote();

    # get the previewpicid, if it hasn't already been loaded
    unless (exists $this->{'_previewpicid'}) {
        $this->{'_previewpicid'} = $u->selectrow_array(qq{
            SELECT value FROM galleryprop WHERE userid=? AND gallid=?
            AND propid=?
        }, $userid, $gallid, FB::get_props()->{'previewpicid'});
    }

    my $ppid = $this->{'_previewpicid'};
    return undef unless int($ppid);

    my $up = FB::load_upic($u, $ppid);
    return undef unless $up;
    return undef unless FB::can_view_picture($u, $up, $remote);
    return FB::S2::Image(FB::url_thumbnail($page->{'_u'}, $up, $fmts_by_name{$style}));
}

*Gallery__get_preview_image = \&GalleryBasic__get_preview_image;

sub ItemRange__url_of
{
    my ($ctx, $this, $n) = @_;
    return "" unless ref $this->{'_url_of'} eq "CODE";
    return $this->{'_url_of'}->($n+0);
}

sub Picture__get_image
{
    my ($ctx, $this, $w, $h) = @_;
    my $user = get_page()->{'user'}->{'user'};

    $w += 0; $h += 0;
    return FB::S2::Null("Image") unless FB::valid_scaling($w, $h);

    my $up = $this->{'_upic'};
    my ($url, $nw, $nh) = $up->scaled_url($w, $h);

    return FB::S2::Image($url, $nw, $nh);
}

sub PicturePage__get_thumbnail
{
    my ($ctx, $this, $keyword, $index) = @_;
    return undef unless
        $this->{'gallery'} &&
        $this->{'gallery'}->{'_gallid'};

    my %fmts_by_name = FB::get_thumb_formats($ctx);
    return undef unless %fmts_by_name;
    return undef unless $fmts_by_name{$keyword};

    FB::S2::load_gallery_pics($this, $this->{'gallery'});

    my $p = $this->{'gallery'}->{'_pics'};
    $index--;  # 1 based to 0 based index

    return undef if $index > scalar @$p;
    return undef if $index < 0;

    my $pic = $p->[$index];
    return undef unless $pic;

    return FB::S2::Image(FB::url_thumbnail($this->{'user'}->{'user'}, $pic,
                                           $fmts_by_name{$keyword}));

}

sub PicturePage__get_exif_tag_info
{
    my ($ctx, $this) = @_;

    return $this->{_cache_exif_info} if exists $this->{_cache_exif_info};

    my $u = $this->{_u};
    my $pic = $this->{picture}->{_upic};

    return $this->{_cache_exif_info} = FB::upic_exif_info($u, $pic) || {};
}

# hashref of all exif categories
sub PicturePage__get_exif_cat_info
{
    my ($ctx, $this) = @_;

    my $cat_info = S2::EXIF::get_cat_info();

    # hashref of key => name
    foreach (keys %{$cat_info||{}}) {
        my $tag_order = PicturePage__get_exif_tag_order($ctx, $this, $_);
        delete $cat_info->{$_} unless @{$tag_order||[]};
    }

    return $cat_info;
}

# return exif tags in order with respect to their category
sub PicturePage__get_exif_tag_order
{
    my ($ctx, $this, $cat) = @_;

    my $tag_info = PicturePage__get_exif_tag_info($ctx, $this);

    # category specified
    if ($cat) {
        return [ grep { $tag_info->{$_} } S2::EXIF::get_cat_tags($cat) ];
    }

    # all categories
    return [ grep { $tag_info->{$_} } S2::EXIF::get_all_tags() ];
}

# get non-empty categories in order
sub PicturePage__get_exif_cat_order
{
    my ($ctx, $this) = @_;

    my $tag_info = PicturePage__get_exif_tag_info($ctx, $this);
    my @cat_order = S2::EXIF::get_cat_order();

    # array of cat keys in order
    my @ret = ();
    foreach my $currcat (@cat_order) {
        my @cat_tags = S2::EXIF::get_cat_tags($currcat);
        push @ret, $currcat if scalar(grep { $tag_info->{$_} } @cat_tags);
    }

    return \@ret;
}

1;

