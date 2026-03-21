use strict;
use warnings;

use Test::More;
use Test::Exception;
use DBIx::Fast;

plan skip_all => "DBIX_FAST_TEST_MARIADB not set"
  unless $ENV{DBIX_FAST_TEST_MARIADB};

eval "use DBD::MariaDB 1.23";
plan skip_all => "DBD::MariaDB 1.23 required" if $@;

my $dsn = $ENV{DBIX_FAST_TEST_MARIADB};

# --- Connection ---

subtest 'Connection' => sub {
    my $db;

    lives_ok { $db = DBIx::Fast->new( dsn => $dsn ) } 'Connect via DSN';
    isa_ok( $db, 'DBIx::Fast' );
    is( $db->dbd, 'MariaDB', 'Driver is MariaDB' );
    ok( $db->dsn, 'DSN is set' );
    ok( $db->db,  'Connector is set' );
};

# --- Setup ---

my $db = DBIx::Fast->new( dsn => $dsn );

lives_ok {
    $db->exec('DROP TABLE IF EXISTS dbix_fast_test');
} 'Drop test table if exists';

lives_ok {
    $db->exec(q{
        CREATE TABLE dbix_fast_test (
            id    INT AUTO_INCREMENT PRIMARY KEY,
            name  VARCHAR(255) NOT NULL,
            value INT DEFAULT 0,
            created_at DATETIME
        ) ENGINE=InnoDB
    });
} 'Create test table';

# --- Insert ---

subtest 'Insert' => sub {
    lives_ok {
        $db->insert('dbix_fast_test', { name => 'Alice', value => 100 });
    } 'Insert Alice';

    ok( $db->last_id, 'last_id is set after insert' );
    my $alice_id = $db->last_id;

    lives_ok {
        $db->insert('dbix_fast_test', { name => 'Bob', value => 200 });
    } 'Insert Bob';

    ok( $db->last_id > $alice_id, 'last_id incremented' );

    lives_ok {
        $db->insert('dbix_fast_test',
            { name => 'Charlie', value => 300 },
            time => 'created_at'
        );
    } 'Insert with time column';
};

# --- Select ---

subtest 'Select - hash' => sub {
    $db->hash('SELECT * FROM dbix_fast_test WHERE name = ?', 'Alice');
    my $row = $db->results;

    ok( $row, 'hash() returns result' );
    is( $row->{name},  'Alice', 'name matches' );
    is( $row->{value}, 100,     'value matches' );
};

subtest 'Select - val' => sub {
    my $val = $db->val('SELECT value FROM dbix_fast_test WHERE name = ?', 'Bob');
    is( $val, 200, 'val() returns single value' );
};

subtest 'Select - all' => sub {
    $db->all('SELECT * FROM dbix_fast_test ORDER BY id');
    my $rows = $db->results;

    ok( $rows, 'all() returns results' );
    is( ref $rows, 'ARRAY', 'results is arrayref' );
    is( scalar @$rows, 3, 'Got 3 rows' );
    is( $rows->[0]->{name}, 'Alice', 'First row is Alice' );
};

subtest 'Select - flat' => sub {
    my @names = $db->flat('SELECT name FROM dbix_fast_test ORDER BY id');
    is( scalar @names, 3, 'flat() returns 3 values' );
    is( $names[0], 'Alice', 'First name is Alice' );
};

subtest 'Select - array' => sub {
    $db->array('SELECT name FROM dbix_fast_test ORDER BY id');
    my $arr = $db->results;
    is( ref $arr, 'ARRAY', 'array() returns arrayref' );
    is( $arr->[1], 'Bob', 'Second element is Bob' );
};

subtest 'Select - count' => sub {
    my $total = $db->count('dbix_fast_test');
    is( $total, 3, 'count() returns 3' );

    my $filtered = $db->count('dbix_fast_test', { value => { '>=' => 200 } });
    is( $filtered, 2, 'count() with WHERE returns 2' );
};

# --- Update ---

subtest 'Update' => sub {
    lives_ok {
        $db->up('dbix_fast_test', { value => 150 }, { name => 'Alice' });
    } 'up() Alice value';

    my $val = $db->val('SELECT value FROM dbix_fast_test WHERE name = ?', 'Alice');
    is( $val, 150, 'Alice value updated to 150' );

    lives_ok {
        $db->update('dbix_fast_test', {
            sen   => { value => 999 },
            where => { name  => 'Bob' },
        });
    } 'update() Bob value';

    $val = $db->val('SELECT value FROM dbix_fast_test WHERE name = ?', 'Bob');
    is( $val, 999, 'Bob value updated to 999' );
};

# --- Delete ---

subtest 'Delete' => sub {
    my $before = $db->count('dbix_fast_test');

    lives_ok {
        $db->delete('dbix_fast_test', { name => 'Charlie' });
    } 'delete() Charlie';

    my $after = $db->count('dbix_fast_test');
    is( $after, $before - 1, 'Row count decreased by 1' );
};

# --- Transactions ---

