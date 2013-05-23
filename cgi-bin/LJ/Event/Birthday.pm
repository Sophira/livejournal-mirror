package LJ::Event::Birthday;

use strict;
use base 'LJ::Event';
use LJ::WishList;
use LJ::Client::BitLy;
use Carp qw(croak);

sub show_promo { 0 }

sub new {
    my ($class, $u, $delay) = @_;
    croak "No user" unless $u && LJ::isu($u);

    return $class->SUPER::new($u, $delay);
}

sub bdayuser {
    my $self = shift;
    return $self->event_journal;
}

# $self->bday ==> $self->bday($lang) where $lang = $u->prop('browselang');
# formats birthday as "August 1"
sub bday {
    my $self = shift;
    my ($year, $mon, $day) = split(/-/, $self->bdayuser->{bdate});

    my @months = qw(January February March April May June
                    July August September October November December);

    return "$months[$mon-1] $day";
}

sub next_bday {
    my $self = shift;

    my ($year, $mon, $day) = split(/-/, $self->bdayuser->{bdate});
    
    $year = (localtime())[5] + 1900;

    $year++
        if $mon == 1 && $day < 3;

    return join '-',($year, $mon, $day)
}

sub matches_filter {
    my ($self, $subscr) = @_;

    if (!$subscr->owner || $self->userid == $subscr->owner->userid)  {
        return 0;
    }

    return $self->bdayuser->can_show_bday(to => $subscr->owner) ? 1 : 0;
}

sub as_string {
    my ($self, $u) = @_;
    my $lang = ($u && $u->prop('browselang')) || $LJ::DEFAULT_LANG;

    my $tinyurl = $self->bdayuser->journal_base;
    $tinyurl = LJ::Client::BitLy->shorten($tinyurl);
    undef $tinyurl if $tinyurl =~ /^500/;

    my $lang_var =  $self->arg1 ? 'notification.sms.birthday_today' : 
                                  'notification.sms.birthday';

    return LJ::Lang::get_text($lang, $lang_var, undef, {
        user       => $self->bdayuser->display_username(1),
        bday       => $self->bday,
        mobile_url => $tinyurl,
    });
}

sub as_alert {
    my $self = shift;
    my $u = shift;

    my $lang_var = $self->arg1 ? 'esn.bday.alert_today' :
                                 'esn.bday.alert';

    return LJ::Lang::get_text($u->prop('browselang'),
            $lang_var, undef,
            {
                who     => $self->bdayuser->ljuser_display(),
                bdate   => $self->bday,
            });
}

sub as_html {
    my $self = shift;
    my $u    = shift;

    my $lang_var = $self->arg1 ? 'html.notify.bday_today' :
                                 'html.notify.bday';
   
    return LJ::Lang::get_text($u->prop('browselang'),
           $lang_var, undef,
            {
                who     => $self->bdayuser->ljuser_display(),
                bdate   => $self->bday,
            });
}

sub tmpl_params {
    my $self = shift;
    my $u    = shift;

    my $lang = $u->prop('browselang') || $LJ::DEFAULT_LANG;
    my $lang_var = $self->arg1 ? 'html.notify.bday_today' :
                                 'html.notify.bday';
   
    return {
           body => LJ::Lang::get_text($lang, $lang_var, undef, {
                   who     => $self->bdayuser->ljuser_display(),
                   bdate   => $self->bday,
           }),
           userpic    => $self->bdayuser->userpic ? $self->bdayuser->userpic->url : '',
           subject    => LJ::Lang::get_text($lang, 'esn.bday.params.subject'),
           actions    => [{
                   action_url => $self->bdayuser->gift_url({ item => 'vgift' }),
                   action     => LJ::Lang::get_text($lang, 'send.a.gift'),
           }],
    }
}

sub as_html_actions {
    my ($self) = @_;

    my $lang = $self->bdayuser->prop('browselang') || $LJ::DEFAULT_LANG;
    my $lang_var = 'send.a.gift';
    my $giftlink = LJ::Lang::get_text($lang,$lang_var);

    my $gifturl = $self->bdayuser->gift_url({ item => 'vgift' });
    my $ret .= "<div class='actions'>";
    $ret .= " <a href='$gifturl'>$giftlink</a>";
    unless ($LJ::DISABLED{wishlist_v2}) {
        if (LJ::WishList->have_current($self->bdayuser)) {
            $ret .= " View user's <a href='".$self->bdayuser->wishlist_url."'>Wishlist</a>";
        }
    }
    $ret .= "</div>";

    return $ret;
}

