# Common stuff for the manage pages

package FB::Manage;
use strict;

# Return common stuff to insert in the headers of the manage pages
sub standard_head {
    my $class = shift;

    my $authmod = FB::current_domain_plugin();
    my $siteroot = $authmod->site_root;

    my $remote = FB::User->remote or return '';

    # generate hash of security groups for the JS functions to handle
    my $secgroups = $remote->secgroups;
    my %retsecgroups;
    while (my ($secid, $secgroup) = each %$secgroups) {
        $retsecgroups{$secid} = FB::SecGroup->name($remote, $secid);
    }
    my $secgroupjs = JSON::objToJson(\%retsecgroups);
    my $secids = join(',', keys %retsecgroups);

    my $head = qq {
            <link rel='stylesheet' type='text/css' href='/static/manage.css' />

            <script language="JavaScript">
              var FB = {};

              FB.siteRoot = "$siteroot";
              FB.secGroups = {"ids": [$secids], "groups": $secgroupjs};
            </script>

            <script language="JavaScript" src="/js/core.js"></script>
            <script language="JavaScript" src="/js/dom.js"></script>
            <script language="JavaScript" src='/js/ippu.js'></script>
            <script language="JavaScript" src='/js/fb_ippu.js'></script>
            <script language="JavaScript" src='/js/httpreq.js'></script>
            <script language="JavaScript" src='/js/hourglass.js'></script>
            <script language="JavaScript" src='/js/galcreate.js'></script>
            <script language="JavaScript" src='/js/inputcomplete.js'></script>
            <script language="JavaScript" src='/js/galselectmenu.js'></script>
            <script language="JavaScript" src='/js/devel.js'></script>

            <script language="JavaScript" src='/js/progressbar.js'></script>
            <script language="JavaScript" src='/js/fbprogressbar.js'></script>
            <script language="JavaScript" src='/js/diskfree_widget.js'></script>

            <script language="JavaScript" src='/js/controller.js'></script>
            <script language="JavaScript" src='/js/manage/galmanagecontroller.js'></script>

            <script language="JavaScript" src='/js/datasource.js'></script>
            <script language="JavaScript" src='/js/jsondatasource.js'></script>
            <script language="JavaScript" src='/js/galdatasource.js'></script>
            <script language="JavaScript" src='/js/picdatasource.js'></script>
            <script language="JavaScript" src='/js/paginateddatasource.js'></script>

            <script language="JavaScript" src='/js/view.js'></script>
            <script language="JavaScript" src='/js/multiview.js'></script>
            <script language="JavaScript" src='/js/manage/managelistview.js'></script>
            <script language="JavaScript" src='/js/manage/managethumbview.js'></script>
            <script language="JavaScript" src='/js/paginationview.js'></script>
            <script language="JavaScript" src='/js/tabview.js'></script>
            <script language="JavaScript" src='/js/tabgroup.js'></script>
        };

    return $head;
}

1;