subtest 'Transaction - commit' => sub {
    lives_ok {
        $db->txn(sub {
            $db->insert('dbix_fast_test', { name => 'TxnUser', value => 500 });
        });
    } 'Transaction committed';

    my $val = $db->val('SELECT value FROM dbix_fast_test WHERE name = ?', 'TxnUser');
    is( $val, 500, 'TxnUser persisted after commit' );
};

subtest 'Transaction - rollback' => sub {
    eval {
        $db->txn(sub {
            $db->insert('dbix_fast_test', { name => 'RollbackUser', value => 600 });
            die "force rollback";
        });
    };
    like( $@, qr/force rollback/, 'Transaction died' );

    my $val = $db->val('SELECT COUNT(*) FROM dbix_fast_test WHERE name = ?', 'RollbackUser');
    is( $val, 0, 'RollbackUser not persisted after rollback' );
};

subtest 'Transaction - savepoint' => sub {
    lives_ok {
        $db->transaction->do(sub {
            $db->insert('dbix_fast_test', { name => 'SP_before', value => 700 });
            $db->transaction->savepoint('sp1');

            eval {
                $db->insert('dbix_fast_test', { name => 'SP_after', value => 800 });
                die "rollback to savepoint";
            };

            if ($@) {
                $db->transaction->rollback_to('sp1');
                $db->insert('dbix_fast_test', { name => 'SP_recovered', value => 900 });
            }
        });
    } 'Transaction with savepoint completed';

    is( $db->val('SELECT COUNT(*) FROM dbix_fast_test WHERE name = ?', 'SP_before'),    1, 'SP_before persisted' );
    is( $db->val('SELECT COUNT(*) FROM dbix_fast_test WHERE name = ?', 'SP_after'),     0, 'SP_after rolled back' );
    is( $db->val('SELECT COUNT(*) FROM dbix_fast_test WHERE name = ?', 'SP_recovered'), 1, 'SP_recovered persisted' );
};

subtest 'Transaction - stats' => sub {
    my $stats = $db->transaction->get_stats();
    ok( $stats, 'Got transaction stats' );
    ok( $stats->{total_count} > 0,   'total_count > 0' );
    ok( $stats->{success_count} > 0, 'success_count > 0' );
};

# --- Schema ---

subtest 'Schema - tables' => sub {
    my $schema = $db->schema;
    isa_ok( $schema, 'DBIx::Fast::Schema' );

    $schema->_load_tables_name();
    my $tables = $schema->tables;

    ok( $tables, 'Got table list' );
    ok( exists $tables->{dbix_fast_test}, 'dbix_fast_test found in tables' );
};

subtest 'Schema - table_info' => sub {
    my $info = $db->schema->table_info('dbix_fast_test');
    ok( $info, 'Got table info' );
    ok( scalar @$info > 0, 'Has column info' );
};

subtest 'Schema - indexes' => sub {
    lives_ok {
        $db->exec('CREATE INDEX idx_name ON dbix_fast_test (name)');
    } 'Create index';

    my $indexes = $db->schema->get_indexes('dbix_fast_test');
    ok( $indexes, 'Got indexes' );
    ok( scalar @$indexes > 0, 'Has at least one index' );
};

subtest 'Schema - primary_keys' => sub {
    my $keys = $db->schema->primary_keys('dbix_fast_test');
    ok( $keys, 'Got primary keys' );
    is( $keys->[0], 'id', 'Primary key is id' );
};

subtest 'Schema - table_size' => sub {
    my $size = $db->schema->table_size('dbix_fast_test');
    ok( $size, 'Got table size' );
    ok( defined $size->{rows}, 'Has row count' );
};

# --- Named parameters ---

subtest 'Named parameters' => sub {
    $db->execute(
        'SELECT * FROM dbix_fast_test WHERE name = :name AND value >= :min_val',
        { name => 'Alice', min_val => 100 }
    );
    my $rows = $db->results;
    ok( $rows, 'Named parameter query returned results' );
};

# --- exec ---

subtest 'exec' => sub {
    my $sth = $db->exec('SELECT COUNT(*) as cnt FROM dbix_fast_test');
    ok( $sth, 'exec() returns statement handle' );

    my $row = $sth->fetchrow_hashref;
    ok( $row->{cnt} > 0, 'exec() query works' );
};

# --- Error handling ---

subtest 'Errors' => sub {
    my $db_err = DBIx::Fast->new( dsn => $dsn, RaiseError => 0, PrintError => 0 );

    $db_err->set_error( 42, 'Test error' );
    ok( $db_err->last_error, 'last_error is set' );
    ok( scalar @{ $db_err->errors } > 0, 'errors array has entries' );
};

# --- now() ---

subtest 'Timestamp' => sub {
    my $now = $db->now();
    like( $now, qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/, 'now() returns MySQL format timestamp' );
};

# --- Cleanup ---

lives_ok {
    $db->exec('DROP TABLE IF EXISTS dbix_fast_test');
} 'Cleanup: drop test table';

done_testing();
