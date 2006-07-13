# this class represents a pending subscription, used for presenting to the user
# a subscription that doesn't exist yet

package LJ::Subscription::Pending;
use base 'LJ::Subscription';
use strict;
use Carp qw(croak carp);
use Class::Autouse qw (LJ::Event LJ::NotificationMethod);

sub new {
    my $class = shift;
    my $u = shift;
    my %opts = @_;

    die "No user" unless LJ::isu($u);

    my $journal          = LJ::want_user(delete $opts{journal}) || 0;
    my $etypeid          = delete $opts{etypeid};
    my $ntypeid          = delete $opts{ntypeid};
    my $event            = delete $opts{event};
    my $method           = delete $opts{method};
    my $arg1             = delete $opts{arg1} || 0;
    my $arg2             = delete $opts{arg2} || 0;
    my $default_selected = delete $opts{default_selected} || 0;
    my $flags            = delete $opts{flags} || 0;

    # force autoload of LJ::Event and it's subclasses
    LJ::Event->can('');

    # optional journalid arg
    $journal ||= LJ::want_user(delete $opts{journalid});

    croak "etypeid or event required" unless ($etypeid xor $event);
    if ($event) {
        $etypeid = LJ::Event::etypeid("LJ::Event::$event") or croak "Invalid event: $event";
    }
    croak "No etypeid" unless $etypeid;

    $method = 'Inbox' unless $ntypeid || $method;
    if ($method) {
        $ntypeid = LJ::NotificationMethod::ntypeid("LJ::NotificationMethod::$method") or croak "Invalid method: $method";
    }
    croak "No ntypeid" unless $ntypeid;

    my $self = {
        userid           => $u->{userid},
        u                => $u,
        journal          => $journal,
        etypeid          => $etypeid,
        ntypeid          => $ntypeid,
        arg1             => $arg1,
        arg2             => $arg2,
        default_selected => $default_selected,
        flags            => $flags,
    };

    return bless $self, $class;
}

sub delete {}
sub pending { 1 }

sub journal           { $_[0]->{journal}}
sub journalid         { $_[0]->{journal} ? $_[0]->{journal}->{userid} : 0 }
sub default_selected  { $_[0]->{default_selected} }

# overload create because you should never be calling it on this object
# (if you want to turn a pending subscription into a real subscription call "commit")
sub create { die "Create called on LJ::Subscription::Pending" }

sub commit {
    my ($self) = @_;

    return $self->{u}->subscribe(
                         etypeid => $self->{etypeid},
                         ntypeid => $self->{ntypeid},
                         journal => $self->{journal},
                         arg1    => $self->{arg1},
                         arg2    => $self->{arg2},
                         );
}

# class method
sub thaw {
    my ($class, $data, $u, $POST) = @_;

    my ($type, $userid, $journalid, $etypeid, $flags, $ntypeid, $arg1, $arg2) = split('-', $data);

    die "Invalid thawed data" unless $type eq 'pending';

    unless ($u) {
        my $subuser = LJ::load_userid($userid);
        die "no user" unless $subuser;
        $u = LJ::get_authas_user($subuser);
        die "Invalid user $subuser->{user}" unless $u;
    }

    if ($arg1 && $arg1 eq '?') {
        die "Arg1 option passed without POST data" unless $POST;

        my $arg1_postkey = "$type-$userid-$journalid-$etypeid-$arg1-$arg2.arg1";

        die "No input data for $arg1_postkey" unless defined $POST->{$arg1_postkey};

        my $arg1value = $POST->{$arg1_postkey};
        $arg1 = int($arg1value);
    }

    if ($arg2 && $arg2 eq '?') {
        die "Arg2 option passed without POST data" unless $POST;

        my $arg2_postkey = "$type-$userid-$journalid-$etypeid-$arg2-$arg2.arg2";

        die "No input data for $arg2_postkey" unless defined $POST->{$arg2_postkey};

        my $arg2value = $POST->{$arg2_postkey};
        $arg2 = int($arg2value);
    }

    return undef unless $etypeid;
    return $class->new(
                       $u,
                       journal => $journalid,
                       ntypeid => $ntypeid,
                       etypeid => $etypeid,
                       arg1    => $arg1 || 0,
                       arg2    => $arg2 || 0,
                       flags   => $flags || 0,
                       );
}

# instance method
sub freeze {
    my $self = shift;
    my $arg  = shift;

    my $user = $self->{u}->{userid};
    my $journalid = $self->journalid;
    my $etypeid = $self->{etypeid};
    my $flags = $self->flags;
    my $ntypeid = $self->{ntypeid};

    my @args = ($user,$journalid,$etypeid,$flags,$ntypeid);

    # we don't want ntypeid if we're freezing for arg1/2
    pop @args if $arg;

    push @args, $self->{arg1} if defined $self->{arg1};

    # if arg2 is defined but not arg1, put a zero in arg1
    push @args, 0 if ! defined $self->{arg1} && defined $self->{arg2};

    push @args, $self->{arg2} if defined $self->{arg2};

    my $frozen = join('-', ('pending', @args));
    $frozen .= '.' . $arg if $arg;

    return $frozen;
}

1;
