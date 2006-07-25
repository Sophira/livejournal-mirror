package LJ::NotificationMethod::Email;

use strict;
use Carp qw/ croak /;
use base 'LJ::NotificationMethod';
require 'weblib.pl';

sub can_digest { 1 };

# takes a $u
sub new {
    my $class = shift;

    croak "no args passed"
        unless @_;

    my $u = shift;
    croak "invalid user object passed"
        unless LJ::isu($u);

    my $self = { u => $u };

    return bless $self, $class;
}

sub title { 'Email' }

sub new_from_subscription {
    my $class = shift;
    my $subs = shift;

    return $class->new($subs->owner);
}

sub u {
    my $self = shift;
    croak "'u' is an object method"
        unless ref $self eq __PACKAGE__;

    if (my $u = shift) {
        croak "invalid 'u' passed to setter"
            unless LJ::isu($u);

        $self->{u} = $u;
    }
    croak "superfluous extra parameters"
        if @_;

    return $self->{u};
}

# notify a single event
sub notify {
    my $self = shift;
    croak "'notify' is an object method"
        unless ref $self eq __PACKAGE__;

    my $u = $self->u;

    my @events = @_;
    croak "'notify' requires one or more events"
        unless @events;

    foreach my $ev (@events) {
        croak "invalid event passed" unless ref $ev;

        my $plain_body = $ev->as_email_string($u);
        my $html_body  = $ev->as_email_html($u);

        my $footer = qq {
-------------------------

This automatic notification email was sent by LiveJournal.com according to your preferences.  You can edit your preferences in $LJ::SITEROOT/manage/subscriptions/.

Thanks!
$LJ::SITENAME Team

$LJ::SITEROOT
        };

        $footer .= LJ::run_hook("esn_email_footer");

        $plain_body .= $footer;

        # for html, convert newlines to <br/> and linkify
        $footer =~ s/\n/<br\/>/g;
        $footer = LJ::auto_linkify($footer);
        $html_body  .= $footer;

        LJ::send_mail({
            to       => $u->{email},
            from     => $LJ::BOGUS_EMAIL,
            fromname => $LJ::SITENAMESHORT,
            wrap     => 1,
            charset  => 'utf-8',
            subject  => $ev->as_email_subject($u),
            html     => $html_body,
            body     => $plain_body,
        }) or die "unable to send notification email";
    }

    return 1;
}

sub configured {
    my $class = shift;

    # FIXME: should probably have more checks
    return $LJ::BOGUS_EMAIL && $LJ::SITENAMESHORT ? 1 : 0;
}

sub configured_for_user {
    my $class = shift;
    my $u = shift;

    return length $u->{email} ? 1 : 0;
}

1;
