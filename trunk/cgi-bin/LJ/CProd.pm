
package LJ::CProd;
# Mostly abstract base class for LiveJournal's contextual product/prodding.
# Let users know about new/old features they can use but never have.
use strict;
use List::Util qw (shuffle);

#################### Override:

# optionally override this:
sub applicable {
    my ($class, $u) = @_;
    # given a user object, is it applicable to advertise
    # this product ($class) to the user?
    return 1;
}

# override this:
sub render {
    my ($class, $u, $version) = @_;
    # given a user, return HTML to promote the product ($class)
    return "Hey $u->{user}, did you know about $class?";
}

# override these:
sub ml { '' }
sub link { '' }
sub button_text { 'Cool!' }


#################### Don't override.

our $typemap;
# get the typemap for the subscriptions classes (class/instance method)
sub typemap {
    return $typemap ||= LJ::Typemap->new(
        table       => 'cprodlist',
        classfield  => 'class',
        idfield     => 'cprodid',
    );
}

# returns the typeid for this module.
sub cprodid {
    my ($class_self) = @_;
    my $class = ref $class_self ? ref $class_self : $class_self;

    my $tm = $class->typemap
        or return undef;

    return $tm->class_to_typeid($class);
}

# don't override:
sub shortname {
    my $class = shift;
    $class =~ s/^LJ::CProd:://;
    return $class;
}

# returns boolean; if user has dismissed the $class tip
sub has_dismissed {
    my ($class, $u) = @_;
    # TODO: implement
    return 0;
}

sub mark_dontshow {
    shift @_ unless ref $_[0];
    my ($u, $noclass) = @_;
    return 0 unless $u;
    my $tm  = LJ::CProd->typemap;
    my $hide_cprodid = $tm->class_to_typeid($noclass)
        or return 0;
    $u->do("INSERT IGNORE INTO cprod SET userid=?, cprodid=?",
           undef, $u->{userid}, $hide_cprodid);
    return $u->do("UPDATE cprod SET acktime=UNIX_TIMESTAMP(), nothankstime=UNIX_TIMESTAMP() WHERE userid=? AND cprodid=?",
                  undef, $u->{userid}, $hide_cprodid);
}

sub mark_acked {
    shift @_ unless ref $_[0];
    my ($u, $class) = @_;
    return 0 unless $u;
    my $tm  = LJ::CProd->typemap;
    my $hide_cprodid = $tm->class_to_typeid($class)
        or return 0;
    $u->do("INSERT IGNORE INTO cprod SET userid=?, cprodid=?",
           undef, $u->{userid}, $hide_cprodid);
    return $u->do("UPDATE cprod SET acktime=UNIX_TIMESTAMP() WHERE userid=? AND cprodid=?",
                  undef, $u->{userid}, $hide_cprodid);
}

sub _trackable_link {
    my ($class, $text, $goodclick, $version, %opts) = @_;
    Carp::croak("bogus caller, forgot param") unless defined $goodclick;
    my $link = $class->_trackable_link_url($class->link, $goodclick, $version);
    my $e_text;
    if ($opts{'style'}) {
        $e_text = "<span $opts{'style'}>" . LJ::ehtml($text) . "</span>";
    } else {
        $e_text = LJ::ehtml($text);
    }
    my $classlink = $class->link;
    return qq {
        <a onclick="window.location.href='$link'; return false;" href="$classlink">$e_text</a>
        };
}

sub _trackable_button {
    my ($class, $text, $goodclick, $version) = @_;
    Carp::croak("bogus caller, forgot param") unless defined $goodclick;
    my $link = $class->_trackable_link_url($class->link, $goodclick, $version);
    my $e_text = LJ::ehtml($text);
    return qq {
        <input type="button" value="$e_text" onclick="window.location.href='$link';" />
        };
}

sub _trackable_link_url {
    my ($class, $href, $goodclick, $version) = @_;
    $version ||= 0;
    return "$LJ::SITEROOT/misc/cprod.bml?class=$class&g=$goodclick&version=$version&to=" . LJ::eurl($href);
}

sub clickthru_button {
    my ($class, $text, $version) = @_;
    return $class->_trackable_button($text, 1, $version);
}

sub next_button {
    my ($class, $style) = @_;
    my $text = "Next";
    my $btn = qq {
        <input type="button" value="$text" id="CProd_nextbutton" />
        };

    $btn .= qq {
        <div id="CProd_style" style="display: none;">$style</div>
        };
}

sub clickthru_link {
    my ($class, $ml_key, $version, %opts) = @_;
    my $versioned_link_text = BML::ml($ml_key . ".v$version");
    my $text = $versioned_link_text || BML::ml($ml_key);
    $class->_trackable_link($text, 1, $version, %opts);
}

sub ack_link {
    my ($class, $text) = @_;
    $class->_trackable_link($text, 0);
}

# don't override
sub full_box_for {
    my ($class, $u, %opts) = @_;
    my $showclass = LJ::CProd->prod_to_show($u)
        or return "";
    my $version = $showclass->get_version;
    my $content = eval { $showclass->render($u, $version) } || LJ::ehtml($@);
    return $showclass->wrap_content($content, %opts, version => $version);
}

# don't override
sub box_for {
    my ($class, $u) = @_;
    my $showclass = LJ::CProd->prod_to_show($u)
        or return "";
    my $version = $showclass->get_version;
    my $content = eval { $showclass->render($u, $version) } || LJ::ehtml($@);
    return $content;
}

