package LJ::Customize;
use strict;
use Carp qw(croak);

require "$ENV{'LJHOME'}/cgi-bin/customizelib.pl";

# returns the S2Theme object of the given user's current theme
sub get_current_theme {
    my $class = shift;
    my $u = shift;

    die "Invalid user object." unless LJ::isu($u);

    my $pub = LJ::S2::get_public_layers();
    my $userlay = LJ::S2::get_layers_of_user($u);
    my %style = LJ::S2::get_style($u, { verify => 1, force_layers => 1 });

    if ($style{theme} == 0) {
        # default theme of system layout
        if (ref $pub->{$style{layout}}) {
            return LJ::S2Theme->load_default_of($style{layout});

        # default theme of custom layout
        } elsif (ref $userlay->{$style{layout}}) {
            return LJ::S2Theme->load_custom_layoutid($style{layout}, $u);
        } else {
            die "Theme is neither system nor custom.";
        }
    } else {
        return LJ::S2Theme->load_by_themeid($style{theme}, $u);
    }
}

# applies the given theme to the given user's journal
sub apply_theme {
    my $class = shift;
    my $u = shift;
    my $theme = shift;

    my %style;
    my $has_cap = $u->get_cap("s2styles");
    my $pub = LJ::S2::get_public_layers();
    my $userlay = LJ::S2::get_layers_of_user($u);

    die "Your account status does not allow access to this custom layer."
        if $theme->is_custom && !$has_cap;
    die "You cannot use this theme."
        unless $theme->available_to($u);
    die "No core parent."
        unless $theme->coreid;

    # delete s2_style and replace it with a new
    # or existing style for this theme
    $u->set_prop("s2_style", '');

    $style{theme} = $theme->themeid;
    $style{layout} = $theme->layoutid;
    $style{core} = $theme->coreid;

    # if a style for this theme already exists, set that as the user's style
    my $styleid = $theme->get_styleid_for_theme($u);
    if ($styleid) {
        $u->set_prop("s2_style", $styleid);

        # now we have to populate %style from this style
        # theme, layout, and core have already been set
        my $stylay = LJ::S2::get_style_layers($u, $u->prop('s2_style'));
        foreach my $layer (qw(user i18nc i18n)) {
            $style{$layer} = exists $stylay->{$layer} ? $stylay->{$layer} : 0;
        }

    # no existing style found, create a new one
    } else {
        $style{user} = $style{i18nc} = $style{i18n} = 0;
    }

    # set style
    $class->implicit_style_create($u, %style);
}

# wrapper around LJ::cmize::s2_implicit_style_create
sub implicit_style_create {
    my $class = shift;
    my ($opts, $u, %style);

    # this is because the arguments aren't static
    # old callers don't pass in an options hashref, so we create a blank one
    if (ref $_[0] && ref $_[1]) {
        ($opts, $u) = (shift, shift);
    } else {
        ($opts, $u) = ({}, shift);
    }

    # everything else is part of the style hash
    %style = ( @_ );

    return LJ::cmize::s2_implicit_style_create($opts, $u, %style);
}

# given a layout id, get the layout's name
sub get_layout_name {
    my $class = shift;
    my $layoutid = shift;
    my %opts = @_;

    my $pub = LJ::S2::get_public_layers();
    my $userlay = $opts{user} ? LJ::S2::get_layers_of_user($opts{user}) : "";

    my $layout_name = LJ::Lang::ml('customize.layoutname.default');
    $layout_name = $pub->{$layoutid}->{name} if $pub->{$layoutid} && $pub->{$layoutid}->{name};
    $layout_name = $userlay->{$layoutid}->{name} if ref $userlay && $userlay->{$layoutid} && $userlay->{$layoutid}->{name};

    return $layout_name;
}

sub get_layerids {
    my $class = shift;
    my $style = shift;

    my $dbh = LJ::get_db_writer();
    my $layer = LJ::S2::load_layer($dbh, $style->{'layer'}->{'user'});
    my $lyr_layout = LJ::S2::load_layer($dbh, $layer->{'b2lid'});
    die "Layout layer for this $layer->{'type'} layer not found." unless $lyr_layout;
    my $lyr_core = LJ::S2::load_layer($dbh, $lyr_layout->{'b2lid'});
    die "Core layer for layout not found." unless $lyr_core;

    my @layers;
    push @layers, ([ 'core' => $lyr_core->{'s2lid'} ],
                   [ 'i18nc' => $style->{'layer'}->{'i18nc'} ],
                   [ 'layout' => $lyr_layout->{'s2lid'} ],
                   [ 'i18n' => $style->{'layer'}->{'i18n'} ]);
    if ($layer->{'type'} eq "user" && $style->{'layer'}->{'theme'}) {
        push @layers, [ 'theme' => $style->{'layer'}->{'theme'} ];
    }
    push @layers, [ $layer->{'type'} => $layer->{'s2lid'} ];

    my @layerids = grep { $_ } map { $_->[1] } @layers;

    return @layerids;
}

