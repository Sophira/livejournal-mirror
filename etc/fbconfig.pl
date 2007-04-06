#!/usr/bin/perl
# -*-perl-*-

# Sample fbconfig, edit to suit your environment
{
    package FB;
    $HOME = $ENV{'FBHOME'};

    $DOMAIN = "pics.megatron.dev.livejournal.org";
    $DOMAIN_WEB = "pics.megatron.dev.livejournal.org";

    $SITENAME = "Fotobuckit+";

    $IS_DEV_SERVER = 1;
#    $DEBUG = 1;

#    $IMPORT_WITHOUT_GEARMAN = 1;

    if (1) {
        @GEARMAN_SERVERS = ('127.0.0.1:7003');
        %GEARMAN_DISABLED = (thumbnail_image => 0,
                             scale_image     => 0,
                             importing       => 0);
    }

    $PIC_ROOT = "$HOME/var/picroot";

    $AUDIO_SUPPORT = 1;

    %MOGILEFS_CONFIG = (
                        domain => 'danga.com::fb', # arbitrary namespace, not dns domain
                        hosts  => (
                                   ['127.0.0.1:7001']
                                   ),
                        classes => {
                            alt => 2,
                        },
                        );

    # database info.  only the master is necessary.
    # you should probably change this
    %DBINFO = (
               'master' => {
                   'host' => "localhost",
                   'port' => 3306,
                   'user' => 'lj',
                   'pass' => 'ljpass',
                   'role' => {
                       'master' => 1,
                   }
               },
               'u1' => {
                   'host' => "localhost",
                   'port' => 3306,
                   'user' => 'lj',
                   'pass' => 'ljpass',
                   'dbname' => 'fb_c1',
                   'role' => {
                       'user1' => 1,
                   }
               },
               'u2' => {
                   'host' => "localhost",
                   'port' => 3306,
                   'user' => 'lj',
                   'pass' => 'ljpass',
                   'dbname' => 'fb_c2',
                   'role' => {
                       'user2' => 1,
                   }
               },
               );

    # keep this next line.  it lets you upgrade FotoBilder without
    # having to change your config file.  if there is a new required
    # configuration option, the following line will set it:
    require "$HOME/cgi-bin/fbdefaults.pl";

    # require policyconfig, if it exists
    if (-e "$HOME/etc/policyconfig.pl") {
        do "$HOME/etc/policyconfig.pl";
    }
}

1;  # return true
