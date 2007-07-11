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
