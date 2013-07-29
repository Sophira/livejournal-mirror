package LJ;
use strict;
use Class::Autouse qw(
                      LJ::ModuleLoader
                      );

my $hooks_dir_scanned = 0;  # bool: if we've loaded everything from cgi-bin/LJ/Hooks/

# <LJFUNC>
# name: LJ::are_hooks
# des: Returns true if the site has one or more hooks installed for
#      the given hookname.
# args: hookname
# </LJFUNC>
sub are_hooks
{
    my $hookname = shift;
    load_hooks_dir() unless $hooks_dir_scanned;
    return defined $LJ::HOOKS{$hookname};
}

# <LJFUNC>
# name: LJ::clear_hooks
# des: Removes all hooks.
# </LJFUNC>
sub clear_hooks
{
    my ($filename) = @_;

    if (!$filename) {
        %LJ::HOOKS = ();
        $hooks_dir_scanned = 0;
    } else {
        foreach my $hookname (keys %LJ::HOOKS) {
            @{$LJ::HOOKS{$hookname}} = grep { $_->[0] ne $filename }
                @{$LJ::HOOKS{$hookname}};
        }
    }
}

# <LJFUNC>
# name: LJ::run_hooks
# des: Runs all the site-specific hooks of the given name.
# returns: list of arrayrefs, one for each hook ran, their
#          contents being their own return values.
# args: hookname, args*
# des-args: Arguments to be passed to hook.
# </LJFUNC>
sub run_hooks
{
    my ($hookname, @args) = @_;
    load_hooks_dir() unless $hooks_dir_scanned;

    my @ret;
    foreach my $hook (@{$LJ::HOOKS{$hookname} || []}) {
        push @ret, [ $hook->[1]->(@args) ];
    }
    return @ret;
}

# <LJFUNC>
# name: LJ::run_hook
# des: Runs single site-specific hook of the given name.
# returns: return value from hook
# args: hookname, args*
# des-args: Arguments to be passed to hook.
# </LJFUNC>
sub run_hook
{
    my ($hookname, @args) = @_;
    load_hooks_dir() unless $hooks_dir_scanned;

    my $registered_hooks = $LJ::HOOKS{$hookname} || [];
    return undef unless @$registered_hooks;

    if ( @$registered_hooks > 1 ) {
        my $list_out = join( q{, },
            map { $_->[0] . ' line ' . $_->[2] } @$registered_hooks );

        Carp::carp "more than one hook has been registered " .
            "for $hookname ($list_out), but " .
            "only one is being used in run_hook";
    }

    return $registered_hooks->[0]->[1]->(@args);
}

# <LJFUNC>
# name: LJ::register_hook
# des: Installs a site-specific hook.
# info: Installing multiple hooks per hookname is valid.
#       They're run later in the order they're registered.
# args: hookname, subref
# des-subref: Subroutine reference to run later.
# </LJFUNC>
sub register_hook
{
    my $hookname = shift;
    my $subref = shift;
    my (undef, $filename, $line) = caller;

    ## Check that no hook is registered twice
    foreach my $h (@{$LJ::HOOKS{$hookname}}) {
        if ($h->[0] eq $filename && $h->[2]==$line) {
            warn "Hook '$hookname' may be registered twice from $filename:$line";
            last;
        }
    }
    push @{$LJ::HOOKS{$hookname}}, [$filename, $subref, $line];
}

sub load_hooks_dir {
    return if $hooks_dir_scanned++;
    # eh, not actually subclasses... just files:
    foreach my $class (LJ::ModuleLoader->module_subclasses("LJ::Hooks")) {
        $class =~ s!::!/!g;
        require "$class.pm";
        die "Error loading $class: $@" if $@;
    }
}

# <LJFUNC>
# name: LJ::register_setter
# des: Installs code to run for the "set" command in the console.
# info: Setters can be general or site-specific.
# args: key, subref
# des-key: Key to set.
# des-subref: Subroutine reference to run later.
# </LJFUNC>
sub register_setter
{
    my $key = shift;
    my $subref = shift;
    $LJ::SETTER{$key} = $subref;
}

register_setter('synlevel', sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(title|summary|full)$/) {
        $$err = "Illegal value.  Must be 'title', 'summary', or 'full'";
        return 0;
    }

    $u->set_prop("opt_synlevel", $value);
    return 1;
});

