# class for passing around LiveJournal errors/warnings, both user-caused
# and system-caused

package LJ::Error;
use strict;
use Carp qw(croak);

# helper function, aliased from LJ::errobj, but here so croak bypasses
# it, since it has to be in the same package or in an @ISA package
# from the caller
#
# Two ways to call:
#
# As a shortcut for constructing a new error object:
#   - LJ::errobj("Userpic::TooManyWords", %opts)
#   - LJ::errobj("BogusParams");
# this is short for LJ::Error::Userpic::TooManyWords->new(%opts)
# but also sets up @ISA on LJ::Error::Userpic::TooManyWords-
#
# As a way to get an LJ::Error instance after an eval
# that died:
#   eval { LJ::scary(); }
#   if (my $err = LJ::errobj()) {  # or you can pass in errobj($@)
#      ....
#   }
#
# returns undef if $@ is undef,
# returns LJ::Error object otherwise.  specific instance is:
#
#      LJ::Error::DieString   -- for deaths with die "Error message!";
#          $ljerr->die_string -- to get the string
#      LJ::Error::DieObject   -- for deaths w/ Exception.pm/etc
#          $ljerr->die_object -- to get the object
#      LJ::Error::*           -- if $@ isa LJ::Error, returns $@ unmodified
#      LJ::Error::Database::Failure -- if given a $dbh/$u after a failure,
#                                      will get the errstr/errmsg
#
sub errobj {
    # constructing a new LJ::Error instance.  either with a classname
    # and args, or just a classname (no whitespace, must have one capital letter)
    if (@_ > 0 && (@_ > 1 || ($_[0] !~ /\s/ && $_[0] =~ /[A-Z]/ && $_[0] !~ /[^:\w]/))) {
        my ($classtail, @ctor_args) = @_;
        my $class = "LJ::Error::$classtail";
        my $makeit = sub { $class->new(@ctor_args); };
        my $val = eval { $makeit->(); };
        if ($@ =~ /^Can\'t locate object method "new" via package "(LJ::Error::\S+?)"/) {
            my $class = $1;
            my $code = "\@${class}::ISA = ('LJ::Error'); 1;";
            eval $code or die "Failed to set ISA: [$@] for code: [$code]\n";
        }
        return $val || $makeit->();
    }

    # if no parameters, act like errobj($@)
    $_[0] = $@ unless @_;

    my $ref = ref $_[0];

    # wrapping a database (or database-like) handle
    if (LJ::isdb($_[0]) || $ref eq "LJ::User") {
        return errobj("Database::Failure", db => $_[0]);
    }

    # wrapping return of an error object
    return errobj("DieString", message => $_[0]) unless $ref;

    # wrapping an LJ::Error object, returning it unchanged
    return $_[0] if $ref =~ /^LJ::Error/;  # should use ->isa, but then have to catch it on HASH, etc

    # else it's a reference, but not one of ours, so we wrap it
    return errobj("DieObject", object => $_[0]);
}

# don't override this!
sub new {
    my $class = shift;
    my %opts  = @_;

    my ($line, $file);
    my $self = {
        _line => $line,
        _file => $file,
    };

    foreach my $f ($class->fields) {
        croak("Missing field in $class ctor: '$f'")
            unless exists $opts{$f};
        $self->{$f} = delete $opts{$f};
    }
    foreach my $f ($class->opt_fields) {
        $self->{$f} = delete $opts{$f};
    }

    if (%opts) {
        croak("Unknown fields in $class ctor: " . join(", ", keys %opts));
    }

    return bless $self, $class;
}

# don't override.
sub field {
    my ($self, $field) = @_;
    croak("Invalid field for object " . ref $self) unless
        exists $self->{$field};
    return $self->{$field};
}

# don't override.  also aliased from LJ::throw(@throw).  or an instance method.
sub throw {
    return unless @_;

    if (@_ == 1) {
        my $self = shift;
        LJ::Error->log_error($self) if $LJ::LOG_ERRORS;
        die $self;
    }

    # throw multiple errors as one
    my @errors = @_;
    LJ::errobj("Multiple", errors => \@errors)->throw;
}

# throws self, if $LJ::THROW_ERRORS is dynamically set w/ local,
# else returns undef (by default), or the value passed to it
sub cond_throw {
    my $self = shift;
    my $ret_value = shift;
    $self->throw if $LJ::THROW_ERRORS;
    return defined $ret_value ? $ret_value : undef;
}

