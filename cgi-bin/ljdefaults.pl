#!/usr/bin/perl
#
# Do not edit this file.  You should edit ljconfig.pl, which you should have at
# cgi-bin/ljconfig.pl.  If you don't, copy it from doc/ljconfig.pl.txt to cgi-bin
# and edit it there.  This file only provides backup default values for upgrading.
#

{
    package LJ;

    $DEFAULT_STYLE ||= { 
        'core' => 'core1',
        'layout' => 'generator/layout',
        'i18n' => 'generator/en',
    };

    $HOME = $ENV{'LJHOME'};
    $HTDOCS = "$HOME/htdocs";
    $BIN = "$HOME/bin";

    $SITENAMESHORT = "LiveJournal";
    $SITENAMEABBREV = "LJ";

    $NODB_MSG ||= "Database temporarily unavailable.  Try again shortly.";

    $SITEROOT ||= "http://www.$DOMAIN:8011";
    $IMGPREFIX ||= "$SITEROOT/img";
    $USERPIC_ROOT ||= "$LJ::SITEROOT/userpic";

    # path to sendmail and any necessary options
    $SENDMAIL ||= "/usr/sbin/sendmail -t -oi";

    # where we set the cookies (note the period before the domain)
    $COOKIE_DOMAIN ||= ".$DOMAIN";
    $COOKIE_PATH   ||= "/";

    ## default portal options
    @PORTAL_COLS = qw(main right moz) unless (@PORTAL_COLS);

    $PORTAL_URI ||= "/portal/";           # either "/" or "/portal/"    

    $PORTAL_LOGGED_IN ||= {'main' => [ 
                                     [ 'update', 'mode=full'],
                                     ],
                         'right' => [ 
                                      [ 'stats', '', ],
                                      [ 'bdays', '', ],
                                      [ 'popfaq', '', ],
                                      ] };
    $PORTAL_LOGGED_OUT ||= {'main' => [ 
                                      [ 'update', 'mode='],
                                      ],
                          'right' => [ 
                                       [ 'login', '', ],
                                       [ 'stats', '', ],
                                       [ 'randuser', '', ],
                                       [ 'popfaq', '', ],
                                       ],
                          'moz' => [
                                    [ 'login', '', ],
                                    ],
                          };

   
    $MAX_HINTS_LASTN ||= 100;
    $MAX_SCROLLBACK_LASTN ||= 400;
    $MAX_SCROLLBACK_FRIENDS ||= 1000;

    $RECENT_SPAN ||= 14;

    # set default capability limits if the site maintainer hasn't.
    {
        my %defcap = (
                      'checkfriends' => 1,
                      'checkfriends_interval' => 60,
                      'friendsviewupdate' => 30,
                      'makepoll' => 1,
                      'maxfriends' => 500,
                      'moodthemecreate' => 1,
                      'styles' => 1,
                      'textmessage' => 1,
                      'todomax' => 100,
                      'todosec' => 1,
                      'userdomain' => 0,
                      'useremail' => 0,
                      'userpics' => 5,
                      'findsim' => 1,
                      'can_post' => 1,
                      'get_comments' => 1,
                      'leave_comments' => 1,
                      );
        foreach my $k (keys %defcap) {
            next if (defined $LJ::CAP_DEF{$k});
            $LJ::CAP_DEF{$k} = $defcap{$k};	    
        }
    }

    # set default userprop limits if site maintainer hasn't
    {
        my %defuser = (
                       's1_lastn_style'    => 'lastn/Default LiveJournal',
                       's1_friends_style'  => 'friends/Default Friends View',
                       's1_calendar_style' => 'calendar/Default Calendar',
                       's1_day_style'      => 'day/Default Day View',
                       );
        foreach my $k (keys %defuser) {
            next if (defined $LJ::USERPROP_DEF{$k});
            $LJ::USERPROP_DEF{$k} = $defuser{$k};
        }
    }
}

# no dependencies.
# <LJDEP>
# </LJDEP>

return 1;
