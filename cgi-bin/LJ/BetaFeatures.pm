package LJ::BetaFeatures;

use strict;
use Carp qw(croak);

use LJ::ModuleLoader;
require "$ENV{'LJHOME'}/cgi-bin/ljcapabilities.pl";

die "must have 'betafeatures' cap configured"
    unless LJ::class_bit(__PACKAGE__->cap_name);

my %HANDLER_OF_KEY = (); # key -> handler object
my @HANDLER_LIST   = LJ::ModuleLoader->module_subclasses(__PACKAGE__);
foreach my $handler (@HANDLER_LIST) {
    eval "use $handler";
    die "Error loading handler '$handler': $@" if $@;
}

sub get_handler {
    my $class = shift;
    my $key   = shift;

    my $handler = $HANDLER_OF_KEY{$key};
    return $handler if $handler;

    my $use_key = 'default';
    foreach my $cl (@HANDLER_LIST) {
        my $subcl = (split("::", $cl))[-1];
        next if $subcl eq 'default';
        next unless $subcl eq $key;

        $HANDLER_OF_KEY{$key} = $cl->new($key);
        last;
    }

    # have one now?
    $handler = $HANDLER_OF_KEY{$key};
    return $handler if $handler;

    # need to instantiate default and register that
    $handler = (__PACKAGE__ . "::default")->new($key);
    return $HANDLER_OF_KEY{$key} = $handler;
}

sub add_to_beta {
    my $class = shift;
    my ($u, $key) = @_;

    my $handler = $class->get_handler($key);
    die "no handler for beta" unless $handler;
    die "can't add to inactive beta" unless $handler->is_active;

    # add the cap value if they're adding it
    unless ($u->in_class($class->cap_name)) {
        $u->add_to_class($class->cap_name);
    }

    my $propval = $u->prop($class->prop_name);
    my @features = split(/\s*,\s*/, $propval);
    return 1 if grep { $_ eq $key } @features;

    push @features, $key;
    my $newval = join(",", @features);
    $u->set_prop($class->prop_name => $newval);
    return 1;
}

sub remove_from_beta {
    my $class = shift;
    my ($u, $key) = @_;

    my $handler = $class->get_handler($key);
    die "no handler for beta" unless $handler;

    # we can just return if they're not beta testing anything
    return 1 unless $u->in_class($class->cap_name);

    # remove the feature from the prop list
    my $propval = $u->prop($class->prop_name);
    my @features = split(/\s*,\s*/, $propval);
    my @newkeys = ();
    push @newkeys, $_ unless grep { $_ eq $key } @features;

    # they're a member of no active beta tests?
    unless (@newkeys) {
        $u->clear_prop($class->prop_name);
        $u->remove_from_class($class->cap_name);
        return 1;
    }

    # we have something to set
    my $newval = join(",", @newkeys);
    # they're already in the cap class
    $u->set_prop($class->prop_name => $newval);
    return 1;
}

sub user_in_beta {
    my $class = shift;
    my ($u, $key) = @_;

    # is the cap set?
    return 0 unless $u->in_class($class->cap_name);

    # cap is set, what does their prop say?
    my $propval = $u->prop($class->prop_name);
    unless ($propval) {
        $u->remove_from_class($class->cap_name);
        return 0;
    }

    my $handler = $class->get_handler($key);
  
    # they have some prop value set, which features
    # are they testing?
    my @features = split(/\s*,\s*/, $propval);

    my $dirty   = 0;
    my $ret_val = 0;
    my @newkeys = ();
    foreach my $fkey (@features) {
        unless ($handler->is_active($fkey)) {
            $dirty = 1;
            next;
        }

        # they should still be in this active fkey
        push @newkeys, $fkey;
        
        # is this the key that we're looking for?
        $ret_val = 1 if $fkey eq $key;
    }

    # now we know if they are in the requested class
    # -- we'll only proceed further if we need to clean
    #    up their prop value
    return $ret_val unless $dirty;

    # we need to change their prop value

    # they're a member of no active beta tests?
    unless (@newkeys) {
        $u->clear_prop($class->prop_name);
        $u->remove_from_class($class->cap_name);
        return $ret_val; # should be 0
    }

    # we have something to set
    my $newval = join(",", @newkeys);
    # they're already in the cap class
    $u->set_prop($class->prop_name => $newval);
    return $ret_val; # could be 1 or 0
}

sub prop_name { 'betafeatures_list' }
sub cap_name  { 'betafeatures'      }

1;
