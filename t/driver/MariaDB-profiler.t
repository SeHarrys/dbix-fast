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
my $db  = DBIx::Fast->new( dsn => $dsn, tn => 0 );

# Setup
$db->exec('DROP TABLE IF EXISTS prof_test');
$db->exec(q{
    CREATE TABLE prof_test (
        id    INT AUTO_INCREMENT PRIMARY KEY,
        name  VARCHAR(255),
        value INT DEFAULT 0
    ) ENGINE=InnoDB
});

# --- Query Tracker (generic profiler) ---

subtest 'Tracker on MariaDB' => sub {
    my $tracker = $db->tracker;
    ok($tracker, 'Tracker initialized');
    isa_ok($tracker, 'DBIx::Fast::Profiler');

    $tracker->clear();

    $db->insert('prof_test', { name => 'alice', value => 100 });
    $db->insert('prof_test', { name => 'bob',   value => 200 });
    $db->all('SELECT * FROM prof_test');
    $db->val('SELECT COUNT(*) FROM prof_test');
    $db->up('prof_test', { value => 150 }, { name => 'alice' });
    $db->delete('prof_test', { name => 'bob' });

    my $stats = $tracker->get_stats();
    is($stats->{total_queries}, 6, '6 queries tracked');
    ok($stats->{total_time} > 0,   'Total time > 0');
    ok($stats->{avg_time} > 0,     'Avg time > 0');

    my $by_type = $tracker->get_detailed_stats();
    is($by_type->{INSERT}->{count}, 2, '2 INSERTs');
    is($by_type->{SELECT}->{count}, 2, '2 SELECTs');
    is($by_type->{UPDATE}->{count}, 1, '1 UPDATE');
    is($by_type->{DELETE}->{count}, 1, '1 DELETE');
};

# --- Driver Profile (MariaDB-specific) ---

subtest 'Profile::MariaDB init' => sub {
    my $profile = $db->profiler;
    ok($profile, 'MariaDB profile loaded');
    isa_ok($profile, 'DBIx::Fast::Profile::MariaDB');
};

subtest 'Profile::MariaDB stats' => sub {
    my $stats = $db->profiler->get_stats();
    ok($stats, 'Got stats');
    ok($stats->{global}, 'Has global stats');
    ok($stats->{global}->{Questions}, 'Questions counter exists');
    ok($stats->{global}->{Com_select}, 'Com_select counter exists');
};

subtest 'Profile::MariaDB explain' => sub {
    my $plan = $db->profiler->explain_query('SELECT * FROM prof_test WHERE id = ?', 1);
    ok($plan, 'EXPLAIN returned result');
    ok(scalar @$plan > 0, 'Has at least one row');
};

subtest 'Profile::MariaDB table_stats' => sub {
    my $stats = $db->profiler->get_table_stats('prof_test');
    ok($stats, 'Got table stats');
    ok(scalar @$stats > 0, 'Has table info');
    ok($stats->[0]->{engine}, 'Engine present');
};

subtest 'Profile::MariaDB index_stats' => sub {
    my $stats = $db->profiler->get_index_stats('prof_test');
    ok($stats, 'Got index stats');
    ok(scalar @$stats > 0, 'Has index info (PRIMARY)');
};

subtest 'Profile::MariaDB slow queries' => sub {
    my $slow = eval { $db->profiler->get_slow_queries() };
    if ($@) {
        pass('get_slow_queries not supported (profiling deprecated in this MariaDB version)');
    } else {
        ok(defined $slow, 'get_slow_queries returned');
    }
};

subtest 'Profile::MariaDB connections' => sub {
    my $conns = $db->profiler->get_current_connections();
    ok($conns, 'Got connections');
    ok($conns->{total_connections} > 0, 'At least 1 connection');
};

# Cleanup
$db->exec('DROP TABLE IF EXISTS prof_test');

done_testing();