sub inline {
    my ($class, $u, %opts) = @_;
    my $tm  = $class->typemap;
    my $map = LJ::CProd->user_map($u);

    $class = "LJ::CProd::$opts{'inline'}";
    my $cprodid = $tm->class_to_typeid($class);
    my $state = $map->{$cprodid};

    eval "use $class; 1";
    return "" if $@;
    return "" unless eval { $class->applicable($u) };
    my $version = $class->get_version($u);
    my $content = eval { $class->render($u, $version) } || LJ::ehtml($@);
    return $content;
}

# get the translation string for this version of the module
# returns ml key
sub get_ml {
    my ($class, $version, $u) = @_;
    $version ||= 1;
    return $class->ml($u) . ".v$version";
}

# pick a random version of this module with a translation string
# returns version number (0 if no valid version translation strings)
sub get_version {
    my ($class,$u) = @_;

    my @versions = shuffle 1..20;

    foreach my $version (@versions) {
        my $ml_key = $class->get_ml($version,$u);
        my $ml_str = BML::ml($ml_key);
        return $version if ($ml_str && $ml_str ne '' && $ml_str !~ /^_skip/i);
    }

    return 0;
}

sub user_map {
    my ($class, $u) = @_;
    my $map = $u ? $u->selectall_hashref("SELECT cprodid, firstshowtime, recentshowtime, ".
                                         "       acktime, nothankstime, clickthrutime ".
                                         "FROM cprod WHERE userid=?",
                                         "cprodid", undef, $u->{userid}) : {};
    $map ||= {};
    return $map;
}

sub prod_to_show {
    my ($class, $u) = @_;

    my $tm  = $class->typemap;
    my $map = LJ::CProd->user_map($u);

    my @poss;  # [$class, $cprodid, $acktime];

    foreach my $prod (@LJ::CPROD_PROMOS) {
        my $class = "LJ::CProd::$prod";
        my $cprodid = $tm->class_to_typeid($class);
        my $state = $map->{$cprodid};

        # skip if they don't want it.
        next if $state && $state->{nothankstime};

        push @poss, [$class, $cprodid, $state, $state ? $state->{acktime} : 0 ];
    }

    return unless @poss;

    foreach my $poss (sort { $a->[3] <=> $b->[3] } @poss) {
        my ($class, $cprodid, $state) = @$poss;
        eval "use $class; 1";
        next if $@;
        next unless eval { $class->applicable($u) };

        if ($u && ! $state) {
            $u->do("INSERT IGNORE INTO cprod SET userid=?, cprodid=?, firstshowtime=?",
                   undef, $u->{userid}, $cprodid, time());
        }

        return $class;
    }
    return;
}

sub wrap_content {
    my ($class, $content, %opts) = @_;

    # include js libraries
    LJ::need_res("js/core.js");
    LJ::need_res("js/dom.js");
    LJ::need_res("js/httpreq.js");
    LJ::need_res("js/hourglass.js");
    LJ::need_res("js/cprod.js");
    LJ::need_res("stc/cprod.css");
    my $e_class = LJ::ehtml($class);

    my $w = delete $opts{'width'} || 300;
    my $version = delete $opts{version} || 0;
    my $style = delete $opts{style} || 'fancy';

    my $alllink = $class->_trackable_link_url("$LJ::SITEROOT/didyouknow/", 0);
    my $next_button = $class->next_button($style);
    my $clickthru_button = $class->clickthru_button($class->button_text, $version);

    if ($style eq 'fancy') {
        return qq{
            <div id='CProd_box'>
                <div style='width: ${w}px;' class='CProd_box_content'>
                    <div class='content'>$content</div>
                    <div class='fancy' style='background: #d9e6f2 url($LJ::IMGPREFIX/cprod_b.gif) bottom left repeat-x;'>
                        <div class='fancy-right' style='background: url($LJ::IMGPREFIX/cprod_bright.gif) no-repeat bottom right;'>
                            <div class='fancy-left' style='background: url($LJ::IMGPREFIX/cprod_bleft.gif) no-repeat bottom left;'>
                                <div class='actions'>$clickthru_button $next_button</div>
                                <img src='$LJ::IMGPREFIX/frankhead.gif' width='50' height='50' class='frankhead' />
                                <div class='clear'></div>
                            </div>
                        </div>
                    </div>

                    <div class='alllink'>
                        <a onclick="window.location.href='$alllink'; return false;" href="$LJ::SITEROOT/didyouknow/">What else has LJ been hiding from me?</a>
                    </div>
                    <div style='display: none;' id='CProd_class'>$e_class</div>
                </div>
            </div>
            };
    } else {
        return qq {
            <div id="CProd_box">
                <div class='content-portal'>$content</div>
                    <div class='portal'>
                        <img src='$LJ::IMGPREFIX/frankhead.gif' width='50' height='50' align='absmiddle' class='frankhead-portal'/>
                        <div class='actions-portal'>$clickthru_button $next_button</div>
                        <div class='alllink-portal'><a href="$alllink">What else has LJ been hiding from me?</a></div>
                        <div class='clear'></div>
                    </div>
                    <div style='display: none;' id='CProd_class'>$e_class</div>
            </div>
            };
    }
}

1;
