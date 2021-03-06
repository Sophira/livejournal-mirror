package LJ::Console::Command::Suspend;

use strict;
use base qw(LJ::Console::Command);
use Carp qw(croak);

use LJ::Pics;

sub cmd { "suspend" }

sub desc { "Suspend an account or entry or photo/album." }

sub args_desc { [
                 'username or email address or entry url or photo url or album url' => "The username of the account to suspend, or an email address to suspend all accounts at that address, or an entry URL to suspend a single entry within an account, or photo URL to suspend, or album URL to suspend all photos",
                 'reason' => "Why you're suspending the account or entry or photo or album.",
                 ] }

sub usage { '<username or email address or entry url or photo/album url> <reason>' }

sub can_execute {
    my $remote = LJ::get_remote();
    return LJ::check_priv( $remote, 'suspend', '' ) || $LJ::IS_DEV_SERVER;
}

sub execute {
    my ($self, $user, $reason, $confirmed, @args) = @_;

    return $self->error("This command takes two arguments. Consult the reference.")
        unless $user && $reason && scalar(@args) == 0;

    my $remote = LJ::get_remote();

    my $photo = LJ::Pics::Photo->new_from_url ($user);
    if ($photo) {
        ## we've got a photo url
        ## suspend and return
        $photo->set_prop ('suspended', 1);
        $photo->set_prop ('suspend_reason', $reason);
        my $journal = $photo->owner;
        LJ::statushistory_add($journal, $remote, "suspend", "photo: $user / $reason");
        $photo->delete_from_cdn () if $LJ::PICS_IMAGES_USE_CDN;
        return $self->print("Photo " . $user . " suspended.");
    }

    my $album = LJ::Pics::Album->new_from_url ($user);
    if ($album) {
        ## we've got an album url
        ## suspend and return
        $album->set_prop ('suspended', 1);
        $album->set_prop ('suspend_reason', $reason);
        my @photos = $album->photos;
        if ($LJ::PICS_IMAGES_USE_CDN) {
            $_->delete_from_cdn () foreach @photos;
        }
        my $journal = $album->owner;
        LJ::statushistory_add($journal, $remote, "suspend", "album: $user / $reason");
        return $self->print("Album " . $user . " suspended.");
    }

    my $entry = LJ::Entry->new_from_url($user);
    if ($entry) {
        my $poster = $entry->poster;
        my $journal = $entry->journal;

        return $self->error("Invalid entry.")
            unless $entry->valid;

        # LJSV-723:
        # It is currently not possible to suspend a user whose journal is deleted & purged,
        # or an entry left by a user whose journal is deleted & purged.
        # However, entries made to communities and comments left in other journals by a deleted & purged journal still appear,
        # and it is sometimes necessary to disable access to these.
        # Suspend functionality should be changed to allow Abuse to disable access to these journals & content.
        #
        # So do not check $poster status.
        #
        return $self->error("Journal is purged; cannot suspend entry.")
            if $journal->is_expunged;

        return $self->error("Entry is already suspended.")
            if $entry->is_suspended;

        $entry->set_prop( statusvis => "S" );
        $entry->mark_suspended('S'); # skip in LJ::get_recent_items() call

        $reason = "entry: " . $entry->url . "; reason: $reason";
        LJ::statushistory_add($journal, $remote, "suspend", $reason);
        LJ::statushistory_add($poster, $remote, "suspend", $reason)
            unless $journal->equals($poster);

        LJ::run_hooks('editpost', $entry,);

        return $self->print("Entry " . $entry->url . " suspended.");
    }

    my @users;
    if ($user !~ /@/) {
        push @users, $user;

    } else {
        $self->info("Acting on users matching email $user");

        my $dbr = LJ::get_db_reader();
        my $userids = $dbr->selectcol_arrayref('SELECT userid FROM email WHERE email = ?', undef, $user);
        return $self->error("Database error: " . $dbr->errstr)
            if $dbr->err;

        return $self->error("No users found matching the email address $user.")
            unless $userids && @$userids;

        my $us = LJ::load_userids(@$userids);
        foreach my $u (values %$us) {
            push @users, $u->user;
        }

        unless ($confirmed eq "confirm") {
            $self->info("   $_") foreach @users;
            $self->info("To actually confirm this action, please do this again:");
            $self->info("   suspend $user \"$reason\" confirm");
            return 1;
        }
    }

    foreach my $username (@users) {
        my $u = LJ::load_user($username);

        unless ($u) {
            $self->error("Unable to load '$username'");
            next;
        }

        if ($u->is_suspended) {
            $self->error("$username is already suspended.");
            next;
        }

        my $err;
        $self->error($err)
            unless $u->set_suspended($remote, $reason, \$err);

        my $job = TheSchwartz::Job->new_from_array("LJ::Worker::MarkSuspendedEntries::mark", { userid => $u->userid });
        my $sclient = LJ::theschwartz();
        $sclient->insert_jobs($job) if $sclient and $job and LJ::is_enabled('mark_suspended_accounts');

        $self->print("User '$username' suspended.");
    }

    return 1;
}

1;
