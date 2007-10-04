package LJ::AdPolicy;

use strict;

LJ::ModuleLoader->autouse_subclasses('LJ::AdPolicy');

sub new {
    my $class = shift;
    my %opts  = @_;

    my $self = {};

    # should we defer to a different class for this adcall?
    if (my $other_class = LJ::run_hook('alternate_adpolicy_class')) {
        bless $self, $other_class;
        return $self;
    }

    # use configured adcall_class, or fall back to stub
    my $adcall_class = $LJ::ADPOLICY_CLASS || $class;
    bless $self, $adcall_class;
    return $self;
}

sub should_show_ads {
    my $self = shift;
    my $page = shift;

    return $self->ads_enabled ? 1 : 0;
}

# Try and figure out what journal is being viewed, if they are viewing one.
sub decide_journal_u {
    my $self = shift;

    my $journal_u = LJ::get_active_journal();
    return $journal_u if LJ::isu($journal_u);

    return undef unless LJ::is_web_context();

    my $r = Apache->request;

    return 
        LJ::load_user($r->notes("_journal")) ||
        LJ::load_userid($r->notes("journalid"));
}

sub ads_enabled {
    my $self = shift;

    return $LJ::USE_ADS ? 1 : 0;
}

1;
