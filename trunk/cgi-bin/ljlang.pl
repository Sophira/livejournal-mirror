#!/usr/bin/perl
#

use strict;
use lib "$ENV{'LJHOME'}/cgi-bin";
use LJ::Cache;

package LJ::Lang;

my @day_short   = (qw[Sun Mon Tue Wed Thu Fri Sat]);
my @day_long    = (qw[Sunday Monday Tuesday Wednesday Thursday Friday Saturday]);
my @month_short = (qw[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]);
my @month_long  = (qw[January February March April May June July August September October November December]);

# get entire array of days and months
sub day_list_short   { return @LJ::Lang::day_short;   }
sub day_list_long    { return @LJ::Lang::day_long;    }
sub month_list_short { return @LJ::Lang::month_short; }
sub month_list_long  { return @LJ::Lang::month_long;  }

# access individual day or month given integer
sub day_short   { return   $day_short[$_[0] - 1]; }
sub day_long    { return    $day_long[$_[0] - 1]; }
sub month_short { return $month_short[$_[0] - 1]; }
sub month_long  { return  $month_long[$_[0] - 1]; }

# lang codes for individual day or month given integer
sub day_short_langcode   { return "date.day."   . lc(LJ::Lang::day_long(@_))    . ".short"; }
sub day_long_langcode    { return "date.day."   . lc(LJ::Lang::day_long(@_))    . ".long";  }
sub month_short_langcode { return "date.month." . lc(LJ::Lang::month_long(@_))  . ".short"; }
sub month_long_langcode  { return "date.month." . lc(LJ::Lang::month_long(@_))  . ".long";  }

## ordinal suffix
sub day_ord {
    my $day = shift;

    # teens all end in 'th'
    if ($day =~ /1\d$/) { return "th"; }
        
    # otherwise endings in 1, 2, 3 are special
    if ($day % 10 == 1) { return "st"; }
    if ($day % 10 == 2) { return "nd"; }
    if ($day % 10 == 3) { return "rd"; }

    # everything else (0,4-9) end in "th"
    return "th";
}

sub time_format
{
    my ($hours, $h, $m, $formatstring) = @_;

    if ($formatstring eq "short") {
        if ($hours == 12) {
            my $ret;
            my $ap = "a";
            if ($h == 0) { $ret .= "12"; }
            elsif ($h < 12) { $ret .= ($h+0); }
            elsif ($h == 12) { $ret .= ($h+0); $ap = "p"; }
            else { $ret .= ($h-12); $ap = "p"; }
            $ret .= sprintf(":%02d$ap", $m);
            return $ret;
        } elsif ($hours == 24) {
            return sprintf("%02d:%02d", $h, $m);
        }
    }
    return "";
}

#### ml_ stuff:
my $LS_CACHED = 0;
my %DM_ID = ();     # id -> { type, args, dmid, langs => { => 1, => 0, => 1 } }
my %DM_UNIQ = ();   # "$type/$args" => ^^^
my %LN_ID = ();     # id -> { ..., ..., 'children' => [ $ids, .. ] }
my %LN_CODE = ();   # $code -> ^^^^
my $LAST_ERROR;
my $TXT_CACHE;      # LJ::Cache for text

sub get_cache_object { return $TXT_CACHE; }

sub last_error
{
    return $LAST_ERROR;
}

sub set_error
{
    $LAST_ERROR = $_[0];
    return 0;
}

sub get_lang
{
    my $code = shift;
    load_lang_struct() unless $LS_CACHED;
    return $LN_CODE{$code};
}

sub get_lang_id
{
    my $id = shift;
    load_lang_struct() unless $LS_CACHED;
    return $LN_ID{$id};
}

sub get_dom
{
    my $dmcode = shift;
    load_lang_struct() unless $LS_CACHED;
    return $DM_UNIQ{$dmcode};
}

sub get_dom_id
{
    my $dmid = shift;
    load_lang_struct() unless $LS_CACHED;
    return $DM_ID{$dmid};
}

