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
use HTML::Parser;
use URI;
use URI::QueryParam;
use Encode qw(encode_utf8 decode_utf8 is_utf8);
use Carp qw(confess cluck);
use UNIVERSAL qw(isa);
use strict;
use Data::Dumper;

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

#
# LJ::Text->remove_utf8_flag($tree);
# input: a string or any complex structure (hash, array etc)
# output: the same structure without utf8 flag on any string in it.
#
sub remove_utf8_flag {
    my $class = shift;
    my $tree = shift;

    unless (ref $tree) {
        $tree = encode_utf8($tree) if $tree && is_utf8($tree);
    }
    
    if (ref $tree eq 'ARRAY') {
        foreach (@$tree) {
            $_ = $class->remove_utf8_flag($_);
        }
    }

    if (ref $tree eq 'HASH') {
        foreach (values %$tree) {
            $_ = $class->remove_utf8_flag($_);
        }
    }

    return $tree;    
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

    cluck "unknown options: " . Dumper(\%opts)
        if %opts;

    unless ( $bytes || $chars ) {
        cluck "not actually truncating: no 'bytes' or 'chars' " .
            "parameter passed to LJ::Text::truncate";
    }

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

    cluck "unknown options: " . Dumper(\%opts)
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

#unit test for that function located in LJHOME/bin/tests/unittests/t/Test/LJ/TextTest.pm
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
    my $fill_empty = delete $opts{'fill_empty'} ? 1 : 0;
    my $punct_space = delete $opts{'punct_space'} ? 1 : 0;
    my $strip_html = delete $opts{'strip_html'} ? 1 : 0;
    my $noparse_tags = delete $opts{'noparse_tags'} || [];

    my $force_ellipsis;

    cluck "unknown options: " . Dumper(\%opts)
        if %opts;

    cluck "not actually truncating"
        unless $bytes || $chars;

    if($strip_html) {
        $force_ellipsis = ($str =~ /<(img|embed|object|iframe|lj\-embed)/i) ? 1 : 0;
        $str = LJ::strip_html($str, { use_space => 1, noparse_tags => $noparse_tags });
    }

    my $remove_last_word = sub {
        my ($str) = @_;

        if ($str =~ /\s+$/) {
            $str =~ s/\s+$//;
        } else {
            $str =~ s/(?<=\S\s)\s*\S+$//;
        }

        return $str;
    };
    my $trimmed = 0;

    if ($bytes && $class->byte_len($str) > $bytes) {
        my $bytes_trunc = $bytes - $class->byte_len($ellipsis);
        $str = $class->truncate(
            'str' => $str,
            'bytes' => $bytes_trunc + 1
        );

        $str = $remove_last_word->($str);
        $remainder = substr($original_string, $class->byte_len($str));
		$trimmed = 1;
    }

    if ($chars && $class->char_len($str) > $chars) {
        my $chars_trunc = $chars - $class->char_len($ellipsis);

        $str = $class->truncate(
            'str' => $str,
            'chars' => $chars_trunc + 1
        );

        my $add_space = (substr(decode_utf8($str), $chars_trunc, 1) =~ /\s/);

        $str = $remove_last_word->($str);

        # What kind af moron one has to be to come up with this kind of logic to be implemented? 
        if($add_space) {
            $str .= ' ';
        } elsif($punct_space && $str =~ /[,.;:!?]$/) {
			if($class->char_len($str) >= $chars - 1) {
		        $str = $remove_last_word->($str);
		        
		        if($class->char_len($str) >= $chars - 1) {
                    $str = $class->truncate(
                        'str' => $str,
                        'bytes' => $class->char_len($str) - 2
                    );
		        }
			} else {
				$str .= ' ';
			}   	
        }

        $remainder = substr($original_string, $class->byte_len($str));
        
        $str .= ' ' if($add_space && $str =~ /\S$/);
        $trimmed = 1;

    } elsif($force_ellipsis) {
        $str .= ' ' if($str =~ /\S$/);
    }

    if($noparse_tags) {
        while ( $_ = shift @$noparse_tags ) {
            my $cnt = scalar($str =~ m/<$_>/g) || 0;
            $cnt -= scalar($str =~ m/<$_\/>/g);
            $str .= "<\/$_>" if ($cnt > 0);
        }
    }

    $str .= $ellipsis if ($trimmed);

    $str ||= $ellipsis if($fill_empty);

    $remainder =~ s/^\s+//;
    return wantarray ? ($str, $remainder) : $str;
}

sub durl {
    my ($class, $str) = @_;

    $str =~ s/\+/ /g;
    $str =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $str;
}