my @_ml_strings = (
    'esn.month.day_jan',      #January [[day]]
    'esn.month.day_feb',      #February [[day]]
    'esn.month.day_mar',      #March [[day]]
    'esn.month.day_apr',      #April [[day]]
    'esn.month.day_may',      #May [[day]]
    'esn.month.day_jun',      #June [[day]]
    'esn.month.day_jul',      #July [[day]]
    'esn.month.day_aug',      #August [[day]]
    'esn.month.day_sep',      #September [[day]]
    'esn.month.day_oct',      #October [[day]]
    'esn.month.day_nov',      #November [[day]]
    'esn.month.day_dec',      #December [[day]]
    'esn.bday.subject',       #[[bdayuser]]'s birthday is coming up!
    'esn.bday.subject_today', #
    'esn.bday.email',         #Hi [[user]],
                              #
                              #[[bdayuser]]'s birthday is coming up on [[bday]]!
                              #
                              #You can:
    'esn.bday.email_today',   #Hi [[user]],
                              #
                              #[[bdayuser]]'s birthday is today!
                              # 
                              #You can:
    'esn.post_happy_bday',    #[[openlink]]Post to wish them a happy birthday[[closelink]]

    'esn.bday.params.subject' # Someone has birthday
);

sub as_email_subject {
    my $self = shift;
    my $u    = shift;

    my $lang_var = $self->arg1 ? 'esn.bday.subject_today' :
                                 'esn.bday.subject';

    return LJ::Lang::get_text($u->prop('browselang'),
        $lang_var, undef,
        { bdayuser => $self->bdayuser->display_username } );
}

# This is same method as 'bday', but it use ml-features.
sub email_bday {
    my ($self, $lang) = @_;

    my ($year, $mon, $day) = split(/-/, $self->bdayuser->{bdate});
    return LJ::Lang::get_text($lang,
       'esn.month.day_' . qw(jan feb mar apr may jun jul aug sep oct nov dec)[$mon-1],
       undef, { day => $day } );
}

sub _as_email {
    my ($self, $is_html, $u) = @_;

    my $lang = $u->prop('browselang');

    # Precache text lines
    LJ::Lang::get_text_multi($lang, undef, \@_ml_strings);

    my $lang_var = $self->arg1 ? 'esn.bday.email_today' : 
                                 'esn.bday.email';

    return LJ::Lang::get_text($lang,
        $lang_var, undef,
        {
            user        => $is_html ? $u->ljuser_display : $u->display_username,
            bday        => $self->email_bday($lang),
            bdayuser    => $is_html ? $self->bdayuser->ljuser_display : $self->bdayuser->display_username,
        }) .
        $self->format_options($is_html, $lang, undef,
            {
                'esn.post_happy_bday'   => [ 1, "$LJ::SITEROOT/update.bml" ],
            },
            LJ::run_hook('birthday_notif_extra_' . ($is_html ? 'html' : 'plaintext'), $u)
        );
}

sub as_email_string {
    my ($self, $u) = @_;
    return _as_email($self, 0, $u);
}

sub as_email_html {
    my ($self, $u) = @_;
    return _as_email($self, 1, $u);
}

sub zero_journalid_subs_means { "friends" }

sub subscription_as_html {
    my ($class, $subscr) = @_;
    my $journal = $subscr->journal;

    return LJ::Lang::ml('event.birthday.me') # "One of my friends has an upcoming birthday"
        unless $journal;

    my $ljuser = $journal->ljuser_display;
    return LJ::Lang::ml('event.birthday.user', { user => $ljuser } ); # "$ljuser\'s birthday is coming up";
}

sub content {
    my ($self, $target) = @_;

    return $self->as_html_actions;
}

sub available_for_user  { 1 }
sub is_subscription_visible_to  { 1 }

sub is_tracking {
    my ($self, $u) = @_;

    return $self->userid ? 1 : 0;
}

sub as_push {
    my $self = shift;
    my $u    = shift;
    my $lang = shift;

    my $lang_var = $self->arg1 ? "esn.push.notification.birthday_today" :
                                 "esn.push.notification.birthday";

    return LJ::Lang::get_text($lang, $lang_var, 1, {
        user    => $self->bdayuser->user(),
        date    => $self->email_bday($u->prop('browselang'))
    })
}

sub as_push_payload {
    my $self = shift;

    return { 't' => 17,
             'j' => $self->bdayuser->user(),
             'b' => $self->next_bday(),
           };
}

sub fire {
    my ($self, $timeout) = @_;
    return 0 if $LJ::DISABLED{'esn'};

    my $sclient = LJ::theschwartz( { role => $self->schwartz_role } );
    return 0 unless $sclient;

    my $job = $self->fire_job or
        return 0;

    $job->run_after($self->arg1)
        if $self->arg1;

    my $h = $sclient->insert($job);
    return $h ? 1 : 0;
}

sub update_events_counter {
    my $self = shift;

    my $u = $self->u;
    return unless $u;

    my $lang = $u->prop('browselang') || $LJ::DEFAULT_LANG;
    LJ::Widget::HomePage::UpdatesForUser->add_event($u, 
        LJ::Lang::get_text($lang, 'widget.updatesforuser.birthday', undef, { 
            ljuser => $self->bdayuser->ljuser_display,
            url    => $self->bdayuser->gift_url({ item => 'vgift' }),
            date   => $self->email_bday($self->u->prop('browselang')),
        })
    ); 
}

1;

