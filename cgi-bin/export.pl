#!/usr/bin/perl
#

use strict;
package FB;

sub account_export_xml
{
    my ($u, $r) = @_;
    return 0 unless $u;
    my $udb = FB::get_user_db_reader($u);
    my $db = FB::get_db_reader(); 
    my $sth;

    my $ident_level = 0;
    my $t = "";  # tabs
    my $tab = sub {
        my $adj = shift;
        $ident_level += $adj;
        $t = "\t" x $ident_level;
    };

    $r->print("<?xml version='1.0' encoding='utf-8' ?>\n");
    $r->print("<fotobilderexport version='1.0'>\n");
    $tab->(1);

    # profile
    $r->print("$t<profile>\n");
    $tab->(1);
    $r->print("$t<user>$u->{'user'}</user>\n");
    $r->print("$t<usercs>$u->{'usercs'}</usercs>\n");
    $tab->(-1);
    $r->print("$t</profile>\n");

    # pictures
    $r->print("$t<pics>\n");
    $tab->(1);
    $sth = $udb->prepare("SELECT upicid, secid, width, height, fmtid, bytes, gpicid, randauth ".
                         "FROM upic WHERE userid=?");
    $sth->execute($u->{'userid'});
    my %upic;
    while (my $up = $sth->fetchrow_hashref) {
        $upic{$up->{'upicid'}} = $up;
    }
    
    my $baseurl = FB::url_user($u);
    
    my $dump_pics = sub {
        my @ids = @_;
        
        # get the md5 values.
        my %md5;
        $sth = $db->prepare("SELECT gpicid, md5sum FROM gpic WHERE gpicid IN (".
                            join(",", map { $upic{$_}->{'gpicid'} } @ids) . ")");
        $sth->execute;
        while (my ($id, $md5sum) = $sth->fetchrow_array) {
            $md5sum .= " "x(16-length($md5sum)); # trailing spaces removed
            $md5sum =~ s/(.)/sprintf("%02x", ord($1))/esg;
            $md5{$id} = $md5sum;
        }
        
        my ($from, $to) = ($ids[0], $ids[-1]);
        
        # get props
        my %prop;
        $sth = $udb->prepare("SELECT upicid, propid, value FROM upicprop ".
                             "WHERE userid=? AND upicid BETWEEN ? AND ?");
        $sth->execute($u->{'userid'}, $from, $to);
        my $ps = FB::get_props();
        while (my ($id, $pid, $val) = $sth->fetchrow_array) {
            next unless $ps->{$pid};
            $prop{$id}->{$ps->{$pid}} = $val;
        }

        # get descriptions
        my %des;
        $sth = $udb->prepare("SELECT itemid, des FROM des ".
                             "WHERE userid=? AND itemtype='P' AND ".
                             "itemid BETWEEN ? AND ?");
        $sth->execute($u->{'userid'}, $from, $to);
        while (my ($id, $des) = $sth->fetchrow_array) {
            $des{$id} = $des;
        }

        # dump this batch;
        foreach my $id (@ids)
        {
            my $up = $upic{$id};
            next unless defined $md5{$up->{'gpicid'}};
            my $piccode = FB::piccode($up);
            $r->print("$t<pic picid='$id'>\n");
            $tab->(1);
            $r->print("$t<secid>$up->{'secid'}</secid>\n");
            $r->print("$t<width>$up->{'width'}</width>\n");
            $r->print("$t<height>$up->{'height'}</height>\n");
            $r->print("$t<bytes>$up->{'bytes'}</bytes>\n");
            $r->print("$t<format>" . FB::fmtid_to_mime($up->{'fmtid'}) . "</format>\n");
            $r->print("$t<md5>$md5{$up->{'gpicid'}}</md5>\n");
            $r->print("$t<url>${baseurl}pic/$piccode</url>\n");
            $prop{$id} ||= {};
            foreach my $prop (sort keys %{$prop{$id}}) {
                $r->print("$t<prop name='$prop'>" . FB::exml($prop{$id}->{$prop}) . "</prop>\n");
            }
            if ($des{$id}) {
                $r->print("$t<des>" . FB::exml($des{$id}) . "</des>\n");
            }
            $tab->(-1);
            $r->print("$t</pic>\n");
        }
    };

    my @pics = sort { $a <=> $b } keys %upic;
    while (@pics) {
        my $size = @pics;
        $size = 100 if $size > 100;
        my @batch = splice(@pics, 0, $size);
        $dump_pics->(@batch);
    }
    $tab->(-1);
    $r->print("$t</pics>\n");

    # dump galleries
    my %gal;
    $sth = $udb->prepare("SELECT gallid, name, secid, randauth, dategal, timeupdate ".
                         "FROM gallery WHERE userid=?");
    $sth->execute($u->{'userid'});
    while (my $g = $sth->fetchrow_hashref) {
        $gal{$g->{'gallid'}} = $g;
    }

    my $dump_gals = sub {
        my @ids = @_;

        my ($from, $to) = ($ids[0], $ids[-1]);

        # get props
        my %prop;
        $sth = $udb->prepare("SELECT gallid, propid, value FROM galleryprop ".
                             "WHERE userid=? AND gallid BETWEEN ? AND ?");
        $sth->execute($u->{'userid'}, $from, $to);
        my $ps = FB::get_props();
        while (my ($id, $pid, $val) = $sth->fetchrow_array) {
            next unless $ps->{$pid};
            $prop{$id}->{$ps->{$pid}} = $val;
        }

        # get descriptions
        my %des;
        $sth = $udb->prepare("SELECT itemid, des FROM des ".
                             "WHERE userid=? AND itemtype='G' AND ".
                             "itemid BETWEEN ? AND ?");
        $sth->execute($u->{'userid'}, $from, $to);
        while (my ($id, $des) = $sth->fetchrow_array) {
            $des{$id} = $des;
        }

        # get members
        my %mem;
        $sth = $udb->prepare("SELECT gallid, upicid, sortorder ".
                             "FROM gallerypics WHERE userid=? AND ".
                             "gallid BETWEEN ? AND ?");
        $sth->execute($u->{'userid'}, $from, $to);
        while (my ($gid, $pid, $sort) = $sth->fetchrow_array) {
            $mem{$gid}->{$pid} = $sort;
        }

        foreach my $id (@ids) {
            my $g = $gal{$id};
            $r->print("$t<gallery gallid='$g->{'gallid'}' secid='$g->{'secid'}'>\n");
            $tab->(1);
            $r->print("$t<name>" . FB::exml($g->{'name'}) . "</name>\n");
            $r->print("$t<url>${baseurl}gallery/" . FB::make_code($id, $g->{'randauth'}) . "</url>\n");
            $prop{$id} ||= {};
            foreach my $prop (sort keys %{$prop{$id}}) {
                $r->print("$t<prop name='$prop'>" . FB::exml($prop{$id}->{$prop}) . "</prop>\n");
            }
            if ($des{$id}) {
                $r->print("$t<des>" . FB::exml($des{$id}) . "</des>\n");
            }

            # gallery members
            $r->print("$t<galmembers>\n");
            $tab->(1);
            $mem{$id} ||= {};
            foreach my $pid (sort { $mem{$id}->{$a} <=> $mem{$id}->{$b} } 
                             keys %{$mem{$id}}) {
                $r->print("$t<galmember picid='$pid' />\n");
            }
            $tab->(-1);
            $r->print("$t</galmembers>\n");
            $tab->(-1);
            $r->print("$t</gallery>\n");
        }
    };

    $r->print("$t<galleries>\n");
    $tab->(1);
    my @gals = sort { $a <=> $b } keys %gal;
    while (@gals) {
        my $size = @gals;
        $size = 100 if $size > 100;
        $dump_gals->(splice(@gals, 0, $size));
    }
    $tab->(-1);
    $r->print("$t</galleries>\n");

    # gallery relationships
    $r->print("$t<galleryrels>\n");
    $tab->(1);
    $sth = $udb->prepare("SELECT gallid, gallid2, sortorder ".
                         "FROM galleryrel WHERE userid=? AND type='C'");
    $sth->execute($u->{'userid'});
    while (my ($sid, $did, $sortorder) = $sth->fetchrow_array) {
        $r->print("$t<galleryrel fromid='$sid' toid='$did' order='$sortorder' />\n");
    }
    $tab->(-1);
    $r->print("$t</galleryrels>\n");

    $tab->(-1);
    $r->print("$t</fotobilderexport>\n");

    return 1;
}

1;
