package LJ::Setting::PingBack;
use base 'LJ::Setting';
use strict;
use warnings;

use LJ::PingBack;

# Check if we can render widget
sub should_render {
    my $class = shift;
    my $u     = shift;

    # Render if widget enabled on server
    return 0 if $LJ::DISABLED{'pingback'};
    return 0 unless ($u->is_person || $u->is_identity);

    #return 0 unless $u && $u->get_cap('pingback');
    return 1;
}

# the link to the FAQ
sub helpurl {
    my ($class, $u) = @_;

    return "pingback_faq";
}

# Caption for widget
sub label {
    my $class = shift;

    return $class->ml('settings.pingback');
}

# Prepare HTML code for widget
sub option {
    my ($class, $u, $errs, $args) = @_;
    my $key = $class->pkgkey;

    ## no value selected == pingback for all
    my $value = $u->prop('pingback') || 'O';
    $value = "O" unless $value  =~ /^[OLDEUB]$/;
    ## option "Livejournal only" is removed so far, now it means "Open"
    $value = "O" if $value eq 'L'; 
    
    # PingBack options
    my $ret = '';
    my $disabled = LJ::PingBack->has_user_pingback($u) ? 0 : 1;

    my %opts = (
        "O" => $class->ml("settings.pingback.option.open"),
        "D" => $class->ml("settings.pingback.option.disabled"),
    );
    
    if ($u->is_person) {
    	%opts = (
           %opts,
           "E" => $class->ml("settings.pingback.option.entries"),
           "U" => $class->ml("settings.pingback.option.usernames"),
        );
    }
    if ($value eq 'B') {
    	$disabled = 1;
        $opts{"B"} = $class->ml("settings.pingback.option.blocked");
    }
    $ret .= $class->ml('settings.pingback.process') . "&nbsp;<br />";
    $ret .= LJ::html_select({ 'name' => "${key}pingback", 'selected' => $value, disabled => $disabled }, %opts );
    return $ret;
}

# Save user choice
sub save {
    my ($class, $u, $args) = @_;
    
    return unless $class->should_render($u);
    
    my $value = $class->get_arg($args, "pingback");
    $value = "O" unless $value  =~ /^[OLDEUB]$/;
    $value = "O" if $value eq 'L';
    return $u->set_prop('pingback', $value);
}

1;

