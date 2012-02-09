package LJ::Setting::ImagePlaceholders;
use base 'LJ::Setting';
use strict;
use warnings;
no warnings 'uninitialized';

sub should_render {
    my ($class, $u) = @_;

    return !$u || $u->is_community ? 0 : 1;
}

sub helpurl {
    my ($class, $u) = @_;

    return "image_placeholders_full";
}

sub label {
    my $class = shift;

    return $class->ml('setting.imageplaceholders.label');
}

sub option {
    my ($class, $u, $errs, $args) = @_;
    my $key = $class->pkgkey;

    my $imgplaceholders = $class->get_arg($args, "imgplaceholders") || $u->prop("opt_imagelinks");

    my ($maxwidth, $maxheight) = (0, 0);
    ($maxwidth, $maxheight) = ($1, $2)
        if $imgplaceholders and $imgplaceholders =~ /^(\d+)\|(\d+)$/;

    my $is_stock = grep { $imgplaceholders eq $_ }
                    (qw/320|240 640|480 0|0/, ''); # standard sizes

    my $extra = undef;
    $extra = $class->ml('setting.imageplaceholders.option.select.custom', { width => $maxwidth, height => $maxheight })
        unless $is_stock;

    my @options = (
        "0" => $class->ml('setting.imageplaceholders.option.select.none'),
        "0|0" => $class->ml('setting.imageplaceholders.option.select.all'),
        "320|240" => $class->ml('setting.imageplaceholders.option.select.medium', { width => 320, height => 240 }),
        "640|480" => $class->ml('setting.imageplaceholders.option.select.large', { width => 640, height => 480 }),
        $extra ? ("$maxwidth|$maxheight" => $extra) : ()
    );

    my $ret = "<label for='${key}imgplaceholders'>" . $class->ml('setting.imageplaceholders.option') . "</label> ";
    $ret .= LJ::html_select({
        name => "${key}imgplaceholders",
        id => "${key}imgplaceholders",
        selected => $imgplaceholders,
    }, @options);

    my $errdiv = $class->errdiv($errs, "imgplaceholders");
    $ret .= "<br />$errdiv" if $errdiv;

    return $ret;
}

sub error_check {
    my ($class, $u, $args) = @_;
    my $val = $class->get_arg($args, "imgplaceholders");

    $class->errors( imgplaceholders => $class->ml('setting.imageplaceholders.error.invalid') )
        unless !$val || $val =~ /^(\d+)\|(\d+)$/;

    return 1;
}

sub save {
    my ($class, $u, $args) = @_;
    $class->error_check($u, $args);

    my $val = $class->get_arg($args, "imgplaceholders");
    $u->set_prop( opt_imagelinks => $val );

    return 1;
}

1;
