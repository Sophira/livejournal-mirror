#!/usr/bin/perl
#

use strict;
package LJ::Img;
use vars qw(%img);

$img{'ins_obj'} = {
    'src' => '/ins-object.gif?v=1',
    'width' => 129,
    'height' => 52,
    'alt' => 'img.ins_obj',
};

$img{'btn_up'} = {
    'src' => '/btn_up.gif?v=1',
    'width' => 22,
    'height' => 20,
    'alt' => 'img.btn_up',
};

$img{'btn_down'} = {
    'src' => '/btn_dn.gif?v=1',
    'width' => 22,
    'height' => 20,
    'alt' => 'img.btn_down',
};

$img{'btn_del'} = {
    'src' => '/btn_del.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.btn_del',
};

$img{'btn_freeze'} = {
    'src' => '/btn_freeze.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.btn_freeze',
};

$img{'btn_unfreeze'} = {
    'src' => '/btn_unfreeze.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.btn_unfreeze',
};

$img{'btn_scr'} = {
    'src' => '/btn_scr.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.btn_scr',
};

$img{'btn_unscr'} = {
    'src' => '/btn_unscr.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.btn_unscr',
};

$img{'prev_entry'} = {
    'src' => '/btn_prev.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.prev_entry',
};

$img{'next_entry'} = {
    'src' => '/btn_next.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.next_entry',
};

$img{'memadd'} = {
    'src' => '/memadd.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.memadd',
};

$img{'editentry'} = {
    'src' => '/btn_edit.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.editentry',
};

$img{'edittags'} = {
    'src' => '/btn_edittags.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.edittags',
};

$img{'tellfriend'} = {
    'src' => '/btn_tellfriend.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.tellfriend',
};

$img{'placeholder'} = {
    'src' => '/imageplaceholder2.png',
    'width' => 35,
    'height' => 35,
    'alt' => 'img.placeholder',
};

$img{'xml'} = {
    'src' => '/xml.gif?v=1',
    'width' => 36,
    'height' => 14,
    'alt' => 'img.xml',
};

$img{'track'} = {
    'src' => '/btn_track.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.track',
};

$img{'track_active'} = {
    'src' => '/btn_tracking.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.track_active',
};

$img{'track_thread_active'} = {
    'src' => '/btn_tracking_thread.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.track_thread_active',
};

$img{'flag'} = {
    'src' => '/button-flag.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.flag_btn',
};

$img{'editcomment'} = {
    'src' => '/btn_edit.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.editcomment',
};

$img{'sharethis'} = {
    'src' => '/btn_sharethis.gif?v=2',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.sharethis',
};

$img{'share'} = {
    'src' => '/btn_share.gif?v=1',
    'width' => 24,
    'height' => 24,
    'alt' => 'img.share',
};

# load the site-local version, if it's around.
if (-e "$LJ::HOME/cgi-bin/imageconf-local.pl") {
    require "$LJ::HOME/cgi-bin/imageconf-local.pl";
}

1;

