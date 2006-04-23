package LJ::Setting::TextSetting;
use base 'LJ::Setting';
use strict;
use warnings;
use Carp qw(croak);

sub current_value {
    my ($class, $u) = @_;
    croak;
}

sub text_size { 40 }

sub question { croak; }

sub as_html {
    my ($class, $u, $errs) = @_;
    my $key = $class->pkgkey;
    return $class->question .
        LJ::html_text({
            name  => "${key}txt",
            value => $class->current_value($u),
            size  => $class->text_size,
        }) .
        $class->errdiv($errs, "txt");
}

sub save {
    my ($class, $u, $args) = @_;
    my $txt = $args->{txt};
    return 1 if $txt eq $class->current_value($u);
    unless (LJ::text_in($txt)) {
        $class->errors(txt => "Invalid UTF-8");
    }
    return $class->save_text($u, $txt);
}

sub save_text {
    my ($class, $u, $txt) = @_;
    croak;
}

1;