register_setter("newpost_minsecurity", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(public|friends|private)$/) {
        $$err = "Illegal value.  Must be 'public', 'friends', or 'private'";
        return 0;
    }
    # Don't let commmunities be private
    if ($u->{'journaltype'} eq "C" && $value eq "private") {
        $$err = "newpost_minsecurity cannot be private for communities";
        return 0;
    }
    $value = "" if $value eq "public";

    $u->set_prop("newpost_minsecurity", $value);
    return 1;
});

register_setter("stylesys", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^[sS]?(1|2)$/) {
        $$err = "Illegal value.  Must be S1 or S2.";
        return 0;
    }
    $value = $1 + 0;
    $u->set_prop("stylesys", $value);
    return 1;
});

register_setter("maximagesize", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ m/^(0|1)[\:\s](0|1)$/) {
        $$err = "Illegal value.  Must be 0|1:0|1.";
        return 0;
    }
    $value = "$1:$2";
    $u->set_prop("opt_imagelinks", $value);
    return 1;
});

register_setter("opt_ljcut_disable_lastn", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }
    $u->set_prop("opt_ljcut_disable_lastn", $value);
    return 1;
});

register_setter("opt_ljcut_disable_friends", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }
    $u->set_prop("opt_ljcut_disable_friends", $value);
    return 1;
});

register_setter("disable_quickreply", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }
    $u->set_prop("opt_no_quickreply", $value);
    return 1;
});

register_setter("disable_nudge", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }
    $u->set_prop("opt_no_nudge", $value);
    return 1;
});

register_setter("check_suspicious", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(?:yes|no)$/) {
        $$err = "Illegal value. Must be 'yes' or 'no'";
        return 0;
    }
    $u->set_prop("check_suspicious", $value);
    return 1;
});

register_setter("trusted_s1", sub {
    my ($u, $key, $value, $err) = @_;

    unless ($value =~ /^(\d+,?)+$/) {
        $$err = "Illegal value. Must be a comma separated list of style ids";
        return 0;
    }

    # guard against accidentally nuking an existing value.
    my $propval = $u->prop("trusted_s1");
    if ($value && $propval) {
        $$err = "You already have this property set to '$propval'. To overwrite this value,\n" .
            "first clear the property ('set trusted_s1 0'). Then, set the new value or store\n".
            "multiple values (with 'set trusted_s1 $propval,$value').";
        return 0;
    }

    $u->set_prop("trusted_s1", $value);
    return 1;
});

register_setter("icbm", sub {
    my ($u, $key, $value, $err) = @_;
    my $loc = eval { LJ::Location->new(coords => $value); };
    unless ($loc) {
        $u->set_prop("icbm", "");  # unset
        $$err = "Illegal value.  Not a recognized format." if $value;
        return 0;
    }
    $u->set_prop("icbm", $loc->as_posneg_comma);
    return 1;
});

register_setter("no_mail_alias", sub {
    my ($u, $key, $value, $err) = @_;

    unless ($value =~ /^[01]$/) {
        $$err = "Illegal value.  Must be '0' or '1'.";
        return 0;
    }

    my $dbh = LJ::get_db_writer();
    if ($value) {
        $dbh->do("DELETE FROM email_aliases WHERE alias=?", undef,
                 "$u->{'user'}\@$LJ::USER_DOMAIN");
    } elsif ($u->{'status'} eq "A" && LJ::get_cap($u, "useremail")) {
        $dbh->do("REPLACE INTO email_aliases (alias, rcpt) VALUES (?,?)",
                 undef, "$u->{'user'}\@$LJ::USER_DOMAIN", $u->email_raw);
    }

    $u->set_prop("no_mail_alias", $value);
    return 1;
});

register_setter("latest_optout", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(?:yes|no)$/i) {
        $$err = "Illegal value.  Must be 'yes' or 'no'.";
        return 0;
    }
    $value = lc $value eq 'yes' ? 1 : 0;
    $u->set_prop("latest_optout", $value);
    return 1;
});

register_setter("maintainers_freeze", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }
    my $remote = LJ::get_remote();
    if (LJ::check_priv($remote, 'siteadmin', 'propedit') || $LJ::IS_DEV_SERVER) {
        $u->set_prop("maintainers_freeze", $value);
        return 1;
    } else {
        $$err = "You don't have permission to change this property";
        return 0;
    }
});

