#!perl -T
use strict;
use warnings FATAL => 'all';

use Test::More 0.98;
use Test::Exception;
use File::Temp qw(tempdir);
use File::Spec;
use DBIx::Fast;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74 required" if $@;

my ( $fixture_db, $needs_schema ) = ( 't/db/test.db', 0 );
my ( $db, $db_path, $dsn );

if ( -e $fixture_db ) {
    $db_path = $fixture_db;
    $dsn     = "dbi:SQLite:dbname=$db_path";
}
else {
    my $tmpdir = tempdir( CLEANUP => 1 );
    $db_path      = File::Spec->catfile( $tmpdir, 'test.sqlite' );
    $dsn          = "dbi:SQLite:dbname=$db_path";
    $needs_schema = 1;
}

sub new_db {
    return DBIx::Fast->new(
        dsn        => $dsn,
        driver     => 'SQLite',
        PrintError => 1,
        tn         => 0
    );
}

subtest 'constructor' => sub {
    $db = new_db();

    isa_ok( $db, 'DBIx::Fast' );
    ok( $db->db, 'has db handle' );
    is( $db->dbd, 'SQLite', 'driver detected as SQLite' ) if $db->dbd;

    done_testing;
};

subtest 'schema setup (if needed)' => sub {
    if ($needs_schema) {
        lives_ok {
            $db->execute_prepare(
                q{
                CREATE TABLE test (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    name       TEXT NOT NULL,
                    status     INTEGER,
                    time       TEXT
                )
            }
            );
        }
        'created table test';
    }
    else {
        pass('re-using existing fixture DB');
    }

    done_testing;
};

subtest 'capabilities' => sub {
    can_ok( $db, qw(insert update up delete q val all hash array count) );

    done_testing;
};

subtest 'cleanup & error capture' => sub {
    lives_ok { $db->delete( 'test', { id => { '>' => 0 } } ) }
    'wipe table test';

    for (qw(be eb)) {
        local $SIG{__DIE__} = sub {
            like(
                $_[0],
                qr/no such table|Exception/i,
                "Exception => No such table ($_)"
            );
        };
        eval { $db->execute("SELECT * FROM $_") };
    }

    is ref $db->errors, 'ARRAY', 'errors array present';
    cmp_ok scalar( @{ $db->errors } ), '>=', 2, 'errors captured (>=2)';

    done_testing;
};

subtest 'empty counts' => sub {
    is $db->val('select count(*) from test'), 0, 'empty via val()';
    is $db->count('test'),                    0, 'count() empty';
    is $db->count( 'test', { id => { '>' => 999 } } ), 0,
      'count() with WHERE empty';

    done_testing;
};

subtest 'insert + last_id' => sub {
    ok $db->insert( 'test', { name => 'test', status => 1 }, time => 'time' ),
      'insert returns truthy';
    cmp_ok $db->last_id, '>=', 1, 'last insert id set';

    done_testing;
};

subtest 'update (WHERE con 1 y 2 claves)' => sub {
    $db->update(
        'test',
        { sen => { name => 'update t3st' }, where => { id => 1 } },
        time => 'time'
    );

    my $v = $db->val('select name from test where id = 1');
    like $v, qr/update t3st/, 'update with 1 where key';

    $db->update(
        'test',
        {
            sen   => { name => 'Mator Change' },
            where => { id   => 1, name => 'update t3st' }
        },
        time => 'time'
    );
    $v = $db->val('select name from test where id = 1');
    like $v, qr/Mator Change/, 'update with 2 where keys';

    done_testing;
};

subtest 'update (evitar claves duplicadas) + up()' => sub {
    $db->update(
        'test',
        {
            sen   => { name => 'Maxim SQL' },
            where => { id   => 1, name => 'Mator Change' }
        },
        time => 'time'
    );

    my $v = $db->val('select name from test where id = 1');
    like $v, qr/Maxim SQL/, 'update stable';

    $db->up( 'test', { name => 'update test' }, { id => 1 }, 'time' );

    $v = $db->val( 'select name from test where id = ?', 1 );
    like $v, qr/update test/, 'up() updated row';

    done_testing;
};