sub load_all_s2_props {
    my $class = shift;
    my $u = shift;
    my $style = shift;

    my %s2_style = LJ::S2::get_style($u, "verify");

    unless ($style->{layer}->{user}) {
        $style->{layer}->{user} = LJ::S2::create_layer($u->{userid}, $style->{layer}->{layout}, "user");
        die "Could not generate user layer" unless $style->{layer}->{user};
        $s2_style{user} = $style->{layer}->{user};
    }

    LJ::cmize::s2_implicit_style_create($u, %s2_style);

    my $dbh = LJ::get_db_writer();
    my $layer = LJ::S2::load_layer($dbh, $style->{'layer'}->{'user'});

    # if the b2lid of this layer has been remapped to a new layerid
    # then update the b2lid mapping for this layer
    my $b2lid = $layer->{b2lid};
    if ($b2lid && $LJ::S2LID_REMAP{$b2lid}) {
        LJ::S2::b2lid_remap($u, $style->{'layer'}->{'user'}, $b2lid);
        $layer->{b2lid} = $LJ::S2LID_REMAP{$b2lid};
    }

    die "Layer belongs to another user. $layer->{userid} vs $u->{userid}" unless $layer->{'userid'} == $u->{'userid'};
    die "Layer isn't of type user or theme." unless $layer->{'type'} eq "user" || $layer->{'type'} eq "theme";

    my @layerids = $class->get_layerids($style);
    LJ::S2::load_layers(@layerids);

    # load the language and layout choices for core.
    my %layerinfo;
    LJ::S2::load_layer_info(\%layerinfo, \@layerids);

    return;
}

sub save_s2_props {
    my $class = shift;
    my $u = shift;
    my $style = shift;
    my $post = shift;
    my %opts = @_;

    my $dbh = LJ::get_db_writer();
    my $layer = LJ::S2::load_layer($dbh, $style->{'layer'}->{'user'});
    my $layerid = $layer->{'s2lid'};

    if ($opts{remove}) {
        my %s2_style = LJ::S2::get_style($u, "verify");

        LJ::S2::delete_layer($s2_style{'user'});
        $s2_style{'user'} = LJ::S2::create_layer($u->{userid}, $s2_style{'layout'}, "user");
        LJ::S2::set_style_layers($u, $u->{'s2_style'}, "user", $s2_style{'user'});
        $layerid = $s2_style{'user'};
    } else {
        my $lyr_layout = LJ::S2::load_layer($dbh, $layer->{'b2lid'});
        die "Layout layer for this $layer->{'type'} layer not found." unless $lyr_layout;
        my $lyr_core = LJ::S2::load_layer($dbh, $lyr_layout->{'b2lid'});
        die "Core layer for layout not found." unless $lyr_core;

        $lyr_layout->{'uniq'} = $dbh->selectrow_array("SELECT value FROM s2info WHERE s2lid=? AND infokey=?",
                                                  undef, $lyr_layout->{'s2lid'}, "redist_uniq");

        my %override;
        foreach my $prop (S2::get_properties($lyr_layout->{'s2lid'}))
        {
            $prop = S2::get_property($lyr_core->{'s2lid'}, $prop)
                unless ref $prop;
            next unless ref $prop;
            next if $prop->{'noui'};
            my $name = $prop->{'name'};
            next unless LJ::S2::can_use_prop($u, $lyr_layout->{'uniq'}, $name);

            my %prop_values = $class->get_s2_prop_values($name, $style);
            my $prop_value = defined $post->{$name} ? $post->{$name} : $prop_values{override};
            next if $prop_value eq $prop_values{existing};
            $override{$name} = [ $prop, $prop_value ];
        }

        if (LJ::S2::layer_compile_user($layer, \%override)) {
            # saved
        } else {
            my $error = LJ::last_error();
            die "Error saving layer: $error";
        }
    }
    LJ::S2::load_layers($layerid);

    return;
}

