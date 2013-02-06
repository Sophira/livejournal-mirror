package LJ::Identity::OpenID;
use strict;

use base qw(LJ::Identity);

use LJ::OpenID;
use Net::OpenID::VerifiedIdentity;
use Encode qw(encode_utf8 decode_utf8);

use integer;

use constant BASE => 36;
use constant TMIN => 1;
use constant TMAX => 26;
use constant SKEW => 38;
use constant DAMP => 700;
use constant INITIAL_BIAS => 72;
use constant INITIAL_N => 128;

my $Delimiter = chr 0x2D;
my $BasicRE   = qr/[\x00-\x7f]/;

sub typeid { 'O' }
sub pretty_type { 'OpenID' }
sub short_code { 'openid' }

sub digit_value {
    my $code = shift;
    return ord($code) - ord("A") if $code =~ /[A-Z]/;
    return ord($code) - ord("a") if $code =~ /[a-z]/;
    return ord($code) - ord("0") + 26 if $code =~ /[0-9]/;
    return;
}

sub adapt {
    my($delta, $numpoints, $firsttime) = @_;
    $delta = $firsttime ? $delta / DAMP : $delta / 2;
    $delta += $delta / $numpoints;
    my $k = 0;
    while ($delta > ((BASE - TMIN) * TMAX) / 2) {
    $delta /= BASE - TMIN;
    $k += BASE;
    }
    return $k + (((BASE - TMIN + 1) * $delta) / ($delta + SKEW));
}

sub decode_punycode {
    my $code = shift;

    my $n      = INITIAL_N;
    my $i      = 0;
    my $bias   = INITIAL_BIAS;
    my @output;

    if ($code =~ s/(.*)$Delimiter//o) {
    push @output, map ord, split //, $1;
    return 0 unless $1 =~ /^$BasicRE*$/o;
    }

    while ($code) {
    my $oldi = $i;
    my $w    = 1;
    LOOP:
    for (my $k = BASE; 1; $k += BASE) {
        my $cp = substr($code, 0, 1, '');
        my $digit = digit_value($cp);
        defined $digit or return 0;
        $i += $digit * $w;
        my $t = ($k <= $bias) ? TMIN
        : ($k >= $bias + TMAX) ? TMAX : $k - $bias;
        last LOOP if $digit < $t;
        $w *= (BASE - $t);
    }
    $bias = adapt($i - $oldi, @output + 1, $oldi == 0);
    $n += $i / (@output + 1);
    $i = $i % (@output + 1);
    splice(@output, $i, 0, $n);
    $i++;
    }

    return join '', map chr, @output;
}

sub enabled {
    return LJ::OpenID->consumer_enabled;
}

sub url {
    my ($self) = @_;
    return $self->value;
}

# Returns a Consumer object
# When planning to verify identity, needs GET
# arguments passed in
sub consumer {
    my ($class, $get_args) = @_;
    $get_args ||= {};

    my $ua;
    unless ($LJ::IS_DEV_SERVER) {
        $ua = LWPx::ParanoidAgent->new(
            timeout => 10,
            max_size => 1024*300,
        );
    }

    my $cache = undef;
    if (! $LJ::OPENID_STATELESS && scalar(@LJ::MEMCACHE_SERVERS)) {
        $cache = 'LJ::Identity::OpenID::Cache';
    }

    my $csr = Net::OpenID::Consumer->new(
        ua => $ua,
        args => $get_args,
        cache => $cache,
        consumer_secret => sub {
            my ($time) = @_;
            return LJ::OpenID::server_secret($time - $time % 3600);
        },
        debug => $LJ::IS_DEV_SERVER || 0,
        required_root => $LJ::SITEROOT,
    );

    return $csr;
}

# Returns 1 if destination identity server
# is blocked
sub blocked_hosts {
    my ($class, $csr) = @_;

    return do { my $dummy = 0; \$dummy; } if $LJ::IS_DEV_SERVER;

    my $tried_local_id = 0;
    $csr->ua->blocked_hosts( sub {
        my $dest = shift;

        if ($dest =~ /(^|\.)\Q$LJ::DOMAIN\E$/i) {
            $tried_local_id = 1;
            return 1;
        }
        return 0;
    } );
    return \$tried_local_id;
}

