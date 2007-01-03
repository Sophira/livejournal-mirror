# this is a small wrapper around Unicode::MapUTF8, just so we can lazily-load it easier
# with Class::Autouse, and so we have a central place to init its charset aliases.
# and in the future if we switch transcoding packages, we can just do it here.
package LJ::ConvUTF8;

use strict;
use warnings;
use Unicode::MapUTF8 ();

BEGIN {
    # declare some charset aliases
    # we need this at least for cases when the only name supported
    # by MapUTF8.pm isn't recognized by browsers
    # note: newer versions of MapUTF8 know these
    {
        my %alias = ( 'windows-1251' => 'cp1251',
                      'windows-1252' => 'cp1252',
                      'windows-1253' => 'cp1253', );
        foreach (keys %alias) {
            next if Unicode::MapUTF8::utf8_supported_charset($_);
            Unicode::MapUTF8::utf8_charset_alias($_, $alias{$_});
        }
    }
}

sub supported_charset {
    my ($class, $charset) = @_;
    return Unicode::MapUTF8::utf8_supported_charset($charset);
}

sub from_utf8 {
    my ($class, $from_enc, $str) = @_;
    return Unicode::MapUTF8::from_utf8({ -string=> $str, -charset => $from_enc });
}

sub to_utf8 {
    my ($class, $to_enc, $str) = @_;
    return Unicode::MapUTF8::from_utf8({ -string=> $str, -charset => $to_enc });
}

1;


