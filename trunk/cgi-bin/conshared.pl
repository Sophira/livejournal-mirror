#!/usr/bin/perl
#

use strict;
package LJ::Con;

use vars qw(%cmd);

$cmd{'shared'}->{'handler'} = \&shared;
$cmd{'community'}->{'handler'} = \&community;
$cmd{'change_community_admin'}->{'handler'} = \&change_community_admin;

sub change_community_admin
{
    my ($dbh, $remote, $args, $out) = @_;
    my $sth;
    my $err = sub { push @$out, [ "error", $_[0] ]; return 0; };
    my $dbs = LJ::make_dbs_from_arg($dbh);

    return $err->("This command takes exactly 2 arguments.  Consult the reference.")
        unless scalar(@$args) == 3;

    my ($comm_name, $newowner_name) = ($args->[1], $args->[2]);
    my $ucomm = LJ::load_user($dbh, $comm_name);
    my $unew  = LJ::load_user($dbh, $newowner_name);

    return $err->("Given community doesn't exist or isn't a community.")
        unless ($ucomm && $ucomm->{'journaltype'} eq "C");

    return $err->("New owner doesn't exist or isn't a person account.")
        unless ($unew && $unew->{'journaltype'} eq "P");

    return $err->("You do not have access to transfer ownership of this community.")
        unless $remote->{'priv'}->{'communityxfer'};

    return $err->("New owner's email address isn't validated.")
        unless ($unew->{'status'} eq "A");
    
    my $commid = $ucomm->{'userid'};
    my $newid = $unew->{'userid'};

    # remove old maintainers' power over it
    LJ::clear_rel($ucomm, '*', 'A');

    # add a new sole maintainer
    LJ::set_rel($ucomm, $newid, 'A');

    # so old maintainers can't regain access:
    $dbh->do("DELETE FROM infohistory WHERE userid=$commid");

    # change password & email of community to new maintainer's password
    LJ::update_user($ucomm, { password => $unew->{'password'}, email => $unew->{'email'} });

    ## log to status history
    LJ::statushistory_add($dbh, $commid, $remote->{'userid'}, "communityxfer", "Changed maintainer to '$unew->{'user'}'($newid)");
    LJ::statushistory_add($dbh, $newid, $remote->{'userid'}, "communityxfer", "Control of '$ucomm->{'user'}'($commid) given.");

    push @$out, [ "info", "Transfered ownership of \"$ucomm->{'user'}\"." ];
    return 1;
}

sub shared
{
    my ($dbh, $remote, $args, $out) = @_;
    my $error = 0;
    my $dbs = LJ::make_dbs_from_arg($dbh);

    unless (scalar(@$args) == 4) {
        $error = 1;
        push @$out, [ "error", "This command takes exactly 3 arguments.  Consult the reference." ];
    }
    
    return 0 if ($error);

    my ($shared_user, $action, $target_user) = ($args->[1], $args->[2], $args->[3]);
    my $shared_id = LJ::get_userid($dbh, $shared_user);
    my $target_id = LJ::get_userid($dbh, $target_user);

    unless ($action eq "add" || $action eq "remove") {
        $error = 1;
        push @$out, [ "error", "Invalid action \"$action\" ... expected 'add' or 'remove'" ];
    }
    unless ($shared_id) {
        $error = 1;
        push @$out, [ "error", "Invalid shared journal \"$shared_user\"" ];
    }
    unless ($target_id) {
        $error = 1;
        push @$out, [ "error", "Invalid user \"$target_user\" to add/remove" ];
    }
    if ($target_id && $target_id==$shared_id) {
        $error = 1;
        push @$out, [ "error", "Target user can't be shared journal user." ];
    }
    
    unless (LJ::check_rel($dbs, $shared_id, $remote, 'A') ||
            $remote->{'privarg'}->{'sharedjournal'}->{'all'}) 
    {
        $error = 1;
        push @$out, [ "error", "You don't have access to add/remove users to this shared journal." ];
    }
    
    return 0 if ($error);    
    
    my $dbs = LJ::make_dbs_from_arg($dbh);
    if ($action eq "add") {
        LJ::set_rel($shared_id, $target_id, 'P');
        push @$out, [ "info", "User \"$target_user\" can now post in \"$shared_user\"." ];
    } 
    if ($action eq "remove") {
        LJ::clear_rel($shared_id, $target_id, 'P');
        push @$out, [ "info", "User \"$target_user\" can no longer post in \"$shared_user\"." ];
    }

    return 1;
}

sub community
{
    my ($dbh, $remote, $args, $out) = @_;
    my $error = 0;
    my $sth;
    my $dbs = LJ::make_dbs_from_arg($dbh);

    unless (scalar(@$args) == 4) {
        $error = 1;
        push @$out, [ "error", "This command takes exactly 3 arguments.  Consult the reference." ];
    }
    
    return 0 if ($error);

    my ($com_user, $action, $target_user) = ($args->[1], $args->[2], $args->[3]);
    my $comm = LJ::load_user($com_user);
    my $com_id = $comm->{'userid'};
    my $target = LJ::load_user($target_user);
    my $target_id = $target->{'userid'};

    my $ci;
    
    unless ($action eq "add" || $action eq "remove") {
        $error = 1;
        push @$out, [ "error", "Invalid action \"$action\" ... expected 'add' or 'remove'" ];
    }
    unless ($com_id) {
        $error = 1;
        push @$out, [ "error", "Invalid community \"$com_user\"" ];
    } 
    else 
    {
        $sth = $dbh->prepare("SELECT userid, membership, postlevel FROM community WHERE userid=$com_id");
        $sth->execute;
        $ci = $sth->fetchrow_hashref;
        
        unless ($ci) {
            $error = 1;
            push @$out, [ "error", "\"$com_user\" isn't a registered community." ];
        }
    }

    unless ($target_id) {
        $error = 1;
        push @$out, [ "error", "Invalid user \"$target_user\" to add/remove" ];
    }
    if ($target_id && $target_id==$com_id) {
        $error = 1;
        push @$out, [ "error", "Target user can't be shared journal user." ];
    }
    
    # user doesn't need admin priv to remove themselves from community

    unless (LJ::check_rel($dbs, $com_id, $remote, 'A') ||
            $remote->{'privarg'}->{'sharedjournal'}->{'all'} ||
            ($remote->{'user'} eq $target_user && $action eq "remove")) 
    {
        my $modifier = $action eq "add" ? "to" : "from";
        $error = 1;
        push @$out, [ "error", "You don't have access to $action users $modifier this shared journal." ];
    }
    
    return 0 if ($error);    
    
    if ($action eq "add") 
    {
        my $attr = ['member'];
        push @$attr, 'post' if $ci->{'postlevel'} eq "members";
        my $res = LJ::comm_member_request($comm, $target, $attr);
        unless ($res) {
            push @$out, [ 'error', "Could not add user." ];
            return 0;
        }

        push @$out, [ "info", "User \"$target_user\" has been mailed and will be added to \"$com_user\" pending their approval." ];
        
        if ($ci->{'postlevel'}) {
            push @$out, [ "info", "User \"$target_user\" will be allowed to post to \"$com_user\" once they are added." ];
        } 
    }
        
    if ($action eq "remove") {
        $dbh->do("DELETE FROM friends WHERE userid=$com_id AND friendid=$target_id");
        push @$out, [ "info", "User \"$target_user\" is no longer a member of \"$com_user\"." ];

        LJ::clear_rel($com_id, $target_id, 'P');
        push @$out, [ "info", "User \"$target_user\" can no longer post in \"$com_user\"." ];
    }

    return 1;
}

1;


