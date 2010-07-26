package LJ::Talk::Author;
use strict;

use Carp qw();

my %code_map;

sub short_code {
    my ($class) = @_;
    $class =~ s/^LJ::Talk::Author:://;
    return $class;
}

sub all {
    return map { "LJ::Talk::Author::$_" } @LJ::TALK_METHODS_ORDER;
}

sub find_class {
    my ($class, $code) = @_;
    return $code_map{$code};
}

sub display_params {
    my ($class, $opts) = @_;

    my $remote = LJ::get_remote();

    return {};
}

sub handle_form_submission {
    my ($class, $entry, $errors) = @_;

    Carp::confess "short_code must be overridden in a subclass";

    my $remote = LJ::get_remote();
    $errors ||= [];

    push @$errors, "example error";
    return;
}

sub want_user_input { 0 }

# initialization code here
foreach my $method (@LJ::TALK_METHODS_ORDER) {
    my $package = "LJ::Talk::Author::$method";
    eval "use $package";
    die $@ if $@;
    $code_map{$package->short_code} = $package;
}

1;
