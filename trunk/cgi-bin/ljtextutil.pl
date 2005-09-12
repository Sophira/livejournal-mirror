package LJ;
use strict;

# <LJFUNC>
# name: LJ::trim
# class: text
# des: Removes whitespace from left and right side of a string.
# args: string
# des-string: string to be trimmed
# returns: string trimmed
# </LJFUNC>
sub trim
{
    my $a = $_[0];
    $a =~ s/^\s+//;
    $a =~ s/\s+$//;
    return $a;
}

# <LJFUNC>
# name: LJ::eurl
# class: text
# des: Escapes a value before it can be put in a URL.  See also [func[LJ::durl]].
# args: string
# des-string: string to be escaped
# returns: string escaped
# </LJFUNC>
sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

# <LJFUNC>
# name: LJ::durl
# class: text
# des: Decodes a value that's URL-escaped.  See also [func[LJ::eurl]].
# args: string
# des-string: string to be decoded
# returns: string decoded
# </LJFUNC>
sub durl
{
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

# <LJFUNC>
# name: LJ::exml
# class: text
# des: Escapes a value before it can be put in XML.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </LJFUNC>
sub exml
{
    # fast path for the commmon case:
    return $_[0] unless $_[0] =~ /[&\"\'<>\x00-\x08\x0B\x0C\x0E-\x1F]/;
    # what are those character ranges? XML 1.0 allows:
    # #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]

    my $a = shift;
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&apos;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    $a =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;
    return $a;
}

# <LJFUNC>
# name: LJ::ehtml
# class: text
# des: Escapes a value before it can be put in HTML.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </LJFUNC>
sub ehtml
{
    # fast path for the commmon case:
    return $_[0] unless $_[0] =~ /[&\"\'<>]/;

    # this is faster than doing one substitution with a map:
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&\#39;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}
*eall = \&ehtml;  # old BML syntax required eall to also escape BML.  not anymore.

# <LJFUNC>
# name: LJ::etags
# class: text
# des: Escapes < and > from a string
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </LJFUNC>
sub etags
{
    # fast path for the commmon case:
    return $_[0] unless $_[0] =~ /[<>]/;

    my $a = $_[0];
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;
}

# <LJFUNC>
# name: LJ::ejs
# class: text
# des: Escapes a string value before it can be put in JavaScript.
# args: string
# des-string: string to be escaped
# returns: string escaped.
# </LJFUNC>
sub ejs
{
    my $a = $_[0];
    $a =~ s/[\"\'\\]/\\$&/g;
    $a =~ s/\r?\n/\\n/gs;
    $a =~ s/\r//;
    return $a;
}

# <LJFUNC>
# name: LJ::is_ascii
# des: checks if text is pure ASCII
# args: text
# des-text: text to check for being pure 7-bit ASCII text
# returns: 1 if text is indeed pure 7-bit, 0 otherwise.
# </LJFUNC>
sub is_ascii {
    my $text = shift;
    return ($text !~ m/[\x00\x80-\xff]/);
}

# <LJFUNC>
# name: LJ::is_utf8
# des: check text for UTF-8 validity
# args: text
# des-text: text to check for UTF-8 validity
# returns: 1 if text is a valid UTF-8 stream, 0 otherwise.
# </LJFUNC>
sub is_utf8 {
    my $text = shift;

    if (LJ::are_hooks("is_utf8")) {
        return LJ::run_hook("is_utf8", $text);
    }

    # for a discussion of the different utf8 validity checking methods,
    # see:  http://zilla.livejournal.org/657
    # in summary, this isn't the fastest, but it's pretty fast, it doesn't make
    # perl segfault, and it doesn't add new crazy dependencies.  if you want
    # speed, check out ljcom's is_utf8 version in C, using Inline.pm

    my $u = Unicode::String::utf8($text);
    my $text2 = $u->utf8;
    return $text eq $text2;
}

# <LJFUNC>
# name: LJ::text_out
# des: force outgoing text into valid UTF-8
# args: text
# des-text: reference to text to pass to output. Text if modified in-place.
# returns: nothing.
# </LJFUNC>
sub text_out
{
    my $rtext = shift;

    # if we're not Unicode, do nothing
    return unless $LJ::UNICODE;

    # is this valid UTF-8 already?
    return if LJ::is_utf8($$rtext);

    # no. Blot out all non-ASCII chars
    $$rtext =~ s/[\x00\x80-\xff]/\?/g;
    return;
}

# <LJFUNC>
# name: LJ::text_in
# des: do appropriate checks on input text. Should be called on all
#      user-generated text.
# args: text
# des-text: text to check
# returns: 1 if the text is valid, 0 if not.
# </LJFUNC>
sub text_in
{
    my $text = shift;
    return 1 unless $LJ::UNICODE;
    if (ref ($text) eq "HASH") {
        return ! (grep { !LJ::is_utf8($_) } values %{$text});
    }
    if (ref ($text) eq "ARRAY") {
        return ! (grep { !LJ::is_utf8($_) } @{$text});
    }
    return LJ::is_utf8($text);
}

# <LJFUNC>
# name: LJ::text_convert
# des: convert old entries/comments to UTF-8 using user's default encoding
# args: dbs?, text, u, error
# des-text: old possibly non-ASCII text to convert
# des-u: user hashref of the journal's owner
# des-error: ref to a scalar variable which is set to 1 on error
#            (when user has no default encoding defined, but
#            text needs to be translated)
# returns: converted text or undef on error
# </LJFUNC>
sub text_convert
{
    &nodb;
    my ($text, $u, $error) = @_;

    # maybe it's pure ASCII?
    return $text if LJ::is_ascii($text);

    # load encoding id->name mapping if it's not loaded yet
    LJ::load_codes({ "encoding" => \%LJ::CACHE_ENCODINGS } )
        unless %LJ::CACHE_ENCODINGS;

    if ($u->{'oldenc'} == 0 ||
        not defined $LJ::CACHE_ENCODINGS{$u->{'oldenc'}}) {
        $$error = 1;
        return undef;
    };

    # We don't preload this library in non-web context, so this
    # makes sure it's loaded if it's needed
    require Unicode::MapUTF8;

    # convert!
    my $name = $LJ::CACHE_ENCODINGS{$u->{'oldenc'}};
    unless (Unicode::MapUTF8::utf8_supported_charset($name)) {
        $$error = 1;
        return undef;
    }

    return Unicode::MapUTF8::to_utf8({-string=>$text, -charset=>$name});
}


# <LJFUNC>
# name: LJ::text_length
# des: returns both byte length and character length of a string. In a non-Unicode
#      environment, this means byte length twice. In a Unicode environment,
#      the function assumes that its argument is a valid UTF-8 string.
# args: text
# des-text: the string to measure
# returns: a list of two values, (byte_length, char_length).
# </LJFUNC>

sub text_length
{
    my $text = shift;
    my $bl = length($text);
    unless ($LJ::UNICODE) {
        return ($bl, $bl);
    }
    my $cl = 0;
    my $utf_char = "([\x00-\x7f]|[\xc0-\xdf].|[\xe0-\xef]..|[\xf0-\xf7]...)";

    while ($text =~ m/$utf_char/go) { $cl++; }
    return ($bl, $cl);
}

# <LJFUNC>
# name: LJ::text_trim
# des: truncate string according to requirements on byte length, char
#      length, or both. "char length" means number of UTF-8 characters if
#      $LJ::UNICODE is set, or the same thing as byte length otherwise.
# args: text, byte_max, char_max
# des-text: the string to trim
# des-byte_max: maximum allowed length in bytes; if 0, there's no restriction
# des-char_max: maximum allowed length in chars; if 0, there's no restriction
# returns: the truncated string.
# </LJFUNC>
sub text_trim
{
    my ($text, $byte_max, $char_max) = @_;
    return $text unless $byte_max or $char_max;
    if (!$LJ::UNICODE) {
        $byte_max = $char_max if $char_max and $char_max < $byte_max;
        $byte_max = $char_max unless $byte_max;
        return substr($text, 0, $byte_max);
    }
    my $cur = 0;
    my $utf_char = "([\x00-\x7f]|[\xc0-\xdf].|[\xe0-\xef]..|[\xf0-\xf7]...)";

    # if we don't have a character limit, assume it's the same as the byte limit.
    # we will never have more characters than bytes, but we might have more bytes
    # than characters, so we can't inherit the other way.
    $char_max ||= $byte_max;

    while ($text =~ m/$utf_char/gco) {
    last unless $char_max;
        last if $cur + length($1) > $byte_max and $byte_max;
        $cur += length($1);
        $char_max--;
    }
    return substr($text,0,$cur);
}

# <LJFUNC>
# name: LJ::text_compress
# des: Compresses a chunk of text, to gzip, if configured for site.  Can compress
#      a scalarref in place, or return a compressed copy.  Won't compress if
#      value is too small, already compressed, or size would grow by compressing.
# args: text
# des-test: either a scalar or scalarref
# returns: nothing if given a scalarref (to compress in-place), or original/compressed value,
#          depending on site config
# </LJFUNC>
sub text_compress
{
    my $text = shift;
    my $ref = ref $text;
    return $ref ? undef : $text unless $LJ::COMPRESS_TEXT;
    die "Invalid reference" if $ref && $ref ne "SCALAR";

    my $tref = $ref ? $text : \$text;
    my $pre_len = length($$tref);
    unless (substr($$tref,0,2) eq "\037\213" || $pre_len < 100) {
        my $gz = Compress::Zlib::memGzip($$tref);
        if (length($gz) < $pre_len) {
            $$tref = $gz;
        }
    }

    return $ref ? undef : $$tref;
}

# <LJFUNC>
# name: LJ::text_uncompress
# des: Uncompresses a chunk of text, from gzip, if configured for site.  Can uncompress
#      a scalarref in place, or return a compressed copy.  Won't uncompress unless
#      it finds the gzip magic number at the beginning of the text.
# args: text
# des-test: either a scalar or scalarref.
# returns: nothing if given a scalarref (to uncompress in-place), or original/uncompressed value,
#          depending on if test was compressed or not
# </LJFUNC>
sub text_uncompress
{
    my $text = shift;
    my $ref = ref $text;
    die "Invalid reference" if $ref && $ref ne "SCALAR";
    my $tref = $ref ? $text : \$text;

    # check for gzip's magic number
    if (substr($$tref,0,2) eq "\037\213") {
        $$tref = Compress::Zlib::memGunzip($$tref);
    }

    return $ref ? undef : $$tref;
}



1;
