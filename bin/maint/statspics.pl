#!/usr/bin/perl
#

$maint{'genstatspics'} = sub 
{
    &connect_db();
    use GD::Graph::bars;

    print "-I- paid accounts by day.\n";

    ### suck the data in
    $sth = $dbh->prepare("SELECT DATE_FORMAT(datesent, '%Y-%m-%d') AS 'day', COUNT(*) AS 'count' FROM payments GROUP BY 1 ORDER BY 1 DESC LIMIT 60");
    $sth->execute;
    if ($dbh->err) { die $dbh->errstr; }

    my @data;
    my $i;
    my $max;
    while (my ($date, $count) = $sth->fetchrow_array) 
    {
	$date =~ s/^\d\d\d\d-//;
	unshift @{$data[0]}, ($i++ % 5 == 0 ? $date : "");
	unshift @{$data[1]}, $count;
	if ($count > $max) { $max = $count; }
    }

    # posts by day graph
    my $g = GD::Graph::bars->new(520, 350);
    $g->set(
	    x_label           => 'Day',
	    y_label           => 'Accounts',
	    title             => 'Paid accounts per day',
	    tranparent        => 0,
	    y_max_value       => $max,
	    );

    my $gd = $g->plot(\@data);
    open(IMG, ">$LJ::HTDOCS/stats/paidbyday.png") or die $!;
    binmode IMG;
    print IMG $gd->png;
    close IMG;

    print "-I- new accounts by day.\n";

    ### suck the data in
    $sth = $dbh->prepare("SELECT DATE_FORMAT(statkey, '%m-%d') AS 'day', statval AS 'new' FROM stats WHERE statcat='newbyday' ORDER BY statkey DESC LIMIT 60");
    $sth->execute;
    if ($dbh->err) { die $dbh->errstr; }

    my @data;
    my $i;
    my $max;
    while ($_ = $sth->fetchrow_hashref) 
    {
	my $val = $_->{'new'};
	unshift @{$data[0]}, ($i++ % 5 == 0 ? $_->{'day'} : "");
	unshift @{$data[1]}, $val;
	if ($val > $max) { $max = $val; }
    }

    # posts by day graph
    my $g = GD::Graph::bars->new(520, 350);
    $g->set(
	    x_label           => 'Day',
	    y_label           => 'Accounts',
	    title             => 'New accounts per day',
	    tranparent        => 0,
	    y_max_value       => $max,
	    );

    my $gd = $g->plot(\@data);
    open(IMG, ">$LJ::HTDOCS/stats/newbyday.png") or die $!;
    binmode IMG;
    print IMG $gd->png;
    close IMG;

    print "-I- posts in last 60 days.\n";

    ### suck the data in
    $sth = $dbh->prepare("SELECT DATE_FORMAT(statkey, '%m-%d') AS 'day', statval AS 'posts' FROM stats WHERE statcat='postsbyday' ORDER BY statkey DESC LIMIT 60");
    $sth->execute;
    if ($dbh->err) { die $dbh->errstr; }

    ### analyze the last 60 days data

    my @data;
    my $i;
    my $max;
    while ($_ = $sth->fetchrow_hashref) 
    {
	my $val = $_->{'posts'};
	unshift @{$data[0]}, ($i++ % 5 == 0 ? $_->{'day'} : "");
	unshift @{$data[1]}, $val;
	if ($val > $max) { $max = $val; }
    }

    # posts by day graph
    my $g = GD::Graph::bars->new(520, 350);
    $g->set(
	    x_label           => 'Day',
	    y_label           => 'Posts',
	    title             => 'LiveJournal posts per day',
	    tranparent        => 0,
	    y_max_value       => $max,
	    );

    my $gd = $g->plot(\@data);
    open(IMG, ">$LJ::HTDOCS/stats/postsbyday.png") or die $!;
    binmode IMG;
    print IMG $gd->png;
    close IMG;

    print "-I- posts by week.\n";

    ### suck the data in
    $sth = $dbh->prepare("SELECT DATE_FORMAT(statkey, '%X-%V') AS 'week', SUM(statval) AS 'posts' FROM stats WHERE statcat='postsbyday' AND DATE_FORMAT(statkey, '%X-%V') <> DATE_FORMAT(NOW(), '%X-%V') AND statkey>'1999-06-01' GROUP BY 1 ORDER BY statkey DESC");
    $sth->execute;
    if ($dbh->err) { die $dbh->errstr; }

    ### analyze the last 60 days data

    my @data;
    my $i;
    my $max;
    while ($_ = $sth->fetchrow_hashref) 
    {
	my $val = $_->{'posts'};
	unshift @{$data[0]}, ($i++ % 10 == 0 ? $_->{'week'} : "");
	unshift @{$data[1]}, $val;
	if ($val > $max) { $max = $val; }
    }

    # posts by week graph
    my $g = GD::Graph::bars->new(520, 350);
    $g->set(
	    x_label           => 'Week',
	    y_label           => 'Posts',
	    title             => 'LiveJournal posts per week',
	    tranparent        => 0,
	    y_max_value       => $max,
	    );

    my $gd = $g->plot(\@data);
    open(IMG, ">$LJ::HTDOCS/stats/postsbyweek.png") or die $!;
    binmode IMG;
    print IMG $gd->png;
    close IMG;

    print "-I- done.\n";

};


1;