subtest 'bulk inserts + flat/array/results' => sub {
    $db->insert( 'test', { name => rand(6) }, time => 'time' ) for 1 .. 5;

    my @flat = $db->flat('SELECT name FROM test WHERE 1');

    is ref \@flat, 'ARRAY', 'flat() returns list';
    cmp_ok scalar(@flat), '>=', 6, 'flat() >= 6 rows';

    $db->flat('SELECT name FROM test WHERE 1');
    is ref $db->results, 'ARRAY', 'results after flat() is arrayref';

    $db->array('SELECT * FROM test WHERE 1');
    is ref $db->results, 'ARRAY', 'results after array() is arrayref';

    $db->hash( 'SELECT * FROM test WHERE id = ? ', 1 );

    is ref $db->results, 'HASH', 'results after hash() is hashref';
    like $db->results->{time}, qr/^\d{4}-\d{2}-\d{2} /,
      'time is timestamp (NOW)';

    $db->all('select * from test');
    is ref $db->results, 'ARRAY', 'results after all() is arrayref';

    done_testing;
};

subtest 'delete variants + last_sql' => sub {
    ok $db->delete( 'test', { id => { '=' => $db->last_id } } ),
      'delete last_id';
    is $db->sql, 'DELETE FROM test WHERE id = ?', 'Delete SQL (=)';

    $db->delete( 'test', { id => { '>' => 999 } } );
    is $db->sql, 'DELETE FROM test WHERE id > ?', 'Delete SQL (>)';

    $db->delete( 'test', { id => 999 } );
    is $db->sql, 'DELETE FROM test WHERE id = ?', 'Delete SQL (= scalar)';

    done_testing;
};

subtest 'delete compound WHERE' => sub {
    # Insert a row to delete with compound WHERE
    $db->insert( 'test', { name => 'compound_del', status => 77 } );
    my $cid = $db->last_id;
    ok $cid, "inserted row for compound delete (id=$cid)";

    # Delete with two WHERE keys
    lives_ok { $db->delete( 'test', { id => $cid, status => 77 } ) }
      'delete with compound WHERE does not die';

    # Verify it was actually deleted
    my $check = $db->val( 'SELECT id FROM test WHERE id = ?', $cid );
    ok !$check, 'row deleted by compound WHERE';

    # Insert again and try with wrong compound (should not delete)
    $db->insert( 'test', { name => 'compound_safe', status => 88 } );
    my $cid2 = $db->last_id;

    $db->delete( 'test', { id => $cid2, status => 99 } );    # wrong status
    my $still = $db->val( 'SELECT id FROM test WHERE id = ?', $cid2 );
    ok $still, 'row NOT deleted when compound WHERE does not match';

    # Cleanup
    $db->delete( 'test', { id => $cid2 } );

    done_testing;
};

subtest 'count compound WHERE' => sub {
    $db->insert( 'test', { name => 'count_a', status => 55 } );
    $db->insert( 'test', { name => 'count_b', status => 55 } );
    $db->insert( 'test', { name => 'count_c', status => 66 } );

    my $total_55 = $db->count( 'test', { status => 55 } );
    cmp_ok $total_55, '>=', 2, 'count with single WHERE key';

    my $exact = $db->count( 'test', { name => 'count_a', status => 55 } );
    is $exact, 1, 'count with compound WHERE returns 1';

    my $zero = $db->count( 'test', { name => 'count_a', status => 66 } );
    is $zero, 0, 'count with mismatched compound WHERE returns 0';

    # Cleanup
    $db->delete( 'test', { name => 'count_a' } );
    $db->delete( 'test', { name => 'count_b' } );
    $db->delete( 'test', { name => 'count_c' } );

    done_testing;
};

subtest '_make_where SQL generation' => sub {
    # Test internal SQL generation directly
    $db->sql('SELECT * FROM test');
    $db->_make_where({ id => 1 });
    like $db->sql, qr/WHERE id = \?/, 'single key WHERE';

    $db->sql('DELETE FROM test');
    $db->_make_where({ id => 1, status => 5 });
    like $db->sql, qr/WHERE .+ AND .+/, 'compound WHERE has AND';
    unlike $db->sql, qr/AND\s*$/, 'no trailing AND';

    # Verify both placeholders present
    my $placeholders = () = $db->sql =~ /\?/g;
    is $placeholders, 2, 'compound WHERE has 2 placeholders';
    is scalar @{$db->p}, 2, 'compound WHERE has 2 bind values';

    done_testing;
};

subtest 'TableName validator' => sub {
    is $db->TableName('TableName'), 'TableName', 'valid table name';

    done_testing;
};

done_testing();