sub get_domains
{
    load_lang_struct() unless $LS_CACHED;
    return values %DM_ID;
}

sub get_root_lang
{
    my $dom = shift;  # from, say, get_dom
    return undef unless ref $dom eq "HASH";
    foreach (keys %{$dom->{'langs'}}) {
        if ($dom->{'langs'}->{$_}) {
            return get_lang_id($_);
        }
    }
    return undef;
}

sub load_lang_struct
{
    return 1 if $LS_CACHED;
    my $dbr = LJ::get_db_reader();
    return set_error("No database available") unless $dbr;
    my $sth;

    $TXT_CACHE = new LJ::Cache { 'maxbytes' => $LJ::LANG_CACHE_BYTES || 50_000 };

    $sth = $dbr->prepare("SELECT dmid, type, args FROM ml_domains");
    $sth->execute;
    while (my ($dmid, $type, $args) = $sth->fetchrow_array) {
        my $uniq = $args ? "$type/$args" : $type;
        $DM_UNIQ{$uniq} = $DM_ID{$dmid} = { 
            'type' => $type, 'args' => $args, 'dmid' => $dmid,
            'uniq' => $uniq,
        };
    }

    $sth = $dbr->prepare("SELECT lnid, lncode, lnname, parenttype, parentlnid FROM ml_langs");
    $sth->execute;
    while (my ($id, $code, $name, $ptype, $pid) = $sth->fetchrow_array) {
        $LN_ID{$id} = $LN_CODE{$code} = {
            'lnid' => $id,
            'lncode' => $code,
            'lnname' => $name,
            'parenttype' => $ptype,
            'parentlnid' => $pid,
        };
    }
    foreach (values %LN_CODE) {
        next unless $_->{'parentlnid'};
        push @{$LN_ID{$_->{'parentlnid'}}->{'children'}}, $_->{'lnid'};
    }
    
    $sth = $dbr->prepare("SELECT lnid, dmid, dmmaster FROM ml_langdomains");
    $sth->execute;
    while (my ($lnid, $dmid, $dmmaster) = $sth->fetchrow_array) {
        $DM_ID{$dmid}->{'langs'}->{$lnid} = $dmmaster;
    }
    
    $LS_CACHED = 1;
}

sub get_itemid
{
    my ($dbarg, $dmid, $itcode, $opts) = @_;
    load_lang_struct() unless $LS_CACHED;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    $dmid += 0;
    my $qcode = $dbh->quote($itcode);
    my $itid = $dbr->selectrow_array("SELECT itid FROM ml_items WHERE dmid=$dmid AND itcode=$qcode");
    return $itid if defined $itid;
    my $qnotes = $dbh->quote($opts->{'notes'});
    $dbh->do("INSERT INTO ml_items (dmid, itid, itcode, notes) VALUES ($dmid, NULL, $qcode, $qnotes)");
    if ($dbh->err) {
        return $dbh->selectrow_array("SELECT itid FROM ml_items WHERE dmid=$dmid AND itcode=$qcode");
    }
    return $dbh->{'mysql_insertid'};
}

