#!/usr/bin/perl
#
# Do not edit this file.  You should edit ljconfig.pl, which you should have at
# cgi-bin/ljconfig.pl.  If you don't, copy it from doc/ljconfig.pl.txt to cgi-bin
# and edit it there.  This file only provides backup default values for upgrading.
#

{
    package LJ;
    use Sys::Hostname ();

    $DEFAULT_STYLE ||= { 
        'core' => 'core1',
        'layout' => 'generator/layout',
        'i18n' => 'generator/en',
    };

    # cluster 0 is no longer supported
    $DEFAULT_CLUSTER ||= 1;
    @CLUSTERS = (1) unless @CLUSTERS;

    $HOME = $ENV{'LJHOME'};
    $HTDOCS = "$HOME/htdocs";
    $BIN = "$HOME/bin";

    $SERVER_NAME ||= Sys::Hostname::hostname();
    
    $UNICODE = 1 unless defined $UNICODE;

    @LANGS = ("en") unless @LANGS;
    $DEFAULT_LANG ||= $LANGS[0];

    $SITENAME ||= "NameNotConfigured.com";
    unless ($SITENAMESHORT) {
        $SITENAMESHORT = $SITENAME;
        $SITENAMESHORT =~ s/\..*//;  # remove .net/.com/etc
    }
    $SITENAMEABBREV ||= "[??]";

    $NODB_MSG ||= "Database temporarily unavailable.  Try again shortly.";
    $MSG_READONLY_USER ||= "Database temporarily in read-only mode during maintenance.";

    $SITEROOT ||= "http://www.$DOMAIN:8011";
    $IMGPREFIX ||= "$SITEROOT/img";
    $STATPREFIX ||= "$SITEROOT/stc";
    $USERPIC_ROOT ||= "$LJ::SITEROOT/userpic";
    $PALIMGROOT ||= "$LJ::SITEROOT/palimg";

    if ($LJ::DB_USERIDMAP ||= "") {
        $LJ::DB_USERIDMAP .= "." unless  $LJ::DB_USERIDMAP =~ /\.$/;
    }

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
    $MAX_SCROLLBACK_FRIENDS ||= 1000;
    $MAX_USERPIC_KEYWORDS ||= 5;

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
                      's2styles' => 1,
                      's2viewentry' => 1,
                      's2viewreply' => 1,
                      's2stylesmax' => 10,
                      's2layersmax' => 50,
                      'textmessage' => 1,
                      'todomax' => 100,
                      'todosec' => 1,
                      'userdomain' => 0,
                      'useremail' => 0,
                      'userpics' => 5,
                      'findsim' => 1,
                      'full_rss' => 1,
                      'can_post' => 1,
                      'get_comments' => 1,
                      'leave_comments' => 1,
                      'mod_queue' => 50,
                      'mod_queue_per_poster' => 1,
                      'weblogscom' => 0,
                      'hide_email_after' => 0,
                      'userlinks' => 5,
                      'maxcomments' => 5000,
                      'rateperiod-lostinfo' => 24*60, # 24 hours
                      'rateallowed-lostinfo' => 3,
                      );
        foreach my $k (keys %defcap) {
            next if (defined $LJ::CAP_DEF{$k});
            $LJ::CAP_DEF{$k} = $defcap{$k};	    
        }
    }

    # FIXME: should forcibly limit userlinks to 255 (tinyint)

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

    # Send community invites from the admin address unless otherwise specified
    $COMMUNITY_EMAIL ||= $ADMIN_EMAIL;

    # By default, auto-detect account types for
    # <lj user> tags only if using memcache
    unless (defined $LJ::DYNAMIC_LJUSER) {
        $LJ::DYNAMIC_LJUSER = scalar(@LJ::MEMCACHE_SERVERS) ? 1 : 0;
    }

    # The list of content types that we consider valid for gzip compression.
    %GZIP_OKAY = (
        'text/html' => 1,               # regular web pages; XHTML 1.0 "may" be this
        'text/xml' => 1,                # regular XML files
        'application/xml' => 1,         # XHTML 1.1 "may" be this
        'application/xhtml+xml' => 1,   # XHTML 1.1 "should" be this
        'application/rdf+xml' => 1,     # FOAF should be this
    ) unless %GZIP_OKAY;

    # maximum FOAF friends to return (so the server doesn't get overloaded)
    $MAX_FOAF_FRIENDS ||= 1000;

    # whether to proactively delete any comments associated with an entry when we assign
    # a new jitemid (see the big comment above LJ::Protocol::new_entry_cleanup_hack)
    $NEW_ENTRY_CLEANUP_HACK ||= 0;

    # block size is used in stats generation code that gets n rows from the db at a time
    $STATS_BLOCK_SIZE ||= 10_000;
}

# no dependencies.
# <LJDEP>
# </LJDEP>

return 1;
