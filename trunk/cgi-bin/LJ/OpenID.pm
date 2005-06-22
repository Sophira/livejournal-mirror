package LJ::OpenID;

use strict;
use Net::OpenID::Server 0.04;
use Digest::SHA1 qw(sha1 sha1_hex);

sub server {
    my ($get, $post) = @_;

    return Net::OpenID::Server->new(
                                    get_args         => $get  || {},
                                    post_args        => $post || {},

                                    get_user     => \&LJ::get_remote,
                                    is_identity  => sub {
                                        my ($u, $ident) = @_;
                                        return LJ::OpenID::is_identity($u, $ident, $get);
                                    },
                                    is_trusted   => \&LJ::OpenID::is_trusted,

                                    setup_url    => "$LJ::SITEROOT/openid/approve.bml",

                                    server_secret => \&LJ::OpenID::server_secret,
                                    secret_gen_interval => 3600,
                                    secret_expire_age   => 86400 * 14,
                                    );
}

sub server_secret {
    my $time = shift;
    my ($t2, $secret) = LJ::get_secret($time);
    die "ASSERT: didn't get t2 (t1=$time)" unless $t2;
    die "ASSERT: didn't get secret (t2=$t2)" unless $secret;
    die "ASSERT: time($time) != t2($t2)\n" unless $t2 == $time;
    return $secret;
}

sub is_trusted {
    my ($u, $trust_root, $is_identity) = @_;
    return 0 unless $u;
    # we always look up $is_trusted, even if $is_identity is false, to avoid timing attacks

    my $dbh = LJ::get_db_writer();
    my ($endpointid, $duration) = $dbh->selectrow_array("SELECT t.endpoint_id, t.duration ".
                                                        "FROM openid_trust t, openid_endpoint e ".
                                                        "WHERE t.userid=? AND t.endpoint_id=e.endpoint_id AND e.url=?",
                                                        undef, $u->{userid}, $trust_root);
    return 0 unless $endpointid;

    if ($duration eq "once") {
        $dbh->do("DELETE FROM openid_trust WHERE userid=? AND endpoint_id=?", undef, $u->{userid}, $endpointid);
    }
    return 1;
}

sub is_identity {
    my ($u, $ident, $get) = @_;
    return 0 unless $u && $u->{journaltype} eq "P";

    my $user = $u->{user};
    return 1 if
        $ident eq "$LJ::SITEROOT/users/$user/" ||
        $ident eq "$LJ::SITEROOT/~$user/" ||
        $ident eq "http://$user.$LJ::USER_DOMAIN/";

    if ($get->{'ljuser_sha1'} eq sha1_hex($user) ||
        $get->{'ljuser'} eq $user) {
	my $dbh = LJ::get_db_writer();
	return $dbh->selectrow_array("SELECT COUNT(*) FROM openid_external WHERE userid=? AND url=?",
                                     undef, $u->{userid}, $ident);
    }

    return 0;
}

sub getmake_endpointid {
    my $site = shift;

    my $dbh = LJ::get_db_writer()
        or return undef;

    my $rv = $dbh->do("INSERT IGNORE INTO openid_endpoint (url) VALUES (?)", undef, $site);
    my $end_id;
    if ($rv > 0) {
        $end_id = $dbh->{'mysql_insertid'};
    } else {
        $end_id = $dbh->selectrow_array("SELECT endpoint_id FROM openid_endpoint WHERE url=?",
                                        undef, $site);
    }
    return $end_id;
}

sub add_trust {
    my ($u, $site, $dur) = @_;

    return 0 unless $dur =~ /^always|once$/;

    my $end_id = LJ::OpenID::getmake_endpointid($site)
        or return 0;

    my $dbh = LJ::get_db_writer()
        or return undef;

    my $rv = $dbh->do("REPLACE INTO openid_trust (userid, endpoint_id, duration, trust_time) ".
                      "VALUES (?,?,?,UNIX_TIMESTAMP())", undef, $u->{userid}, $end_id, $dur);
    return $rv;
}

# From Digest::HMAC
sub hmac_sha1_hex {
    unpack("H*", &hmac_sha1);
}
sub hmac_sha1 {
    hmac($_[0], $_[1], \&sha1, 64);
}
sub hmac {
    my($data, $key, $hash_func, $block_size) = @_;
    $block_size ||= 64;
    $key = &$hash_func($key) if length($key) > $block_size;

    my $k_ipad = $key ^ (chr(0x36) x $block_size);
    my $k_opad = $key ^ (chr(0x5c) x $block_size);

    &$hash_func($k_opad, &$hash_func($k_ipad, $data));
}

1;