sub set_text
{
    my ($dbarg, $dmid, $lncode, $itcode, $text, $opts) = @_;
    load_lang_struct() unless $LS_CACHED;

    my $dbs = LJ::make_dbs_from_arg($dbarg);
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};

    my $l = $LN_CODE{$lncode} or return set_error("Language not defined.");
    my $lnid = $l->{'lnid'};
    $dmid += 0;

    # is this domain/language request even possible?
    return set_error("Bogus domain") 
        unless exists $DM_ID{$dmid};
    return set_error("Bogus lang for that domain") 
        unless exists $DM_ID{$dmid}->{'langs'}->{$lnid};

    my $itid = get_itemid($dbs, $dmid, $itcode, { 'notes' => $opts->{'notes'}});
    return set_error("Couldn't allocate itid.") unless $itid;

    my $txtid = 0;
    if (defined $text) {
        my $userid = $opts->{'userid'} + 0;
        my $qtext = $dbh->quote($text);
        $dbh->do("INSERT INTO ml_text (dmid, txtid, lnid, itid, text, userid) ".
                 "VALUES ($dmid, NULL, $lnid, $itid, $qtext, $userid)");
        return set_error("Error inserting ml_text: ".$dbh->errstr) if $dbh->err;
        $txtid = $dbh->{'mysql_insertid'};
    }
    if ($opts->{'txtid'}) {
        $txtid = $opts->{'txtid'}+0;
    }

    my $staleness = $opts->{'staleness'}+0;
    $dbh->do("REPLACE INTO ml_latest (lnid, dmid, itid, txtid, chgtime, staleness) ".
             "VALUES ($lnid, $dmid, $itid, $txtid, NOW(), $staleness)");
    return set_error("Error inserting ml_latest: ".$dbh->errstr) if $dbh->err;

    # set descendants to use this mapping
    if ($opts->{'childrenlatest'}) {
        my $vals;
        my $rec = sub {
            my $l = shift;
            my $rec = shift;
            foreach my $cid (@{$l->{'children'}}) {
                my $clid = $LN_ID{$cid};
                my $stale = $clid->{'parenttype'} eq "diff" ? 3 : 0;
                $vals .= "," if $vals;
                $vals .= "($cid, $dmid, $itid, $txtid, NOW(), $stale)";
                $rec->($clid, $rec);
            }
        };
        $rec->($l, $rec);
        $dbh->do("INSERT IGNORE INTO ml_latest (lnid, dmid, itid, txtid, chgtime, staleness) ".
                 "VALUES $vals") if $vals;
    }
    
    if ($opts->{'changeseverity'} && $l->{'children'} && @{$l->{'children'}}) {
        my $in = join(",", @{$l->{'children'}});
        my $newstale = $opts->{'changeseverity'} == 2 ? 2 : 1;
        $dbh->do("UPDATE ml_latest SET staleness=$newstale WHERE lnid IN ($in) AND ".
                 "dmid=$dmid AND itid=$itid AND txtid<>$txtid AND staleness < $newstale");
    }

    return 1;
}

sub load_user_lang
{
    my ($u) = @_;
    return if $u->{'lang'};

    LJ::load_user_props(LJ::get_dbs(), $u, "browselang") unless $u->{'browselang'};
    $u->{'lang'} ||= $u->{'browselang'} || $LJ::DEFAULT_LANG || 'en';
}

sub get_text
{
    my ($lang, $code, $dmid, $vars) = @_;
    $dmid = int($dmid || 1);

    load_lang_struct() unless $LS_CACHED;
    my $cache_key = "ml.${lang}.${dmid}.${code}";
    
    my $text = $TXT_CACHE->get($cache_key);

    unless (defined $text) {
        my $mem_good = 1;
        $text = LJ::MemCache::get($cache_key);
        unless (defined $text) {
            $mem_good = 0;
            my $l = $LN_CODE{$lang} or return "?lang?";
            my $dbr = LJ::get_dbh("slave", "master");
            $text = $dbr->selectrow_array("SELECT t.text".
                                          "  FROM ml_text t, ml_latest l, ml_items i".
                                          " WHERE t.dmid=$dmid AND t.txtid=l.txtid".
                                          "   AND l.dmid=$dmid AND l.lnid=$l->{lnid} AND l.itid=i.itid".
                                          "   AND i.dmid=$dmid AND i.itcode=?", undef,
                                          $code);
        }
        if (defined $text) {
            $TXT_CACHE->set($cache_key, $text);
            LJ::MemCache::set($cache_key, $text) unless $mem_good;
        }
    }

    if ($vars) {
        $text =~ s/\[\[([^\[]+?)\]\]/$vars->{$1}/g;
    }

    return $text;
}
   
1;
