package LJ::MassPrivacy;

# LJ::MassPrivacy object
#
# Used to handle Schwartz job for updating privacy of posts en masse
#

use strict;
use Carp qw(croak);
use DateTime;

sub schwartz_capabilities {
    return qw(LJ::Worker::MassPrivacy);
}

# enqueue job to update privacy
sub enqueue_job {
    my ($class, %opts) = @_;
    croak "enqueue_job is a class method"
        unless $class eq __PACKAGE__;

    croak "missing options argument" unless %opts;

    # Check options
    if ( (!($opts{publicity}  =~ m/[restrict|permit]/)) &&
         (!($opts{s_security} =~ m/[private|usemask|public]/) ||
          !($opts{e_security} =~ m/[private|usemask|public]/) ) ) {
        croak "invalid privacy option";
    }

    if ($opts{publicity}) {
        $opts{publicity} = ($opts{publicity} =~ m/restrict/) ? 'C' : 'P';
    }

    if ($opts{'start_date'} || $opts{'end_date'}) {
        croak "start or end date not defined"
            if (!$opts{'start_date'} || !$opts{'end_date'});

        if (!($opts{'start_date'} >= 0) || !($opts{'end_date'} >= 0) ||
            !($opts{'start_date'} <= $LJ::EndOfTime) ||
            !($opts{'end_date'} <= $LJ::EndOfTime) ) {
            return undef;
        }
    }

    my $sclient = LJ::theschwartz();
    die "Unable to contact TheSchwartz!" unless $sclient;

    my $shandle = $sclient->insert("LJ::Worker::MassPrivacy", \%opts);

    return $shandle;
}

