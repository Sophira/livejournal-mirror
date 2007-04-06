#!/usr/bin/perl
#
# NOTE: do not modify this file!  These are just fall-back values
#       in case you forgot to set something in etc/fbconfig.pl
# 

{
    package FB;
    use Sys::Hostname ();

    $DEFAULT_STYLE ||= {
        'core' => 'core1', 
        'i18nc' => '',
        'layout' => 'supersimple/layout',
        'theme' => '',
        'i18n' => '',
        'user' => '',
    };

    @NEW_PICS_ON = (['disk', 1]) unless @NEW_PICS_ON;

    $SERVER_NAME ||= Sys::Hostname::hostname();

    # set some defaults.
    $STOCK_BGCOLOR ||= "ffffff";
    $STOCK_TEXTCOLOR ||= "000000";
    $STOCK_LINKCOLOR ||= "0000ff";
    $STOCK_VLINKCOLOR ||= "7f007f";
    $STOCK_HEADINGCOLOR ||= "000000";
    $STOCK_BARTEXTCOLOR ||= "000000";
    $STOCK_BARCOLOR ||= "7f74fc";
    $STOCK_BARCOLOR_LIGHT ||= "b1aaff";

    $FB::SESSION_LENGTH{short} ||= 60*60*24*1.5;
    $FB::SESSION_LENGTH{long}  ||= 60*60*24*7;

    $FB::HELPURL{'galsecurity'} = "/help/index.bml?topic=galsec"
        unless exists $FB::HELPURL{'galsecurity'};

    # set default capability limits if the site maintainer hasn't.
    {
        my %defcap = (
                      'styles' => 1,
                      'maxlayers' => 100,
                      'gallery_enabled' => 1,
                      'gallery_private' => 0,
                      'can_upload' => 1,
                      'deg_level' => 0,
                      );
        while (my ($k, $v) = each %defcap) {
            next if defined $FB::CAP_DEF{$k};
            $FB::CAP_DEF{$k} = $v;
        }
    }

    # find a suitable temporary dir
    unless ($FB::TEMP_DIR && -e $FB::TEMP_DIR) {
        if (-e "$FB::HOME/tmp") { $FB::TEMP_DIR = "$FB::HOME/tmp"; }
        else { $FB::TEMP_DIR = "/tmp"; }
    }
}
1;