sub eurl {
    my ($class, $str) = @_;
    ##
    ## Warning: previous version of code replaced <space> by "+".
    ## According to RFC 2396, <space> must be "%20", and only in query-string,
    ## when application/x-www-form-urlencoded (old standard) is used, it may be "+".
    ## See also: http://en.wikipedia.org/wiki/Percent-encoding.
    ##
    $str =~ s/([^a-zA-Z0-9_\,\-.\\])/uc sprintf("%%%02x",ord($1))/eg;
    return $str;
}

# runs HTML cleaner on the passed string (to ensure that
# <lj user="exampleusername"> is expanded), and then actually removes
# all HTML tags in the result
#
# TODO: save some hassle running clean_comment, and/or make this an option
# for the HTML cleaner itself
sub drop_html {
    my ( $class, $what ) = @_;

    LJ::CleanHTML::clean_comment( \$what, { 'textonly' => 1 });

    $what =~ s/<.*?>/ /g;
    $what =~ s/\s+/ /g;
    $what =~ s/^\s+//;
    $what =~ s/\s+$//;

    return $what;
}

# <LJFUNC>
# name: LJ::Text->wrap_urls
# des: Wrap URLs into "a href"
#      <a href="[URL]">[URL]</a>
# args: text
# des-text: text to be changed
# returns: text with active URLs  
# </LJFUNC>
sub wrap_urls {
    my ($class, $text) = @_;
    my %url = ();
    my $urlcount = 0;
    my $match = sub {
        my $str = shift;
        my $end = '';
        if ($str =~ /^(.*?)(&(#39|quot|lt|gt)(;.*)?)$/) {
            $url{++$urlcount} = $1;
            $end = $2;
        } else {
            $url{++$urlcount} = $str;
        }
        return "&url$urlcount;$url{$urlcount}&urlend;$end";
    };
    my $tag_a = sub {
        my ($key, $title) = @_;
        return "<a href='$url{$key}'>$title</a>";
    };
    ## URL is http://anything-here-but-space-and-quotes/and-last-symbol-isn't-space-comma-period-etc
    ## like this (http://example.com) and these: http://foo.bar, http://bar.baz.
    $text =~ s!(https?://[^\s\'\"\<\>]+[^\s\'\"\<\>\.\,\?\:\;\)])! $match->($1) !ge;
    $text =~ s|&url(\d+);(.*?)&urlend;|$tag_a->($1,$2)|ge;
    
    return $text;
}

# this is extracted from LJ::Support::Request::Tag; note that it's only
# used in selected places at this time -- for example, entry tags are still
# case-sensitive in case they use non-ASCII symbols
sub normalize_tag_name {
    my ( $class, $name, %opts ) = @_;

    # cleanup
    $name =~ s/,//g; # tag separator
    $name =~ s/(^\s+|\s+$)//g; # starting or trailing whitespace
    $name =~ s/\s+/ /g; # excessive whitespace

    return unless $name;

    # this hack is to get Perl actually perform lc() on a Unicode string
    # you're welcome to fix it if you know a better way ;)
    $name = decode_utf8($name);
    $name = lc($name);
    $name = encode_utf8($name);

    if ( my $length_limit = delete $opts{'length_limit'} ) {
        $name = $class->truncate_to_bytes( $name, $length_limit );
    }

    return $name;
}

sub extract_links_with_context {
    my ( $text ) = @_;

    # text can be a plain text or html or combined.
    # some links can be a well-formed <A> tags, other just a plain text like http://some.domain/page.html
    # after detecting a link we need to extract a text (context) in which this link is.
    # To fetching link context in the one way we do process text twice:
    #   1) convert links in plain text in an <a> tags
    #   2) extract links and its context.

    # <a href="http://ya.ru">http://ya.ru</a> - well-formed a-tag
    # <div>well-known search is http://google.ru</div> - link in plain text

    # convert links from plain text in <a> tags.
    my $normolized_text = '';
    my $normolize = HTML::Parser->new(
        api_version => 3,
        start_h     => [
            sub {
                my ($self, $tagname, $text, $attr) = @_;
                $normolized_text .= $text;
                $self->{_smplf_in_a} = 1 if $tagname eq 'a';
            },
            "self, tagname,text,attr",
        ],
        end_h       => [
            sub {
                my ($self, $tagname, $text, $attr) = @_;
                $normolized_text .= $text;
                $self->{_smplf_in_a} = 0 if $tagname eq 'a';
            },
            "self,tagname,text,attr",
        ],
        text_h      => [
            sub {
                my ($self, $text) = @_;

                unless ( $self->{_smplf_in_a} ) {
                    $text =~ s|(http://[\w\-\_]{1,16}\.$LJ::DOMAIN/\d+\.html(\?\S*(\#\S*)?)?)|<a href="$1">$1</a>|g;
                    $text =~ s|(http://community\.$LJ::DOMAIN/[\w\-\_]{1,16}/\d+\.html(\?\S*(\#\S*)?)?)|<a href="$1">$1</a>|g;
                }

                $normolized_text .= $text;
            },
            "self,text",
        ],
    );

    $normolize->parse( Encode::decode_utf8($text . "\n") );

    # parse
    my $parser = HTML::Parser->new(
        api_version => 3,
        start_h     => [ \&tag_start, "self,tagname,text,attr" ],
        end_h       => [ \&tag_end,   "self,tagname,text,attr" ],
        text_h      => [ \&text,      "self,text"              ],
    );

    # init
    $parser->{'res'}           = '';
    $parser->{'prev_link_end'} = 0;
    $parser->{'links'}         = [];

    $parser->parse($normolized_text);

    return
        map { $_->{context} = Encode::encode_utf8($_->{context}); $_ }
        @{$parser->{'links'}};
}

sub tag_start {
    my( $self, $tag_name, $text, $attr ) = @_;

    if ( $tag_name eq 'a' ) {
        parse_a( $self, $text, $attr )
    }
    elsif ( $tag_name =~ m/(br|p|table|hr|object)/ ) {
        $self->{'res'} .= ' ' if substr( $self->{'res'}, -1, 1 ) ne ' ';
    }
}

sub tag_end {
    my ( $self, $tag_name ) = @_;

    if ( $tag_name eq 'a' ){
        my $context = substr $self->{'res'}, (length($self->{'res'}) - 100 < $self->{'prev_link_end'} ? $self->{'prev_link_end'} : -100); # last 100 or less unused chars

        if ( length($self->{'res'}) > length($context) ) { # context does not start from the text begining.
            $context =~ s/^(\S{1,5}\s*)//;
        }

        $self->{'links'}->[-1]->{context} = $context if scalar @{$self->{'links'}};
        $self->{'prev_link_end'} = length($self->{'res'});
    }
}

sub text {
    my ( $self, $text ) = @_;
    my $copy = $text;
    $copy =~ s/\s+/ /g;
    $self->{'res'} .= $copy;
}

sub parse_a {
    my ( $self, $text, $attr ) = @_;
    my $uri = URI->new($attr->{href});
    return unless $uri;

    my $context = $text;

    push @{$self->{'links'}}, { uri => $uri->as_string, context => $context };
    return;
}

sub extract_link_with_context {
    my ( $text, $url ) = @_;

    my $need_text = 0;
    my $res = {};
    my $in_title = 0;
    my $in_a = 0;
    my $del = 0;

    my $normolized_text = '';
    my $normolize = HTML::Parser->new(
        api_version => 3,
        start_h     => [
            sub {
                my ($self, $tagname, $text, $attr) = @_;

                if ( $tagname eq 'title' ) {
                    $in_title = 1;
                }

                if ( $tagname eq 'a' ) {
                    if ( lc $attr->{'href'} eq lc $url && ! $need_text ) {
                        $res->{'pre'} = $normolized_text;
                        $in_a = 1;
                        $need_text = 1;
                    }
                };

                if ( $tagname eq 'script' ) {
                    $del = 1;
                }
            },
            "self, tagname,text,attr",
        ],
        end_h       => [
            sub {
                my ($self, $tagname, $text, $attr) = @_;

                if ( $tagname eq 'title' ) {
                    $in_title = 0;
                }

                if ( $tagname eq 'a' ) {
                    $in_a = 0;
                }

                if ( $tagname eq 'script' ) {
                    $del = 0;
                }

                $self->{_smplf_in_a} = 0 if $tagname eq 'a';
            },
            "self,tagname,text,attr",
        ],
        text_h      => [
            sub {
                my ($self, $text) = @_;

                return if $del;

                $normolized_text .= ' ' unless $normolized_text =~ /\s$/;
                $normolized_text .= $text;

                if ( $need_text && ! $in_a ) {
                    $res->{'post'} .= ' ' . $text;
                }

                if ( $need_text && $in_a ) {
                    $res->{'link'} = ' ' . $text;
                }

                if ( $in_title ) {
                    $res->{'title'} .= $text;
                }
            },
            "self,text",
        ],
    );

    $normolize->parse( $text );
    return $res;
}

sub canonical_uri {
    my( $raw_uri ) = @_;
    my $uri = URI->new($raw_uri)->canonical;

    # regexp from https://metacpan.org/module/URI#PARSING-URIs-WITH-REGEXP
    my( $scheme, $authority, $path, $query, $fragment ) =
        $uri->as_string =~ m|(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?|;

    $query = '';
    my @query = ();

    for my $key ( sort $uri->query_param ) {
        push @query, map { "$key=$_" } sort $uri->query_param($key);
    }

    $query = join( '&', @query );
    return ( $scheme ? "$scheme://" : '' ) . ( $authority ? $authority : '') . ( $path ? $path : '' ) . ( $query ? "?$query" : '' ) . ( $fragment ? $fragment : '' );
}

1;