sub handle {
    my ($class, $opts) = @_;

    croak "missing options argument" unless $opts;

    my $u =  LJ::load_userid($opts->{'userid'});
    # we only handle changes to or from friends-only security
    # Allowmask for friends-only is 1, public and private are 0.
    my $s_allowmask = ($opts->{s_security} eq 'usemask') ? 1 :0;
    my $e_allowmask = ($opts->{e_security} eq 'usemask') ? 1 :0;
    my %privacy = ( private => 'private',
                    usemask => 'friends-only',
                    public  => 'public',
                  );

    my @jids;
    my $timeframe = ''; # date range string or empty
    my %post_ids_filter;

    # If there is a date range
    # add 24h to the final date; otherwise we don't get entries on that date

    if ($opts->{s_unixtime} && $opts->{e_unixtime}) {
        $post_ids_filter{'start_date'}  = $opts->{'s_unixtime'};
        $post_ids_filter{'end_date'}    = $opts->{'e_unixtime'} + 24*60*60;

        my $s_dt = DateTime->from_epoch( epoch => $opts->{s_unixtime} );
        my $e_dt = DateTime->from_epoch( epoch => $opts->{e_unixtime} );
        $timeframe = "between " . $s_dt->ymd . " and " . $e_dt->ymd . " ";
    }

    if ($opts->{'s_security'}) {
        $post_ids_filter{'security'}    = $opts->{'s_security'};
        $post_ids_filter{'allowmask'}   = $s_allowmask;
    }

    @jids = $u->get_post_ids(%post_ids_filter);

    # check if there are any posts to update
    return 1 unless (scalar @jids);

    my @errs;
    my $okay_ct = 0;

    # Update each event using the API

    if ($opts->{e_security}) {  # Update security with LJ::do_request
        foreach my $itemid (@jids) {
            my %res = ();
            my %req = ( 'mode' => 'editevent',
                        'ver' => $LJ::PROTOCOL_VER,
                        'user' => $u->{'user'},
                        'itemid' => $itemid,
                        'security' => $opts->{e_security},
                        'allowmask' => $e_allowmask,
                        );

            # do editevent request
            LJ::do_request(\%req, \%res, { 'noauth' => 1, 'u' => $u,
                           'use_old_content' => 1 });

            # check response
            if ($res{'success'} eq "OK") {
                $okay_ct++;
            } else {
                push @errs, $res{'errmsg'};
            }
        }
    } elsif ($opts->{publicity}) { # Update publicity with LJ::Entry->set_prop
        my $publicity = $opts->{publicity};
        foreach my $itemid (@jids) {
            my $entry = LJ::Entry->new($u, jitemid => $itemid);
            $entry->set_prop('copyright', $publicity) if $entry;
            # There is no any errors returned from LJ::Entry->set_props,
            # it always returns '1'.
            $okay_ct++;
        }
    }

    # better logging
    # Used when logging to statushistory
    my $sys_u = LJ::load_user('system');
    # only print 200 characters  of error message to log
    # allow some space at the end for error location message
    if (@errs) {
        my $errmsg = join(', ', @errs);
        $errmsg = substr($errmsg, 0, 200) . "... ";
        LJ::statushistory_add($u->{'userid'}, $sys_u,
                              "mass_privacy", "Error: $errmsg");
        die $errmsg;
    }

    my ($subject, $msg, @status_history);
    if ($opts->{e_security}) {  # Update security with LJ::do_request
        $subject = "We've updated the privacy of your entries";
        $msg = "Hi " . $u->user . ",\n\n" .
               "$okay_ct " . $privacy{$opts->{s_security}} . " entries " .
               $timeframe . "have now " .
               "been changed to be " . $privacy{$opts->{e_security}} . ".\n\n" .
               "If you made this change by mistake, or if you want to change " .
               "the security on more of your entries, you can do so at " .
               "$LJ::SITEROOT/editprivacy.bml\n\n" .
               "Thanks!\n\n" .
               "$LJ::SITENAME Team\n" .
               "$LJ::SITEROOT";
        @status_history = ("mass_privacy", "Success: $okay_ct " .
                          $privacy{$opts->{s_security}} . " entries " .
                          $timeframe . "have now " . "been changed to be " .
                          $privacy{$opts->{e_security}});
    } elsif ($opts->{publicity}) { # Update publicity with LJ::Entry->set_prop
        my $e_publicity = ($opts->{publicity} eq 'C') ? 'disallow' : 'allow';
        $subject = "We've updated the publicity of your entries";
        $msg = "Hi " . $u->user . ",\n\n" .
               "$okay_ct entries " .
               $timeframe . "have now " .
               "been set to be " . $e_publicity . ".\n\n" .
               "If you made this change by mistake, or if you want to change " .
               "the security on more of your entries, you can do so at " .
               "$LJ::SITEROOT/editsyndi.bml\n\n" .
               "Thanks!\n\n" .
               "$LJ::SITENAME Team\n" .
               "$LJ::SITEROOT";
        @status_history = ("mass_publicity", "Success: $okay_ct " .
                          " entries " . $timeframe . "have now " . "been set to be " .
                          $opts->{publicity});
    }

    LJ::send_mail({
        'to' => $u->email_raw,
        'from' => $LJ::BOGUS_EMAIL,
        'fromname' => $LJ::SITENAMESHORT,
        'wrap' => 1,
        'charset' => 'utf-8',
        'subject' => $subject,
        'body' => $msg,
    }) if $subject && $msg;

    LJ::statushistory_add($u->{'userid'}, $sys_u, @status_history) if @status_history;

    return 1;
}

# Schwartz job for processing changes to privacy en masse
package LJ::Worker::MassPrivacy;
use base 'TheSchwartz::Worker';

use Class::Autouse qw(LJ::MassPrivacy);

sub work {
    my ($class, $job) = @_;

    my $opts = $job->arg;

    unless ($opts) {
        $job->failed;
        return;
    }

    LJ::MassPrivacy->handle($opts);

    return $job->completed;
}

sub keep_exit_status_for { 0 }
sub grab_for { 300 }
sub max_retries { 5 }
sub retry_delay {
        my ($class, $fails) = @_;
            return (10, 30, 60, 300, 600)[$fails];
}

1;
