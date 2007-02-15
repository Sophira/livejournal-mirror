#!/usr/bin/perl
package LJ::EmbedModule;
use strict;
use Carp qw (croak);

# can optionally pass in an id of a module to change its contents
# returns module id
sub save_module {
    my ($class, %opts) = @_;

    my $contents = $opts{contents} || '';
    my $id       = $opts{id};
    my $journal  = $opts{journal}
        or croak "No journal passed to LJ::EmbedModule::save_module";

    # are we creating a new entry?
    unless ($id) {
        $id = LJ::alloc_user_counter($journal, 'D')
            or die "Could not allocate embed module ID";
    }

    $journal->do("REPLACE INTO embedcontent (userid, moduleid, content) VALUES ".
                 "(?, ?, ?)", undef, $journal->userid, $id, $contents);
    die $journal->errstr if $journal->err;

    return $id;
}

# takes a scalarref to entry text and expands lj-embed tags
sub expand_entry {
    my ($class, $journal, $entryref) = @_;

    my $expand = sub {
        my $moduleid = shift;
        return "[Error: no module id]" unless $moduleid;
        return $class->module_iframe_tag($journal, $moduleid);
    };

    $$entryref =~ s!<lj-embed\s+id="(\d*)"\s*/>!$expand->($1)!egi;
}

# take a scalarref to a post, parses any lj-embed tags, saves the contents
# of the tags and replaces them with a module tag with the id.
sub parse_module_embed {
    my ($class, $journal, $postref) = @_;

    return unless $postref && $$postref;

    my $p = HTML::TokeParser->new($postref);
    my $newdata = '';
    my $embedopen = 0;
    my $embedcontents = '';
    my $embedid;

    warn "parsing embed modules!\n";

  TOKEN:
    while (my $token = $p->get_token) {
        my $type = $token->[0];
        my $tag  = $token->[1];
        my $attr = $token->[2];  # hashref

        if ($type eq "S") {
            # start tag
            if (lc $tag eq "lj-embed" && ! $LJ::DISABLED{embed_module}) {
                # XHTML style open/close tags done as a singleton shouldn't actually
                # start a capture loop, because there won't be a close tag.
                if ($attr->{'/'}) {
                    # this is an already-existing embed tag
                    $newdata .= qq(<lj-embed id="$attr->{id}" />);
                    next TOKEN;
                } else {
                    $embedopen = 1;
                    $embedcontents = '';
                    $embedid = $attr->{id};
                }

                next TOKEN;
            } else {
                # ok, whatever
                $newdata .= "<$tag";
                foreach (keys %$attr) {
                    $newdata .= " $_=\"$attr->{$_}\"";
                }
                $newdata .= ">";
            }
        } elsif ($type eq "T" || $type eq "D") {
            # tag contents
            if ($embedopen) {
                # we're in a lj-embed tag, capture the contents
                $embedcontents .= $token->[1];
            } else {
                # whatever, we don't care about this
                $newdata .= $token->[1];
            }
        } elsif ($type eq 'E') {
            # end tag
            if ($tag eq 'lj-embed') {
                if ($embedopen) {
                    $embedopen = 0;
                    if ($embedcontents) {
                        # ok, we have a lj-embed tag with stuff in it.
                        # save it and replace it with a tag with the id
                        $embedid = LJ::EmbedModule->save_module(
                                                                contents => $embedcontents,
                                                                id       => $embedid,
                                                                journal  => $journal,
                                                                );
                        $newdata .= qq(<lj-embed id="$embedid" />) if $embedid;
                    }
                    $embedid = undef;
                } else {
                    $newdata .= "[Error: close lj-embed tag without open tag]";
                }
            } else {
                $newdata .= "</$tag>";
            }
        }
    }

    $$postref = $newdata;
}

sub module_iframe_tag {
    my ($class, $u, $moduleid) = @_;

    my ($content) = $u->selectrow_array("SELECT content FROM embedcontent WHERE " .
                                        "moduleid=? AND userid=?",
                                        undef, $moduleid, $u->userid);
    die $u->errstr if $u->err;
    return "iframe for id $moduleid: [$content]";
}

sub transform_module {
    my ($class, $journal, $tokensref) = @_;

    my ($moduleid, $contents);

    foreach my $token (@$tokensref) {
        if ($token->[0] eq 'T') {
            $contents = $token->[1];
        }

        next unless $token->[0] eq 'S';
        my $check = sub {
            my $attr = shift;
            $moduleid = $attr->{id}
                if $attr->{id};
        };

        my $attr = $token->[2] || {};
        $check->($attr);
    }

    return __PACKAGE__->expand_module_tag(id => $moduleid);
}

sub expand_module_tag {
    my $class = shift;
    my %opts = @_;

    my $moduleid = $opts{id};
    my $contents = $opts{contents};

    # if this has an ID but no contents, then we need to replace it
    # with an iframe containing the content.
    if ($moduleid && ! $contents) {
        # already just a plain module embed tag
        return qq(<lj-embed id="$moduleid" />);
    } elsif ($contents) {
        # save this module, replace with the module tag
        LJ::EmbedModule->save_module(contents => $contents, id => $moduleid);
      } else {
          # no id or contents
          return "Invalid module tag";
      }
}

1;