# returns hash with existing (parent) prop value and override (user layer) prop value
sub get_s2_prop_values {
    my $class = shift;
    my $prop_name = shift;
    my $style = shift;

    my $dbh = LJ::get_db_writer();
    my $layer = LJ::S2::load_layer($dbh, $style->{'layer'}->{'user'});

    # figure out existing value (if there was no user/theme layer)
    my $existing;
    my @layerids = $class->get_layerids($style);
    foreach my $lid (reverse @layerids) {
        next if $lid == $layer->{'s2lid'};
        $existing = S2::get_set($lid, $prop_name);
        last if defined $existing;
    }

    if (ref $existing eq "HASH") { $existing = $existing->{'as_string'}; }

#    if ($type eq "bool") {
#        $prop->{'values'} ||= "1|Yes|0|No";
#    }

#    my %values = split(/\|/, $prop->{'values'});
#    my $existing_display = defined $values{$existing} ?
#        $values{$existing} : $existing;

#    $existing_display = LJ::eall($existing_display);

    my $override = S2::get_set($layer->{'s2lid'}, $prop_name);
    my $had_override = defined $override;
    $override = $existing unless defined $override;

    if (ref $override eq "HASH") { $override = $override->{'as_string'}; }

    return ( existing => $existing, override => $override );
}

sub propgroup_name {
    my $class = shift;
    my $gname = shift;
    my $style = shift;

    my $dbh = LJ::get_db_writer();
    my $layer = LJ::S2::load_layer($dbh, $style->{'layer'}->{'user'});
    my $lyr_layout = LJ::S2::load_layer($dbh, $layer->{'b2lid'});
    die "Layout layer for this $layer->{'type'} layer not found." unless $lyr_layout;
    my $lyr_core = LJ::S2::load_layer($dbh, $lyr_layout->{'b2lid'});
    die "Core layer for layout not found." unless $lyr_core;

    foreach my $lid ($style->{'layer'}->{'i18n'}, $lyr_layout->{'s2lid'}, $style->{'layer'}->{'i18nc'}, $lyr_core->{'s2lid'}) {
        next unless $lid;
        my $name = S2::get_property_group_name($lid, $gname);
        return LJ::ehtml($name) if $name;
    }
    return "Misc" if $gname eq "misc";
    return $gname;
}

sub s2_upsell {
    my $class = shift;
    my $getextra = shift;

    my $ret .= "<?standout ";
    $ret .= "<p>This style system is no longer supported.</p>";
    $ret .= "<p><a href='$LJ::SITEROOT/customize2/switch_system.bml$getextra'><strong>Switch to S2</strong></a> for the latest features and themes.</p>";
    $ret .= " standout?>";

    return $ret;
}

sub get_cats {
    return (
        all => {
            text => LJ::Lang::ml('customize.cats.all'),
            main => 1,
            order => 2,
        },
        featured => {
            text => LJ::Lang::ml('customize.cats.featured'),
            main => 1,
            order => 1,
        },
        special => {
            text => LJ::Lang::ml('customize.cats.special'),
            main => 1,
            order => 3,
        },
        custom => {
            text => LJ::Lang::ml('customize.cats.custom'),
            main => 1,
            order => 4,
        },
        animals => {
            text => LJ::Lang::ml('customize.cats.animals'),
        },
        clean => {
            text => LJ::Lang::ml('customize.cats.clean'),
        },
        cool => {
            text => LJ::Lang::ml('customize.cats.cool'),
        },
        warm => {
            text => LJ::Lang::ml('customize.cats.warm'),
        },
        cute => {
            text => LJ::Lang::ml('customize.cats.cute'),
        },
        dark => {
            text => LJ::Lang::ml('customize.cats.dark'),
        },
        food => {
            text => LJ::Lang::ml('customize.cats.food'),
        },
        hobbies => {
            text => LJ::Lang::ml('customize.cats.hobbies'),
        },
        illustrated => {
            text => LJ::Lang::ml('customize.cats.illustrated'),
        },
        media => {
            text => LJ::Lang::ml('customize.cats.media'),
        },
        modern => {
            text => LJ::Lang::ml('customize.cats.modern'),
        },
        nature => {
            text => LJ::Lang::ml('customize.cats.nature'),
        },
        occasions => {
            text => LJ::Lang::ml('customize.cats.occasions'),
        },
        pattern => {
            text => LJ::Lang::ml('customize.cats.pattern'),
        },
        tech => {
            text => LJ::Lang::ml('customize.cats.tech'),
        },
        travel => {
            text => LJ::Lang::ml('customize.cats.travel'),
        },
    );
}

sub get_layouts {
    return (
        '1'    => LJ::Lang::ml('customize.layouts.1'),
        '2l'   => LJ::Lang::ml('customize.layouts.2l'),
        '2r'   => LJ::Lang::ml('customize.layouts.2r'),
        '2lnh' => LJ::Lang::ml('customize.layouts.2lnh'),
        '2rnh' => LJ::Lang::ml('customize.layouts.2rnh'),
        '3l'   => LJ::Lang::ml('customize.layouts.3l'),
        '3m'   => LJ::Lang::ml('customize.layouts.3m'),
    );
}

1;
