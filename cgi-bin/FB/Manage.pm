# Common stuff for the manage pages

package FB::Manage;
use strict;

# Return common stuff to insert in the headers of the manage pages
sub standard_head {
    my $class = shift;

    my $remote = FB::User->remote or return '';

    # generate hash of security groups for the JS functions to handle
    my $secgroups = $remote->secgroups;
    my %retsecgroups;
    while (my ($secid, $secgroup) = each %$secgroups) {
        $retsecgroups{$secid} = FB::SecGroup->name($remote, $secid);
    }
    my $secgroupjs = JSON::objToJson(\%retsecgroups);
    my $secids = join(',', keys %retsecgroups);

    LJ::need_res(qw(
                    js/core.js
                    js/dom.js
                    js/ippu.js
                    js/lj_ippu.js
                    js/httpreq.js
                    js/hourglass.js
                    js/galcreate.js
                    js/inputcomplete.js
                    js/galselectmenu.js
                    js/devel.js

                    js/progressbar.js
                    js/ljprogressbar.js
                    js/diskfree_widget.js

                    js/controller.js
                    js/manage/galmanagecontroller.js

                    js/datasource.js
                    js/jsondatasource.js
                    js/galdatasource.js
                    js/picdatasource.js
                    js/paginateddatasource.js

                    js/view.js
                    js/multiview.js
                    js/manage/managelistview.js
                    js/manage/managethumbview.js
                    js/paginationview.js
                    js/tabview.js
                    js/tabgroup.js


                    stc/fotobilder.css
                    stc/fb_manage.css
                    ));

    my $head = qq {
            <script language="JavaScript">
              var FB = {};

              FB.siteRoot = "$FB::SITEROOT";
              FB.secGroups = {"ids": [$secids], "groups": $secgroupjs};
            </script>
        };

    return $head;
}

1;
