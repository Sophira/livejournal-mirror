=comment

LJ::Text module: a module that contains miscellaneous string functions that are
ensured to work correctly with non-decoded UTF-8 strings LJ uses.

It is supposed to eventually replace ljtextutil.pl; we need to get rid of that
module for the following reasons:

 * it clutters the LJ:: global namespace,
 * it uses weird (really weird) regular expressions to work with strings; using
   the standard Encode Perl module is deemed better.

The calling convention for this module is that all functions must be called
as class methods: LJ::Text->$subname. Failure to call a method in this manner
results in a fatal error.

String manipulations in this module are never done in-place; if you need to
"manip" $str in-place, do it like $str = LJ::Text->manip($str), not like
LJ::Text->manip($$str).*

UTF-8 strings in this module are passed undecoded and returned undecoded. Should
you need to pass a decoded string, be sure to do Encode::encode_utf8 before you
call and Encode::decode_utf8 afterwards.

The error handling convention is that fatal errors throw Perl die's with
stack traces attached; non-fatal errors throw Perl warn's with stack traces
attached. The standard Carp module (namely, confess and cluck subs) are used
for throwing errors.

Related modules:

 * ljtextutil.pl
 * LJ::ConvUTF8 (?)
 
Notes:

 * There is no actual "manip" method in this module; it is only being used as
   an example.

=cut

package LJ::Text;

use Encode qw(encode_utf8 decode_utf8);
use Carp qw(confess cluck);
use UNIVERSAL qw(isa);
use strict;

# given a string, returns its length in bytes (that is, actual octets needed to
# represent all characters in that string)
sub byte_len {
    my ($class, $str) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    return length($str);
}

# given a string, returns its length in characters
sub char_len {
    my ($class, $str) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    $str = decode_utf8($str);
    return length($str);
}

# given a string, tries to parse it as UTF-8; if it fails, the string is
# truncated at the first invalid octet sequence. the resulting string is
# returned.
sub fix_utf8 {
    my ($class, $str) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    $str = decode_utf8($str, Encode::FB_QUIET());
    return encode_utf8($str);
}

# given a string, returns its longest UTF-8 "prefix" (that is, its
# 'substr($str, 0, $something)' kind of substring) that doesn't exceed the given
# number of bytes.
sub truncate_to_bytes {
    my ($class, $str, $bytes) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    $str = substr($str, 0, $bytes);
    return $class->fix_utf8($str);
}

# given a string, returns its first $chars UTF-8 characters. if the string is
# longer, the entire string is returned.
sub truncate_to_chars {
    my ($class, $str, $chars) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    $str = decode_utf8($str);
    $str = substr($str, 0, $chars);
    return encode_utf8($str);
}

# given a string and optionally numbers of characters and bytes, truncates
# it so that the resulting string is no longer than $bytes bytes and $chars
# characters.
#
# its arguments are coerced to a hash, so you may wish to call it like this:
#
# $str = LJ::Text->truncate(
#     str => $str,
#     chars => $chars, # optional
#     bytes => $bytes, # optional
# );
#
# see also: truncate_to_bytes, truncate_to_chars.
sub truncate {
    my ($class, @opts) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    confess "cannot coerce options to hash: " . Dumper(\@opts)
        unless scalar(@opts) % 2 == 0;

    my %opts = @opts;

    my $str = delete $opts{'str'};
    my $bytes = delete $opts{'bytes'};
    my $chars = delete $opts{'chars'};

    confess "unknown options: " . Data::Dumper(\%opts)
        if %opts;

    cluck "not actually truncating"
        unless $bytes || $chars;

    $str = $class->truncate_to_bytes($str, $bytes) if $bytes;
    $str = $class->truncate_to_chars($str, $chars) if $chars;

    return $str;
}

# given a string and optionally numbers of characters and bytes, truncates
# it and adds an ellipsis ('...'-like UTF-8 symbol) so that the resulting 
# string is no longer than $bytes bytes and $chars characters.
#
# its arguments are coerced to a hash, so you may wish to call it like this:
#
# $str = LJ::Text->truncate(
#     str => $str,
#     chars => $chars, # optional
#     bytes => $bytes, # optional
#     ellipsis => '...', # optional, defaults to the "\x{2026}" Unicode char
# );
#
# see also: truncate_to_bytes, truncate_to_chars.
sub truncate_with_ellipsis {
    my ($class, @opts) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    confess "cannot coerce options to hash: " . Dumper(\@opts)
        unless scalar(@opts) % 2 == 0;

    my %opts = @opts;

    my $str = delete $opts{'str'};
    my $bytes = delete $opts{'bytes'};
    my $chars = delete $opts{'chars'};
    my $ellipsis = delete $opts{'ellipsis'} || Encode::encode_utf8("\x{2026}");

    confess "unknown options: " . Data::Dumper(\%opts)
        if %opts;

    cluck "not actually truncating"
        unless $bytes || $chars;

    if ($bytes && $class->byte_len($str) > $bytes) {
        my $bytes_trunc = $bytes - $class->byte_len($ellipsis);
        $str = $class->truncate(
            'str' => $str,
            'bytes' => $bytes_trunc
        ) . $ellipsis;
    }

    if ($chars && $class->char_len($str) > $chars) {
        my $chars_trunc = $chars - $class->char_len($ellipsis);
        $str = $class->truncate(
            'str' => $str,
            'chars' => $chars_trunc
        ) . $ellipsis;
    }

    return $str;
}

sub truncate_to_word_with_ellipsis {
    my ($class, @opts) = @_;

    confess "must be called as a class method"
        unless isa($class, __PACKAGE__);

    confess "cannot coerce options to hash: " . Dumper(\@opts)
        unless scalar(@opts) % 2 == 0;

    my %opts = @opts;

    my $str = delete $opts{'str'};
    my $original_string = $str;
    my $bytes = delete $opts{'bytes'};
    my $chars = delete $opts{'chars'};
    my $remainder = '';
    my $ellipsis = delete $opts{'ellipsis'} || Encode::encode_utf8("\x{2026}");

    confess "unknown options: " . Data::Dumper(\%opts)
        if %opts;

    cluck "not actually truncating"
        unless $bytes || $chars;

    my $remove_last_word = sub {
        my ($str) = @_;

        if ($str =~ /\s+$/) {
            $str =~ s/\s+$//;
        } else {
            $str =~ s/\s*\S+$//;
        }

        return $str;
    };

    if ($bytes && $class->byte_len($str) > $bytes) {
        my $bytes_trunc = $bytes - $class->byte_len($ellipsis);
        $str = $class->truncate(
            'str' => $str,
            'bytes' => $bytes_trunc + 1
        );

        $str = $remove_last_word->($str);
        $remainder = substr($original_string, $class->byte_len($str));
        $str .= $ellipsis;
    }

    if ($chars && $class->char_len($str) > $chars) {
        my $chars_trunc = $chars - $class->char_len($ellipsis);
        $str = $class->truncate(
            'str' => $str,
            'chars' => $chars_trunc + 1
        );

        $str = $remove_last_word->($str);
        $remainder = substr($original_string, $class->byte_len($str));
        $str .= $ellipsis;
    }

    $remainder =~ s/^\s+//;
    return wantarray ? ($str, $remainder) : $str;
}

1;