sub attempt_login {
    my ($class, $errs, %opts) = @_;

    $errs ||= [];
    my $returl = $opts{'returl'} || $LJ::SITEROOT;
    my $returl_fail = $opts{'returl_fail'};
    my $forwhat = $opts{'forwhat'} || '';

    my $fail = sub {
        return LJ::Request->redirect($returl_fail) if $returl_fail;
        return;
    };

    my $returl_fail ||= $returl || $LJ::SITEROOT;

    my $csr = $class->consumer;
    my $url = LJ::Request->post_param('openid:url') || $opts{'openidurl'};

    if ($url =~ /[\<\>\s]/) {
        push @$errs, "Invalid characters in identity URL.";
        return $fail->();
    }

    my $tried_local_ref = $class->blocked_hosts($csr);
    if ($$tried_local_ref) {
        push @$errs, "You can't use a LiveJournal OpenID account on LiveJournal &mdash; ".
                     "just <a href='/login.bml'>go login</a> with your actual LiveJournal account.";
        return $fail->();
    }

    my $claimed_id = eval { $csr->claimed_identity($url) };
    if ($@) {
        push @$errs, $@;
        return $fail->();
    }

    unless ($claimed_id) {
        push @$errs, $csr->err;
        return $fail->();
    }

    my $check_url = $claimed_id->check_url(
        return_to => "$LJ::SITEROOT/identity/callback-openid.bml?" .
                     'ret=' . LJ::Text->eurl($returl) . '&' .
                     'ret_fail=' . LJ::Text->eurl($returl_fail) . '&' .
                     'forwhat=' . LJ::Text->eurl($forwhat),
        trust_root => "$LJ::SITEROOT/",
        delayed_return => 1,
    );

    return LJ::Request->redirect($check_url);
}

sub initialize_user {
    my ($self, $u, $extra) = @_;

    $extra ||= {};
    my $vident = $extra->{'vident'};

    return unless $vident;

    if (ref $vident and $vident->can("display")) {
        LJ::update_user($u, { 'name' => $vident->display });
    } elsif (not ref $vident){
        LJ::update_user($u, { 'name' => $vident });
    }
}

sub display_name {
    my ($self, $u) = @_;

    # if name does not have [] .com .ru or https it should be displayed as
    # "name [domain.com]"; otherwise - old code
    unless ($u->name_orig =~ m!(\w+\.\w{2,4})|(https?://)!){
        my $uri = URI->new( $self->value );
        my $domain = $self->value;
        ($domain) = $uri->host =~ /([\w-]+\.\w{2,4})$/
            if $uri->can('host');
        return $u->name_orig ." [$domain]";
    }

    #
    my ($url, $name);
    $url = $self->value;
    $name = Net::OpenID::VerifiedIdentity::DisplayOfURL($url,
                                                        $LJ::IS_DEV_SERVER);

    $name = LJ::run_hook("identity_display_name", $name) || $name;
        
    ## Decode URL's like below to human-readable names
    ## http://blog.k.python.ru/accounts/5/%D0%94%D0%BC%D0%B8
    $name =~ s/%([\dA-Fa-f]{2})/chr(hex($1))/ge;

    if ($name =~ /^xn--(.*?)(\..*?)$/) {
        $name = Encode::encode_utf8(decode_punycode($1)).$2;
    }

    return $name;
}

sub ljuser_display_params {
    my ($self, $u, $opts) = @_;

    my $ret = {
        'journal_url'  => $opts->{'journal_url'} || $self->url,
        'journal_name' => $u->display_name,
    };

    if (my $head_size = $opts->{'head_size'}) {
        $ret->{'userhead'}   = "openid_${head_size}.gif";
        $ret->{'userhead_w'} = $head_size;
    } elsif ($self->value =~ m/\.fanat\.ru(\/|$)/) {
        # Fanat.ru users have a distinct pic
        # TODO: move to a hook?
        $ret->{'userhead'}   = 'openid_fanat-profile.gif';
        $ret->{'userhead_w'} = 16;
    } else {
        $ret->{'userhead'}   = 'openid-profile.gif';
        $ret->{'userhead_w'} = 16;
    }

    return $ret;
}

sub profile_window_title {
    return LJ::Lang::ml('/userinfo.bml.title.openidprofile');
}

package LJ::Identity::OpenID::Cache;

my $important = qr/^(?:hassoc|shandle):/;

sub get {
    my ($class, $key) = @_;

    # try memcached first.
    my $val = LJ::MemCache::get($key);
    return $val if $val;

    # important keys, on miss, try the database.
    if ($key =~ /$important/) {
        my $dbh = LJ::get_db_writer();
        $val = $dbh->selectrow_array(qq{
            SELECT value FROM blobcache WHERE bckey=?
        }, undef, $key);

        return unless $val;

        # put it back in memcache.
        LJ::MemCache::set($key, $val);
        return $val;
    }

    return;
}

sub set {
    my ($class, $key, $val) = @_;

    # important keys go to the database
    if ($key =~ /$important/) {
        my $dbh = LJ::get_db_writer();
        $dbh->do(qq{
            REPLACE INTO blobcache SET bckey=?, dateupdate=NOW(), value=?
        }, undef, $key, $val);
    }

    # everything goes in memcache.
    LJ::MemCache::set($key, $val);
}

1;