register_setter('take_entries', sub {
    my ($u, $key, $value, $err) = @_;

    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }

    my $remote = LJ::get_remote();

    if (LJ::check_priv($remote, 'siteadmin', 'propedit') || $LJ::IS_DEV_SERVER) {
        $u->set_prop('take_entries', $value);
        return 1;
    }
    else {
        $$err = "You don't have permission to change this property";
        return 0;
    }
});

register_setter('provide_entries', sub {
    my ($u, $key, $value, $err) = @_;

    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }

    my $remote = LJ::get_remote();

    if (LJ::check_priv($remote, 'siteadmin', 'propedit') || $LJ::IS_DEV_SERVER) {
        $u->set_prop('provide_entries', $value);
        return 1;
    }
    else {
        $$err = "You don't have permission to change this property";
        return 0;
    }
});

register_setter("updatebml_only_old", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }
    $u->set_prop("updatebml_only_old", $value);
    return 1;
});

register_setter('custom_usericon', sub {
    my ($u, $key, $value, $err) = @_;

    my $remote = LJ::get_remote();
    unless ($remote && LJ::check_priv($remote, 'siteadmin', 'custom-usericon')) {
        $$err = "You do not have privileges to set this property.";
        return 0;
    }

    $u->set_custom_usericon($value);
    return 1;
});

register_setter('ilikeit_enable', sub {
    my ($u, $key, $value, $err) = @_;

    my $remote = LJ::get_remote();
    unless ($remote && LJ::check_priv($remote, 'siteadmin', 'ilikeit')) {
        $$err = "You do not have privileges to set this property.";
        return 0;
    }

    $u->set_prop("ilikeit_enable", $value);
    return 1;
});

register_setter("opt_ctxpopup", sub {
    my ($u, $key, $value, $err) = @_;
    unless ($value =~ /^(Y|N)$/) {
        $$err = "Illegal value. Must be 'Y' or 'N'";
        return 0;
    }
    $u->set_prop("opt_ctxpopup", $value);
    return 1;
});

register_setter("pingback", sub {
    my ($u, $key, $value, $err) = @_;
    
    my $remote = LJ::get_remote();
    unless ($remote && LJ::check_priv($remote, 'siteadmin', 'propedit')) {
        $$err = "You do not have privileges to set this property.";
        return 0;
    }
    unless ($value =~ /^[OLDEUB]$/) {
        $$err = "Illegal value. Legal values: O, L, D, E, U, B.";
        return 0;
    }
    $u->set_prop("pingback", $value);
    return 1;
});

register_setter("s2privs", sub {
    my ($u, $key, $value, $err) = @_;

    my %good_params = map { $_ => 1} qw/javascript take_entries provide_entries/;

    if ( $value eq 'none' ) {
        $u->set_prop( $_, 0 ) for keys %good_params;
        return 1;
    }

    my %args = map { $_ => $_ } split( /\+/, $value );
    my @to_set = delete @args{ keys %good_params };
    @to_set = grep { $_ } @to_set;

    return 0 if int(keys %args);
    return 0 unless @to_set;

    delete @good_params{ @to_set };

    # First of all clear unused s2privs props
    $u->set_prop( $_, 0 ) for keys %good_params;

    # and now set required props
    $u->set_prop( $_, 0 ) for @to_set;

    return 1;
});

register_setter("suspicious_trusted_isp_num", sub {
    my ($u, $key, $value, $err) = @_;
    
    my $remote = LJ::get_remote();
    unless ($remote && LJ::check_priv($remote, 'siteadmin', 'propedit')) {
        $$err = "You do not have privileges to set this property.";
        return 0;
    }
    if ( $value < 1 || $value > 256 ) {
        $$err = "Value must be from 1 to 256";
        return 0;
    }
    $u->set_prop("suspicious_trusted_isp_num", $value);
    return 1;
});

register_setter("custom_posting_access", sub {
    my ($u, $key, $value, $err) = @_;

    my $remote = LJ::get_remote();
    unless ($remote && LJ::check_priv($remote, 'siteadmin', 'sharedjournal')) {
        $$err = "You do not have privileges to set this property.";
        return 0;
    }

    unless ($value =~ /^(0|1)$/) {
        $$err = "Illegal value. Must be '0' or '1'";
        return 0;
    }
    $u->set_prop("custom_posting_access", $value);
    return 1;
});

1;
