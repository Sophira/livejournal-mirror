package LJ::Widget::VerticalContentControl;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::Vertical );

sub need_res { }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $get = $opts{get};

    my $action = $get->{action};
    my $remote = LJ::get_remote();
    my $ret;

    if ($action eq "add" || $action eq "remove") {
        my @verticals;
        if (LJ::check_priv($remote, "vertical", "*") || $LJ::IS_DEV_SERVER) {
            @verticals = LJ::Vertical->load_all;
        } else {
            foreach my $vert (keys %LJ::VERTICAL_TREE) {
                my $v = LJ::Vertical->load_by_name($vert);
                if ($v->remote_is_moderator) {
                    push @verticals, $v;
                }
            }
        }

        return "" unless @verticals;
        @verticals = sort { $a->name cmp $b->name } @verticals;

        $ret .= $class->start_form;

        $ret .= "<table border='0'>";
        $ret .= "<tr><td valign='top'>";
        $ret .= $action eq "add" ? "Add entry to vertical(s):" : "Remove entry from vertical(s):";
        $ret .= "</td><td>";
        if (@verticals > 1) {
            $ret .= $class->html_select(
                name => 'verticals',
                list => [ map { $_->vertid, $LJ::VERTICAL_TREE{$_->name}->{display_name} } @verticals ],
                multiple => 'multiple',
                size => 5,
            );
        } else {
            $ret .= "<strong>" . $LJ::VERTICAL_TREE{$verticals[0]->name}->{display_name} . "</strong>";
            $ret .= $class->html_hidden( verticals => $verticals[0]->vertid );
        }
        $ret .= "</td></tr>";

        $ret .= "<tr><td>Entry URL:</td><td>";
        $ret .= $class->html_text(
            name => 'entry_url',
            size => 50,
        ) . "</td></tr>";

        $ret .= "<tr><td colspan='2'>" . $class->html_submit( $action => $action eq "add" ? "Add Entry" : "Remove Entry" ) . " ";
        $ret .= "<a href='$LJ::SITEROOT/admin/verticals/'>Return to Options List</a></td></tr>";
        $ret .= "</table>";

        $ret .= $class->end_form;
    } elsif ($action eq "view") {
        $ret .= $class->start_form;

        $ret .= "<?p Entry URL: ";
        $ret .= $class->html_text(
            name => 'entry_url',
            size => 50,
        ) . " p?>";

        $ret .= "<tr><td colspan='2'>" . $class->html_submit( view => "View Entry Verticals" ) . " ";
        $ret .= "<a href='$LJ::SITEROOT/admin/verticals/'>Return to Options List</a></td></tr>";

        $ret .= $class->end_form;
    } else {
        $ret .= "Options:<br />";
        $ret .= "<a href='$LJ::SITEROOT/admin/verticals/?action=add'>Add an entry to vertical(s)</a><br />";
        $ret .= "<a href='$LJ::SITEROOT/admin/verticals/?action=remove'>Remove an entry from vertical(s)</a><br />";
        $ret .= "<a href='$LJ::SITEROOT/admin/verticals/?action=view'>View which vertical(s) an entry is in</a>";
    }

    return $ret;    
}

sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    my $remote = LJ::get_remote();

    my $action;
    if ($post->{add}) {
        $action = "add";
    } elsif ($post->{remove}) {
        $action = "remove";
    } elsif ($post->{view}) {
        $action = "view";
    } else {
        die "Invalid action.";
    }

    die "An entry URL must be provided." unless $post->{entry_url};

    my $entry = LJ::Entry->new_from_url($post->{entry_url});
    die "Invalid entry URL." unless $entry && $entry->valid;

    my @verts;
    if ($action eq "add" || $action eq "remove") {
        die "At least one vertical must be selected." unless $post->{verticals};

        my @verticals = split('\0', $post->{verticals});
        my @vert_names;
        foreach my $vertid (@verticals) {
            my $v = LJ::Vertical->load_by_id($vertid);
            die "You cannot perform this action." if $action eq "add" && !$v->remote_is_moderator;
            die "You cannot perform this action." if $action eq "remove" && !$v->remote_can_remove_entry($entry);

            push @vert_names, $v->name;
            $action eq "add" ? $v->add_entry($entry) : $v->remove_entry($entry);
        }

        my $vert_list = join(", ", @vert_names);
        LJ::statushistory_add($entry->journal, $remote, "vertical moderation", "$action to/from $vert_list (entry " . $entry->ditemid . ")");
    } elsif ($action eq "view") {
        my @verticals = keys %LJ::VERTICAL_TREE;

        foreach my $vert (@verticals) {
            my $v = LJ::Vertical->load_by_name($vert);
            die "You cannot perform this action." unless $v->remote_is_moderator;

            if ($v->entry_insert_time($entry)) {
                push @verts, $v;
            }
        }
    }

    return ( action => $action, verticals => \@verts );
}

1;
