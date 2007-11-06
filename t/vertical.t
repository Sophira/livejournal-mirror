# -*-perl-*-

use strict;
use Test::More 'no_plan';
use lib "$ENV{LJHOME}/cgi-bin";
require 'ljlib.pl';
use LJ::Vertical;
use LJ::Test qw(memcache_stress temp_user);

my $u = temp_user();

sub run_tests {

    # constructor tests
    {
        my $v;

        $v = eval { LJ::Vertical->new };
        like($@, qr/wrong number of arguments/, "new: no arguments");

        $v = eval { LJ::Vertical->new( undef ) };
        like($@, qr/wrong number of arguments/, "new: wrong number of arguments");

        $v = eval { LJ::Vertical->new( vertid => undef ) };
        like($@, qr/need to supply/, "new: need to supply vertical id");

        $v = eval { LJ::Vertical->new( vertid => 1, foo => 'bar' ) };
        like($@, qr/unknown parameters/, "new: unknown parameters");

        $v = eval { LJ::Vertical->new( vertid => 1 ) };
        isa_ok($v, "LJ::Vertical", "new: successful instantiation");
    }

    # creating a vertical
    {
        my $v;

        my $gen_name = sub { join(":", "t", time(), LJ::rand_chars(20)) };
        my $name = $gen_name->();
        
        $v = eval { LJ::Vertical->create };
        like($@, qr/wrong number of arguments/, "create: no arguments");

        $v = eval { LJ::Vertical->create( undef ) };
        like($@, qr/wrong number of arguments/, "create: wrong number of arguments");

        $v = eval { LJ::Vertical->create( name => undef ) };
        like($@, qr/need to supply/, "create: need to supply vertical name");

        $v = eval { LJ::Vertical->create( name => 'baz', foo => 'bar' ) };
        like($@, qr/unknown parameters/, "create: unknown parameters");

        $v = LJ::Vertical->create( name => $name );
        isa_ok($v, "LJ::Vertical", "create: successful creation");

        # reset singletons then load the one we just created
        {
            my $old_vertid = $v->{vertid};
            LJ::Vertical->reset_singletons();

            $v = LJ::Vertical->new( vertid => $old_vertid );
            ok(ref $v && $v->isa("LJ::Vertical") && $v->{vertid} == $old_vertid, "new: successful load");

            $v->delete_and_purge;
            ok (! LJ::MemCache::get([ $old_vertid, "vert:$old_vertid" ]), "delete: deleted vertical from db and memcache" );

            # create by same name and see if we're able to create and load by different id
            $v = eval { LJ::Vertical->create( name => $name ) };
            isa_ok($v, "LJ::Vertical", "create: new vertical created");
            ok($v->{vertid} != $old_vertid, "create: new vertical has different vertid: $v->{vertid}");

            # try some getters / setters
            ok($v->name eq $name, "name matches creation  name");

            { # test name, set_name
                my $new_name = $gen_name->();
                my $rv = $v->set_name($new_name);
                ok($rv eq $new_name && $v->name eq $new_name, "set new name okay");
            }
            
            { # createtime, set_create_time
                my $old_createtime = $v->createtime;
                ok(time() - $old_createtime < 30, "got original createtime: ");

                my $new_time = time() - 86400;
                $v->set_createtime($new_time);
                ok($v->createtime == $new_time, "new createtime okay");
            }

            # FIXME: more accessors? ... they all use the same code

            # clean up after ourselves
            $v->delete_and_purge;
        }
    }
}

memcache_stress {
    run_tests();
};

1;

