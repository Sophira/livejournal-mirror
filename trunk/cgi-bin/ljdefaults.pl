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
    $JSPREFIX ||= "$SITEROOT/js";
    $USERPIC_ROOT ||= "$LJ::SITEROOT/userpic";
    $PALIMGROOT ||= "$LJ::SITEROOT/palimg";

    if ($LJ::DB_USERIDMAP ||= "") {
        $LJ::DB_USERIDMAP .= "." unless  $LJ::DB_USERIDMAP =~ /\.$/;
    }

    # path to sendmail and any necessary options
    $SENDMAIL ||= "/usr/sbin/sendmail -t -oi";

    # protocol, mailserver hostname, and preferential weight.
    # qmtp, smtp, dmtp, and sendmail are the currently supported protocols.
    @MAIL_TRANSPORTS = ( [ 'sendmail', $SENDMAIL, 1 ] ) unless @MAIL_TRANSPORTS;

    # where we set the cookies (note the period before the domain)
    $COOKIE_DOMAIN ||= ".$DOMAIN";
    $COOKIE_PATH   ||= "/";
    @COOKIE_DOMAIN_RESET = ("", "$DOMAIN", ".$DOMAIN") unless @COOKIE_DOMAIN_RESET;

    $MAX_HINTS_LASTN ||= 100;
    $MAX_SCROLLBACK_FRIENDS ||= 1000;
    $MAX_USERPIC_KEYWORDS ||= 10;

    # this option can be a boolean or a URL, but internally we want a URL
    # (which can also be a boolean)
    if ($LJ::OPENID_SERVER && $LJ::OPENID_SERVER == 1) {
        $LJ::OPENID_SERVER = "$LJ::SITEROOT/openid/server.bml";
    }

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
                      'rateallowed-lostinfo' => 5,
                      'tools_recent_comments_display' => 50,
                      'rateperiod-invitefriend' => 60, # 1 hour
                      'rateallowed-invitefriend' => 20,
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

    # maximum number of friendofs to load/memcache (affects userinfo.bml display)
    $MAX_FRIENDOF_LOAD ||= 5000;

    # whether to proactively delete any comments associated with an entry when we assign
    # a new jitemid (see the big comment above LJ::Protocol::new_entry_cleanup_hack)
    $NEW_ENTRY_CLEANUP_HACK ||= 0;

    # block size is used in stats generation code that gets n rows from the db at a time
    $STATS_BLOCK_SIZE ||= 10_000;

    # Maximum number of comments to display on Recent Comments page
    $TOOLS_RECENT_COMMENTS_MAX = 50;

    # setup the mogilefs defaults so we can create the necessary domains
    # and such. it is not recommended that you change the name of the
    # classes. you can feel free to add your own or alter the mindevcount
    # from within ljconfig.pl, but the LiveJournal code uses these class
    # names elsewhere and depends on them existing if you're using MogileFS
    # for storage.
    #
    # also note that this won't actually do anything unless you have
    # defined a MOGILEFS_CONFIG hash in ljconfig.pl and you explicitly set
    # at least the hosts key to be an arrayref of ip:port combinations
    # indicating where to reach your local MogileFS server.
    %MOGILEFS_CONFIG = () unless defined %MOGILEFS_CONFIG;
    $MOGILEFS_CONFIG{domain}                 ||= 'livejournal';
    $MOGILEFS_CONFIG{classes}                ||= {};
    $MOGILEFS_CONFIG{classes}->{userpics}    ||= 3;
    $MOGILEFS_CONFIG{classes}->{captcha}     ||= 2;

    # Default to allow all reproxying.
    %REPROXY_DISABLE = () unless %REPROXY_DISABLE;

    # Default error message for age verification needed
    $UNDERAGE_ERROR ||= "Sorry, your account needs to be <a href='$SITEROOT/agecheck/'>age verified</a> before you can leave any comments.";

    # Terms of Service revision requirements
    foreach (
             [ rev   => '0.0' ],
             [ title => 'Terms of Service agreement required' ],
             [ html  => '' ],
             [ text  => '' ]
             )
    {
        $LJ::REQUIRED_TOS{$_->[0]} = $_->[1]
            unless defined $LJ::REQUIRED_TOS{$_->[0]};
    }

    # setup default minimal style information
    $MINIMAL_USERAGENT{$_} ||= 1 foreach qw(Links Lynx w BlackBerry); # w is for w3m
    $MINIMAL_BML_SCHEME ||= 'lynx';
    $MINIMAL_STYLE{'core'} ||= 'core1';

    # maximum size to cache s2compiled data
    $MAX_S2COMPILED_CACHE_SIZE ||= 7500; # bytes
    $S2COMPILED_MIGRATION_DONE ||= 0;    # turn on after s2compiled2 migration

    # max limit of schools attended
    $SCHOOLSMAX ||= {
                     'P' => 25,
                     'I' => 25,
                     'C' => 50,
                     };

    # Portal boxes
    unless(scalar(@LJ::PORTAL_BOXES)) {
        @PORTAL_BOXES = (
                         'Birthdays',
                         'UpdateJournal',
                         'TextMessage',
                         'PopWithFriends',
                         'Friends',
                         'Manage',
                         'RecentComments',
                         'NewUser',
                         'FriendsPage',
                         'FAQ',
                         'Debug',
                         );
    }

    unless(scalar(@LJ::PORTAL_BOXES_HIDDEN)) {
        @PORTAL_BOXES_HIDDEN = (
                                'Debug',
                                );
    }

    unless (keys %LJ::PORTAL_DEFAULTBOXSTATES) {
        %PORTAL_DEFAULTBOXSTATES = (
                                    'Birthdays' => {
                                        'added' => 1,
                                        'sort'  => 4,
                                        'col'   => 'R',
                                    },
                                    'FriendsPage' => {
                                        'added' => 1,
                                        'sort'  => 6,
                                        'col'   => 'L',
                                    },
                                    'FAQ' => {
                                        'added' => 1,
                                        'sort'  => 8,
                                        'col'   => 'R',
                                    },
                                    'Friends' => {
                                        'added' => 1,
                                        'sort'  => 10,
                                        'col'   => 'R',
                                    },
                                    'Manage' => {
                                        'added' => 1,
                                        'sort'  => 12,
                                        'col'   => 'L',
                                    },
                                    'PopWithFriends' => {
                                        'added' => 0,
                                        'col'   => 'R',
                                    },
                                    'RecentComments' => {
                                        'added' => 1,
                                        'sort'  => 10,
                                        'col'   => 'L',
                                    },
                                    'UpdateJournal' => {
                                        'added' => 1,
                                        'sort'  => 4,
                                        'col'   => 'L',
                                    },
                                    'NewUser' => {
                                        'added' => 1,
                                        'sort'  => 2,
                                        'col'   => 'L',
                                    },
                                    'TextMessage' => {
                                        'added'  => 1,
                                        'sort'   => 12,
                                        'col'    => 'R',
                                    },
                                    );
    }
}

# no dependencies.
# <LJDEP>
# </LJDEP>

return 1;