# log error to database
# don't override
sub log_error {
    my ($class, $err) = @_;

    my $dbl = LJ::get_dbh("logs") or return;

    my $now = time;
    my @now = localtime($now);

    my $table_name = sprintf("errors%04d%02d%02d%02d", $now[5]+1900,
                             $now[4]+1, $now[3], $now[2]);

    my $create_sql = qq {
        (
         whn INT (10) UNSIGNED NOT NULL,
         INDEX(whn),
         description VARCHAR(255),
         errclass VARCHAR(255),
         usercaused TINYINT,
         server VARCHAR(30),
         addr VARCHAR(15) NOT NULL,
         ljuser VARCHAR(15),
         remotecaps INT UNSIGNED,
         journalid INT UNSIGNED, # userid of what's being looked at
         journaltype CHAR(1),   # journalid's journaltype
         remoteid INT UNSIGNED, # remote user's userid
         codepath VARCHAR(80),  # protocol.getevents / s[12].friends / bml.update / bml.friends.index
         anonsess INT UNSIGNED,
         langpref VARCHAR(5),
         uniq VARCHAR(15),
         method VARCHAR(10) NOT NULL,
         uri VARCHAR(255) NOT NULL,
         args VARCHAR(255),
         status SMALLINT UNSIGNED NOT NULL,
         ctype VARCHAR(30),
         bytes MEDIUMINT UNSIGNED NOT NULL,
         browser VARCHAR(100),
         clientver VARCHAR(100),
         secs TINYINT UNSIGNED
         );
    };

    $dbl->do("CREATE TABLE IF NOT EXISTS $table_name $create_sql") or return;

    my $whn = time();

    my %insert = (
                  'whn'         => $whn,
                  'description' => $err->as_string || $err->as_html,
                  'errclass'    => ref $err,
                  'server'      => $LJ::SERVER_NAME,
                  'usercaused'  => $err->user_caused, # 0, 1 or NULL
                  );

    if (my $r = eval {Apache->request}) {
        my $rl = $r->last;

        my $remote = eval { LJ::load_user($rl->notes('ljuser')) };
        my $remotecaps = $remote ? $remote->{caps} : undef;
        my $remoteid   = $remote ? $remote->{userid} : 0;
        my $ju = eval { LJ::load_userid($rl->notes('journalid')) };
        my $uri = $r->uri;

        my %insert_r = (
                        'addr'        => $r->connection->remote_ip,
                        'remote'      => $rl->notes('ljuser'),
                        'remotecaps'  => $remotecaps,
                        'remoteid'    => $remoteid,
                        'journalid'   => $rl->notes('journalid'),
                        'journaltype' => $ju ? $ju->{journaltype} : "",
                        'codepath'    => $rl->notes('codepath'),
                        'langpref'    => $rl->notes('langpref'),
                        'clientver'   => $rl->notes('clientver'),
                        'method'      => $r->method,
                        'uri'         => $uri,
                        'args'        => scalar $r->args,
                        'browser'     => $r->header_in("User-Agent"),
                        'ref'         => $r->header_in("Referer"),
                        );

        while ( my ($k,$v) = each %insert_r ) {
            $insert{$k} = $v;
        }
    };

    my $delayed = $LJ::IMMEDIATE_LOGGING ? "" : "DELAYED";

    my $ins = sub {
        my $insert_sql = "INSERT $delayed INTO $table_name (" . join(", ", keys %insert) . ") VALUES (" .
            join(",", map { "?" } values %insert) . ")";

        $dbl->do($insert_sql, undef, values %insert);
    };

    # insert time!

    # support for widening the schema at runtime.  if we detect a bogus column,
    # we just don't log that column until the next (wider) table is made at next
    # hour boundary.
    $ins->();
    while ($dbl->err && $dbl->errstr =~ /Unknown column \'(\w+)/) {
        my $col = $1;
        delete $insert{$col};
        $ins->();
    }

    $dbl->disconnect if $LJ::DISCONNECT_DB_LOG;
}

# override this: whether it was user-defined.  should return 0 or 1.
sub user_caused { undef }

# override this: return list of required fields
sub fields { (); }

# override this: return list of optional fields
sub opt_fields { (); }

# you may override this
sub as_html {
    my $self = shift;
    return LJ::ehtml($self->as_string);
}

sub as_bullets {
    my $self = shift;
    return "<li>" . $self->as_html . "</li>\n";
}

# override this
sub as_string {
    my $self = shift;

    # FIXME: show line/file/function, show some fields?  maybe?  that are simple values?
}

# automatic type returned when something dies with just a string
package LJ::Error::DieString;
sub fields { qw(message) }
sub die_string { return $_[0]->field('message'); }

# automatic type returned when something dies with a reference, but not
# an LJ::Error
package LJ::Error::DieObject;
sub fields { qw(object) }
sub die_object { return $_[0]->field('object'); }

package LJ::Error::Multiple;
sub fields { qw(errors); }  # arrayref of errors

sub as_bullets {
    my $self = shift;
    return join('', map { $_->as_bullets } @{ $self->{errors} });
}

package LJ::Error::WithSubError;
sub fields { qw(main suberr); }

sub as_bullets {
    my $self = shift;
    return $self->{main}->as_bullets . "<ul>" . $self->{suberr}->as_bullets . "</ul>";
}

sub as_string {
    my $self = shift;
    return $self->{main}->as_string . ", due to: " . $self->{suberr}->as_string;
}


1;
