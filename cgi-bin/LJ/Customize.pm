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
        'featured' => 'Featured',
        'sponsored' => 'Sponsored',
        'animals' => 'Animals',
        'clean' => 'Clean/Simple',
        'cool' => 'Cool Colors',
        'warm' => 'Warm Colors',
        'cute' => 'Cute',
        'dark' => 'Dark',
        'food' => 'Food/Drink',
        'hobbies' => 'Hobbies',
        'illustrated' => 'Illustrated',
        'media' => 'Media',
        'modern' => 'Modern',
        'nature' => 'Nature',
        'occasions' => 'Occasions',
        'pattern' => 'Pattern/Texture',
        'tech' => 'Tech',
        'travel' => 'Travel',
    );
}

sub get_layouts {
    return (
        '1'    => '1 Column (no sidebar)',
        '2l'   => '2 Column (sidebar on left)',
        '2r'   => '2 Column (sidebar on right)',
        '2lnh' => '2 Column (sidebar on left; no header)',
        '2rnh' => '2 Column (sidebar on right; no header)',
        '3l'   => '3 Column (content on left)',
        '3m'   => '3 Column (content in middle)',
    );
}

1;
