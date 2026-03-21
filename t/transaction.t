#!perl -T
use strict;
use warnings;

use Test::More;
use Test::Exception;
use DBIx::Fast;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74" if $@;

my $db = DBIx::Fast->new( dsn => 'dbi:SQLite:dbname=:memory:', driver => 'SQLite', RaiseError => 1, tn => 0 );

ok($db->transaction,       'Transaction object created');
isa_ok($db->transaction,   'DBIx::Fast::Transaction');

# Helper
can_ok($db,qw(txn));

# Transaction
can_ok($db->transaction,qw(_update_stats do get_stats));

lives_ok {
    $db->exec(q{ CREATE TABLE test_transactions4 (id INTEGER PRIMARY KEY, name TEXT, value INTEGER ) });
} 'Create test table';

lives_ok {
    $db->txn(sub { $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES ('test1','100') }); });
} 'Simple transaction completed';

is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'test1'), 1, 'Record inserted correctly');

eval { $db->txn(sub {
    $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES ('test2', '200') });
    die "Forced rollback"; } );
};
like($@, qr/Forced rollback/, 'Transaction died as expected');

is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'test2'), 0, 'Rollback worked - no record inserted');

lives_ok {
    $db->transaction->do(sub {
        $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES ('test3','300') });
        $db->transaction->savepoint('point1');

        eval {
            $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES ('test4','400') });
            die "Rollback to savepoint";
        };

        if ($@) {
            $db->transaction->rollback_to('point1');
            $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES ('test5','500') });
        }
    });
} 'Transaction with savepoint completed';

# Verify savepoint results
is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'test3'), 1, 'First insert before savepoint persisted');
is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'test4'), 0, 'Insert after savepoint rolled back');
is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'test5'), 1, 'Insert after rollback to savepoint persisted');

# Test 6: Stats
my $stats = $db->transaction->get_stats();
ok($stats,                      'Got transaction stats');
ok($stats->{total_count} > 0  , 'Transaction count recorded');
ok($stats->{success_count} > 0, 'Successful transactions recorded');
ok($stats->{error_count} > 0  , 'Failed transactions recorded');

# Test 7: Reset stats
$db->transaction->reset_stats();
$stats = $db->transaction->get_stats();
is($stats->{total_count}, 0  , 'Stats reset - total count is 0');
is($stats->{success_count}, 0, 'Stats reset - success count is 0');
is($stats->{error_count}, 0  , 'Stats reset - error count is 0');

# Test 8: Nested transactions
lives_ok { $db->txn(sub {
    $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'outer', 600);
    $db->txn(sub { $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'inner', 700);
         } ); });
} 'Nested transactions completed';

is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name IN (?, ?)', 'outer', 'inner'), 2, 'Both nested transaction records inserted');

# Test 9: Rollback in nested transaction
eval {
    $db->txn(sub {
        $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'outer2', 800);

        $db->txn(sub {
            $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'inner2', 900);
            die "Inner transaction rollback";
             });
         });
};
like($@, qr/Inner transaction rollback/, 'Inner transaction died as expected');

is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name IN (?, ?)', 'outer2', 'inner2'), 0, 'Both records in nested transaction rolled back');

# Test 10: Multiple savepoints
lives_ok {
    $db->transaction->do(sub {
        $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'multi1', 1000);
        $db->transaction->savepoint('point1');
        $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'multi2', 2000);
        $db->transaction->savepoint('point2');

        eval {
            $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'multi3', 3000);
            die "Rollback to point1";
        };

        if ($@) {
            $db->transaction->rollback_to('point1');
            $db->exec(q{ INSERT INTO test_transactions4 (name, value) VALUES (?, ?) }, 'multi4', 4000);
        }
    });
} 'Multiple savepoints transaction completed';

is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'multi1'), 1, 'First insert before any savepoint persisted');
is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'multi2'), 0, 'Second insert rolled back to first savepoint');
is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'multi3'), 0, 'Third insert not persisted');
is( $db->val('SELECT COUNT(*) FROM test_transactions4 WHERE name = ?', 'multi4'), 1, 'Fourth insert after rollback to first savepoint persisted');

done_testing();
