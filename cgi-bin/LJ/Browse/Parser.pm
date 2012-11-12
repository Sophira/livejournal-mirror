package LJ::Browse::Parser;

use strict;

use URI;

## Parsing text for Landing Page
## args:
##      text => Text to parse
##      max_len => Truncate text on max_len chars
## return:
##      hashref
##          text => parsed and cropped text
##          images => arrayref for urls of cropped images
##
sub do_parse {
    my $class = shift;
    my %args = @_;

    my $text = $args{'text'};
    my $char_max = $args{'max_len'};
    my $entry = $args{'entry'};

    my $p = HTML::TokeParser->new(\$text);

    my $ret = '';
    my @open_tags = ();
    my $content_len = 0;
    my $is_removed_video = 0;
    my $images_crop_cnt = $args{'crop_image'};
    my @images = ();
    my @links = ();
    my $remove_tags = $args{'remove_tags'};
    my $is_text_trimmed = 0;

    while (my $token = $p->get_token) {
        my $type = $token->[0];
        my $tag  = $token->[1];
        my $attr = $token->[2];  # hashref
        my $text = $token->[3];

        if ($type eq "S") {
            my $selfclose = 0;

            ## remove all 'a' and return array with links
            if ($tag eq 'a') {
                if (grep { $tag eq $_ } @$remove_tags) {
                    push @links, $attr->{'href'};
                    $p->get_text('/a');
                    $ret .= " ";
                    next;
                }
            }

            ## resize and crop first image from post if exist
            if ($tag eq 'img') {
                my $src = $attr->{'src'};
                ## SRC must be exist
                next unless $src;

                my $uri = URI->new($src);
                my $host = eval { $uri->host };
                ## Img URL must be valid
                next if $@;

                ## Hashref with resized image
                my $r = undef;

                ## Are we need to update db?
                my $is_new_img = 0;

                my $jitemid = 0;
                my $journalid = 0;
                my $dbw = LJ::get_db_writer();
                if ($images_crop_cnt) {
                    $jitemid = $entry->jitemid;
                    $journalid = $entry->journalid;
                    my $post = $dbw->selectrow_arrayref ("
                        SELECT pic_orig_url, pic_fb_url 
                            FROM category_recent_posts 
                            WHERE jitemid = ? AND journalid = ?", undef,
                        $jitemid, $journalid
                    );
                    if ($post->[0] eq $attr->{'src'}) {
                        $r = {
                            status  => 'big',
                            url     => $post->[1],
                        };
                    } else {
                        if ($args{'need_resize'} eq 1) {
                            $r = LJ::crop_picture_from_web(
                                source      => $attr->{'src'},
                                size        => '200x200',
                                cancel_size => '200x0',
                                username    => $LJ::PHOTOS_FEAT_POSTS_FB_USERNAME,
                                password    => $LJ::PHOTOS_FEAT_POSTS_FB_PASSWORD,
                                galleries   => [ $LJ::PHOTOS_FEAT_POSTS_FB_GALLERY ],
                            );
                            $is_new_img = 1;
                        } else {
                            next;
                        }
                    }
                }
                if ($images_crop_cnt && $r && ($r->{'status'} ne 'small') && $r->{'url'}) {
                    $jitemid = $entry->jitemid;
                    $journalid = $entry->journalid;
                    $images_crop_cnt--;
                    push @images, $r->{url};
                    $dbw->do ("
                        UPDATE category_recent_posts
                            SET pic_orig_url = ?, pic_fb_url = ? 
                            WHERE jitemid = ? AND journalid = ?", undef,
                        $attr->{'src'}, $r->{'url'}, $jitemid, $journalid
                    ) if $is_new_img;
                    next;
                } else {
                    next;
                }
            }

            if (grep { $tag eq $_ } @$remove_tags) {
                ## adding space to the text do not stick together
                $ret .= " ";
                next;
            }

            if ($tag =~ /^lj-poll/) {
                ## no need to insert poll
                $ret .= " ";
            } elsif ($tag =~ /^lj-embed/) {
                ## nothing to do. remove all embed content
                $is_removed_video = 1;
                $ret .= " ";
            } elsif ($tag =~ /^lj-cut/) {
                ## remove all text from lj-cut
                $ret .= " ";
            } elsif ($tag eq 'lj') {
                foreach my $attrname (keys %$attr) {
                    if ($attrname =~ /user|comm/) {
                        $ret .= LJ::ljuser($attr->{$attrname});
                    }
                }
                $selfclose = 1;
            } else {
                $ret .= "<$tag";

                # assume tags are properly self-closed
                $selfclose = 1 if lc $tag eq 'input' || lc $tag eq 'br' || lc $tag eq 'img';

                # preserve order of attributes. the original order is
                # in element 4 of $token
                foreach my $attrname (@{$token->[3]}) {
                    if ($attrname eq '/') {
                        next;
                    }

                    # FIXME: ultra ghetto.
                    $attr->{$attrname} = LJ::no_utf8_flag($attr->{$attrname});
                    $ret .= " $attrname=\"" . LJ::ehtml($attr->{$attrname}) . "\"";
                }

                $ret .= $selfclose ? " />" : ">";
            }

            push @open_tags, $tag unless $selfclose;

        } elsif ($type eq 'T' || $type eq 'D') {
            my $content = $token->[1];

            if (length($content) + $content_len > $char_max) {

                # truncate and stop parsing
                $content = LJ::trim_at_word($content, ($char_max - $content_len));
                $ret .= $content;
                $is_text_trimmed = 1;
                last;
            }

            $content_len += length $content;

            $ret .= $content;

        } elsif ($type eq 'C') {
            # comment, don't care
            $ret .= $token->[1];

        } elsif ($type eq 'E') {
            next if grep { $tag eq $_ } @$remove_tags;

            # end tag
            pop @open_tags;
            $ret .= "</$tag>";
        }
    }

    $ret .= join("\n", map { "</$_>" } reverse @open_tags);

    _after_parse (\$ret);

    return {
        text             => $ret,
        images           => \@images,
        links            => \@links,
        is_removed_video => $is_removed_video,
        is_text_trimmed  => $is_text_trimmed,
    }
}

sub _after_parse {
    my $text = shift;

    ## Remove multiple "br" tags
    $$text =~ s#(\s*</?br\s*/?>\s*){2,}#<br/>#gi;

    ## Remove <a><img><br>-type html (imgs had been deleted early)
    $$text =~ s#(<a[^>]*?></a></?br\s*/?>\s*){2,}#<br/>#gi;

    ## Remove all content of 'script' tag
    $$text =~ s#<script.*?/script># #gis;
}

1;

