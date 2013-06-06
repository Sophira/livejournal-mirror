package LJ;
use strict;

# Do not edit this file.  You should edit ljconfig.pl, which you should have at
# cgi-bin/ljconfig.pl.  If you don't, copy it from doc/ljconfig.pl.txt to cgi-bin
# and edit it there.  This file only provides backup default values for upgrading.
#

{
    package LJ;
    use Sys::Hostname ();

    $LJ::DEFAULT_STYLE ||= {
        'core' => 'core1',
        'layout' => 'generator/layout',
        'i18n' => 'generator/en',
    };

    $LJ::HOME = $ENV{'LJHOME'};
    $LJ::HTDOCS = "$LJ::HOME/htdocs";
    $LJ::SSLDOCS ||= "$LJ::HOME/ssldocs";
    $LJ::BIN = "$LJ::HOME/bin";

    $LJ::SERVER_NAME ||= Sys::Hostname::hostname();

    $LJ::UNICODE = 1 unless defined $LJ::UNICODE;

    @LJ::LANGS = ("en") unless @LJ::LANGS;
    $LJ::DEFAULT_LANG ||= $LJ::LANGS[0];

    $LJ::SITENAME ||= "NameNotConfigured.com";
    unless ($LJ::SITENAMESHORT) {
        $LJ::SITENAMESHORT = $LJ::SITENAME;
        $LJ::SITENAMESHORT =~ s/\..*//;  # remove .net/.com/etc
    }
    $LJ::SITENAMEABBREV ||= "[??]";

    $LJ::MSG_READONLY_USER ||= "Database temporarily in read-only mode during maintenance.";

    $LJ::DOMAIN_WEB ||= "www.$LJ::DOMAIN";
    $LJ::SITEROOT ||= "http://$LJ::DOMAIN_WEB";
    $LJ::IMGPREFIX ||= "$LJ::SITEROOT/img";
    $LJ::STATPREFIX ||= "$LJ::SITEROOT/stc";
    $LJ::WSTATPREFIX ||= "$LJ::SITEROOT/stc";
    $LJ::JSPREFIX ||= "$LJ::SITEROOT/js";
    $LJ::USERPIC_ROOT ||= "$LJ::SITEROOT/userpic";
    $LJ::PALIMGROOT ||= "$LJ::SITEROOT/palimg";

    # path to sendmail and any necessary options
    $LJ::SENDMAIL ||= "/usr/sbin/sendmail -t -oi";

    # protocol, mailserver hostname, and preferential weight.
    # qmtp, smtp, dmtp, and sendmail are the currently supported protocols.
    @LJ::MAIL_TRANSPORTS = ( [ 'sendmail', $LJ::SENDMAIL, 1 ] ) unless @LJ::MAIL_TRANSPORTS;

    # roles that slow support queries should use in order of precedence
    @LJ::SUPPORT_SLOW_ROLES = ('slow') unless @LJ::SUPPORT_SLOW_ROLES;

    # where we set the cookies (note the period before the domain)
    $LJ::COOKIE_DOMAIN ||= ".$LJ::DOMAIN";
    $LJ::COOKIE_PATH   ||= "/";
    @LJ::COOKIE_DOMAIN_RESET = ("", "$LJ::DOMAIN", ".$LJ::DOMAIN") unless @LJ::COOKIE_DOMAIN_RESET;

    $LJ::MAX_SCROLLBACK_LASTN ||= 100;
    $LJ::MAX_SCROLLBACK_FRIENDS ||= 1000;
    $LJ::MAX_USERPIC_KEYWORDS ||= 10;

    $LJ::AUTOSAVE_DRAFT_INTERVAL ||= 3;

    # this option can be a boolean or a URL, but internally we want a URL
    # (which can also be a boolean)
    if ($LJ::OPENID_SERVER && $LJ::OPENID_SERVER eq 1) {
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
                      's2props' => 1,
                      's2viewentry' => 1,
                      's2viewreply' => 1,
                      's2stylesmax' => 10,
                      's2layersmax' => 50,
                      'textmessage' => 1,
                      'todomax' => 100,
                      'todosec' => 1,
                      'userdomain' => 0,
                      'domainmap' => 0,
                      'useremail' => 0,
                      'userpics' => 5,
                      'findsim' => 1,
                      'full_rss' => 1,
                      'can_post' => 1,
                      'get_comments' => 1,
                      'leave_comments' => 1,
                      'mod_queue' => 250,
                      'mod_queue_per_poster' => 1,
                      'weblogscom' => 0,
                      'hide_email_after' => 0,
                      'userlinks' => 5,
                      'maxcomments' => 10000,
                      'maxcomments-before-captcha' => 5000,
                      'rateperiod-lostinfo' => 24*60, # 24 hours
                      'rateallowed-lostinfo' => 5,
                      'tools_recent_comments_display' => 50,
                      'rateperiod-invitefriend' => 60, # 1 hour
                      'rateallowed-invitefriend' => 20,
                      'subscriptions' => 25,
                      'usermessage_length' => 5000,
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
                       's1_lastn_style'    => 'lastn/Generator',
                       's1_friends_style'  => 'friends/Generator',
                       's1_calendar_style' => 'calendar/Generator',
                       's1_day_style'      => 'day/Generator',
                       );
        foreach my $k (keys %defuser) {
            next if (defined $LJ::USERPROP_DEF{$k});
            $LJ::USERPROP_DEF{$k} = $defuser{$k};
        }
    }

    # Send community invites from the admin address unless otherwise specified
    $LJ::COMMUNITY_EMAIL ||= $LJ::ADMIN_EMAIL;

    # The list of content types that we consider valid for gzip compression.
    %LJ::GZIP_OKAY = (
        'text/html' => 1,               # regular web pages; XHTML 1.0 "may" be this
        'text/xml' => 1,                # regular XML files
        'application/xml' => 1,         # XHTML 1.1 "may" be this
        'application/xhtml+xml' => 1,   # XHTML 1.1 "should" be this
        'application/rdf+xml' => 1,     # FOAF should be this
        'application/json' => 1,
        'application/javascript' => 1,
    ) unless %LJ::GZIP_OKAY;

    # maximum FOAF friends to return (so the server doesn't get overloaded)
    $LJ::MAX_FOAF_FRIENDS ||= 1000;

    # maximum number of friendofs to load/memcache (affects userinfo.bml display)
    $LJ::MAX_FRIENDOF_LOAD ||= 5000;

    # whether to proactively delete any comments associated with an entry when we assign
    # a new jitemid (see the big comment above LJ::Protocol::new_entry_cleanup_hack)
    $LJ::NEW_ENTRY_CLEANUP_HACK ||= 0;

    # block size is used in stats generation code that gets n rows from the db at a time
    $LJ::STATS_BLOCK_SIZE ||= 10_000;

    # Maximum number of comments to display on Recent Comments page
    $LJ::TOOLS_RECENT_COMMENTS_MAX ||= 50;

    # Default to allow all reproxying.
    %LJ::REPROXY_DISABLE = () unless %LJ::REPROXY_DISABLE;

    # Default error message for age verification needed
    $LJ::UNDERAGE_ERROR ||= "Sorry, your account needs to be <a href='$LJ::SITEROOT/agecheck/'>age verified</a> before you can leave any comments.";

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
    $LJ::MINIMAL_USERAGENT{$_} ||= 1 foreach qw(Links Lynx w BlackBerry WebTV); # w is for w3m
    $LJ::MINIMAL_BML_SCHEME ||= 'lynx';
    $LJ::MINIMAL_STYLE{'core'} ||= 'core1';

    $LJ::S2COMPILED_MIGRATION_DONE ||= 0;    # turn on after s2compiled2 migration

    # max limit of schools attended
    $LJ::SCHOOLSMAX ||= {
                     'P' => 25,
                     'I' => 25,
                     'S' => 25,
                     'C' => 50,
                     };

    # max content length we should read via ATOM api
    # 25MB
    $LJ::MAX_ATOM_UPLOAD ||= 26214400;

    $LJ::CAPTCHA_AUDIO_MAKE ||= 100;
    $LJ::CAPTCHA_AUDIO_PREGEN ||= 100;
    $LJ::CAPTCHA_IMAGE_PREGEN ||= 500;
    $LJ::CAPTCHA_IMAGE_RAW ||= "$LJ::HOME/htdocs/img/captcha";

    $LJ::DEFAULT_EDITOR ||= 'rich';

    # Portal boxes
    unless(scalar(@LJ::PORTAL_BOXES)) {
        @LJ::PORTAL_BOXES = (
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
                         'Note',
                         'RandomUser',
                         'Tags',
                         'Reader',
                         );
    }

    unless(scalar(@LJ::PORTAL_BOXES_HIDDEN)) {
        @LJ::PORTAL_BOXES_HIDDEN = (
                                'Debug',
                                );
    }

    unless (keys %LJ::PORTAL_DEFAULTBOXSTATES) {
        %LJ::PORTAL_DEFAULTBOXSTATES = (
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
                                    'Frank' => {
                                        'notunique' => 1,
                                    },
                                    'Note' => {
                                        'notunique' => 1,
                                    },
                                    'Reader' => {
                                        'notunique' => 1,
                                    },
                                    );
    }

    unless (@LJ::EVENT_TYPES) {
        @LJ::EVENT_TYPES = qw (
                               Befriended
                               Birthday
                               JournalNewComment
                               JournalNewEntry
                               UserNewComment
                               UserNewEntry
                               CommunityInvite
                               CommunityJoinRequest
                               OfficialPost
                               InvitedFriendJoins
                               NewUserpic
                               PollVote
                               UserExpunged
                               );
        foreach my $evt (@LJ::EVENT_TYPES) {
            $evt = "LJ::Event::$evt";
        }
    }

    unless (@LJ::NOTIFY_TYPES) {
        @LJ::NOTIFY_TYPES = (
                            'Email',
                            );
        foreach my $evt (@LJ::NOTIFY_TYPES) {
            $evt = "LJ::NotificationMethod::$evt";
        }
    }
    unless (%LJ::BLOBINFO) {
        %LJ::BLOBINFO = (
                         clusters => {
                             1 => "$LJ::HOME/var/blobs/",
                         },
                         );
    }

    unless (scalar @LJ::PROTECTED_USERNAMES) {
        @LJ::PROTECTED_USERNAMES = ("^ex_", "^ext_", "^s_", "^_", '_$', '__');
    }

    $LJ::USERPROP_DEF{'blob_clusterid'} ||= 1;

    # setup default limits for mogilefs classes
    if (%LJ::MOGILEFS_CONFIG) {
        my %classes = (userpics => 3,
                       captcha => 2,
                       temp => 2,
                       );
        $LJ::MOGILEFS_CONFIG{classes} ||= {};
        foreach my $class (keys %classes) {
            $LJ::MOGILEFS_CONFIG{classes}{$class} ||= $classes{$class};
        }
    }

    # sms defaults
    $LJ::SMS_DOMAIN ||= $LJ::DOMAIN;
    $LJ::SMS_TITLE  ||= "$LJ::SITENAMESHORT SMS";

    # random user defaults to a week
    $LJ::RANDOM_USER_PERIOD = 7;

    # how far in advance to send out birthday notifications
    $LJ::BIRTHDAY_NOTIFS_ADVANCE ||= 2*24*60*60;

    # "RPC" URI mappings
    # add default URI handler mappings
    my %ajaxmapping = (
                       delcomment     => "delcomment.bml",
                       talkscreen     => "talkscreen.bml",
                       spamcomment    => "spamcomment.bml",
                       talkmulti      => "talkmulti.bml",
                       controlstrip   => "tools/endpoints/controlstrip.bml",
                       ctxpopup       => "tools/endpoints/ctxpopup.bml",
                       changerelation => "tools/endpoints/changerelation.bml",
                       userpicselect  => "tools/endpoints/getuserpics.bml",
                       esn_inbox      => "tools/endpoints/esn_inbox.bml",
                       esn_subs       => "tools/endpoints/esn_subs.bml",
                       trans_save     => "tools/endpoints/trans_save.bml",
                       dirsearch      => "tools/endpoints/directorysearch.bml",
                       poll           => "tools/endpoints/poll.bml",
                       jobstatus      => "tools/endpoints/jobstatus.bml",
                       widget         => "tools/endpoints/widget.bml",
                       multisearch    => "tools/endpoints/multisearch.bml",
                       give_tokens    => "give_tokens.bml",
                       );

    foreach my $src (keys %ajaxmapping) {
        $LJ::AJAX_URI_MAP{$src} ||= $ajaxmapping{$src};
    }
    $LJ::AJAX_URI_MAP{load_state_codes} = 'tools/endpoints/load_state_codes.bml';
    $LJ::AJAX_URI_MAP{profileexpandcollapse} = 'tools/endpoints/profileexpandcollapse.bml';
    $LJ::AJAX_URI_MAP{dismisspagenotice} = 'tools/endpoints/dismisspagenotice.bml';

    # List all countries that have states listed in 'codes' table in DB
    # These countries will be displayed with drop-down menu on Profile edit page
    # 'type' is used as 'type' attribute value in 'codes' table
    # 'save_region_code' specifies what to save in 'state' userprop  -
    # '1' mean save short region code and '0' - save full region name
    %LJ::COUNTRIES_WITH_REGIONS = (
        'US' => { type => 'state', save_region_code => 1, },
        'RU' => { type => 'stateru', save_region_code => 1, },
        #'AU' => { type => 'stateau', save_region_code => 0, },
        #'CA' => { type => 'stateca', save_region_code => 0, },
        #'DE' => { type => 'statede', save_region_code => 0, },
    );

    %LJ::VALID_PAGE_NOTICES = (
        profile_design => 1,
        settings_design => 1,
    );

    @LJ::IDENTITY_TYPES = qw( openid ) unless @LJ::IDENTITY_TYPES;

    unless (@LJ::TALK_METHODS_ORDER) {
        @LJ::TALK_METHODS_ORDER = qw(
            Anonymous
            OpenID
            User
        );
    }

    if ($LJ::IS_DEV_SERVER) {
        $LJ::CAPTCHA_MOGILEFS   = 1 unless defined $LJ::CAPTCHA_MOGILEFS;
        $LJ::USERPIC_MOGILEFS   = 1 unless defined $LJ::USERPIC_MOGILEFS;
        $LJ::PHONEPOST_MOGILEFS = 1 unless defined $LJ::PHONEPOST_MOGILEFS;
        $LJ::TRUST_X_HEADERS    = 1 unless defined $LJ::TRUST_X_HEADERS;
        $LJ::NO_PASSWORD_CHECK  = 1 unless defined $LJ::NO_PASSWORD_CHECK;

        unless (@LJ::CLUSTERS) {
            @LJ::CLUSTERS = ( 1, 2 );
        }

        unless ( defined $LJ::DEFAULT_CLUSTER ) {
            $LJ::DEFAULT_CLUSTER = [ 1, 2 ];
        }

        unless (%LJ::DBINFO) {
            %LJ::DBINFO = (
                'master' => {
                    'host'   => 'localhost',
                    'user'   => 'lj',
                    'pass'   => 'ljpass',
                    'dbname' => 'livejournal',
                    'role'   => { 'master' => 1, 'slow' => 1 }
                },

                'c1' => {
                    'host'   => 'localhost',
                    'user'   => 'lj',
                    'pass'   => 'ljpass',
                    'dbname' => 'lj_c1',
                    'role'   => { 'cluster1' => 1 },
                },

                'c2' => {
                    'host'   => 'localhost',
                    'user'   => 'lj',
                    'pass'   => 'ljpass',
                    'dbname' => 'lj_c2',
                    'role'   => { 'cluster2' => 1 },
                },
            );
        }

        # theschwartz config for dev servers
        # for production config, see cvs/ljconfs/site/etc/ljconfig.pl
        my $mast   = $LJ::DBINFO{'master'};
        my $dbname = $mast->{'dbname'} || 'livejournal';
        my $dbhost = $mast->{'host'} || 'localhost';
        unless (%LJ::THESCHWARTZ_DBS) {
            %LJ::THESCHWARTZ_DBS = (
                'dev' => {
                    'dsn'    => "dbi:mysql:$dbname;host=$dbhost",
                    'user'   => $mast->{'user'},
                    'pass'   => $mast->{'pass'},
                    'prefix' => 'sch_',
                },
            );
        }
        unless (%LJ::THESCHWARTZ_DBS_ROLES) {
            %LJ::THESCHWARTZ_DBS_ROLES = (
                'default'   => [ 'dev' ],
                'worker'    => [ 'dev' ],
                'mass'      => [ 'dev' ],
            );
        }

        unless (%LJ::MOGILEFS_CONFIG) {
            %LJ::MOGILEFS_CONFIG = (
                domain => 'danga.com::lj',
                hosts  => [ '127.0.0.1:7001' ],
                classes => {
                    'userpics'   => 3,
                    'captcha'    => 2,
                    'phoneposts' => 3,
                    'file'       => 1,
                    'photo'      => 2,
                    'temp'       => 1,
                },
            );
        }

        @LJ::MEMCACHE_SERVERS = qw( 127.0.0.1:11211 )
            unless @LJ::MEMCACHE_SERVERS;

        @LJ::GEARMAN_SERVERS = qw( 127.0.0.1:8000 )
            unless @LJ::GEARMAN_SERVERS;
    }

    # cluster 0 is no longer supported
    $LJ::DEFAULT_CLUSTER ||= 1;
    @LJ::CLUSTERS = (1) unless @LJ::CLUSTERS;
}

# no dependencies.
# <LJDEP>
# </LJDEP>

return 1;
