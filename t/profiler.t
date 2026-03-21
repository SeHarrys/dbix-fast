use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBIx::Fast;

plan skip_all => "Set DBIX_FAST_PROFILER=1" unless $ENV{'DBIX_FAST_PROFILER'};

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74 required" if $@;

my $db = DBIx::Fast->new(
    dsn        => 'dbi:SQLite:dbname=:memory:',
    driver     => 'SQLite',
    RaiseError => 1,
    PrintError => 0,
);

# Activate the query tracker
my $tracker = $db->tracker;

subtest 'Tracker initialization' => sub {
    ok($tracker, 'Tracker loaded');
    isa_ok($tracker, 'DBIx::Fast::Profiler');
    is($tracker->auto_print, 0, 'auto_print off by default');
};

# Setup
$db->exec(q{ CREATE TABLE test_profiler ( id INTEGER PRIMARY KEY, name TEXT, value INTEGER ) });

subtest 'exec() tracked' => sub {
    $tracker->clear();
    for my $i (1..3) {
        $db->exec('INSERT INTO test_profiler (name, value) VALUES (?, ?)', "test$i", $i * 100);
    }

    my $stats = $tracker->get_stats();
    is($stats->{total_queries}, 3, 'exec inserts tracked');
    ok($stats->{total_time} > 0,   'Total time recorded');
};

subtest 'all() tracked' => sub {
    $tracker->clear();
    $db->all('SELECT * FROM test_profiler');

    is($tracker->get_stats()->{total_queries}, 1, 'all() tracked');
    like($tracker->queries->[0]->{sql}, qr/SELECT \*/, 'SQL recorded');
};

subtest 'hash() tracked' => sub {
    $tracker->clear();
    $db->hash('SELECT * FROM test_profiler WHERE id = ?', 1);

    is($tracker->get_stats()->{total_queries}, 1, 'hash() tracked');
};

subtest 'val() tracked' => sub {
    $tracker->clear();
    $db->val('SELECT name FROM test_profiler WHERE id = ?', 1);

    is($tracker->get_stats()->{total_queries}, 1, 'val() tracked');
};

subtest 'flat() tracked' => sub {
    $tracker->clear();
    $db->flat('SELECT name FROM test_profiler');

    is($tracker->get_stats()->{total_queries}, 1, 'flat() tracked');
};

subtest 'array() tracked' => sub {
    $tracker->clear();
    $db->array('SELECT name FROM test_profiler');

    is($tracker->get_stats()->{total_queries}, 1, 'array() tracked');
};

subtest 'insert() tracked' => sub {
    $tracker->clear();
    $db->insert('test_profiler', { name => 'prof_insert', value => 999 });

    is($tracker->get_stats()->{total_queries}, 1, 'insert() tracked');
    like($tracker->queries->[0]->{sql}, qr/INSERT/, 'INSERT SQL recorded');
};

subtest 'update via up() tracked' => sub {
    $tracker->clear();
    $db->up('test_profiler', { value => 111 }, { id => 1 });

    is($tracker->get_stats()->{total_queries}, 1, 'up() tracked');
    like($tracker->queries->[0]->{sql}, qr/UPDATE/, 'UPDATE SQL recorded');
};

subtest 'delete() tracked' => sub {
    $tracker->clear();
    $db->delete('test_profiler', { name => 'prof_insert' });

    is($tracker->get_stats()->{total_queries}, 1, 'delete() tracked');
    like($tracker->queries->[0]->{sql}, qr/DELETE/, 'DELETE SQL recorded');
};

subtest 'query limit enforced' => sub {
    $tracker->clear();
    $tracker->max_queries(3);

    for (1..5) {
        $db->exec('SELECT 1');
    }
    is(scalar(@{$tracker->queries}), 3, 'Buffer limited to 3');
    $tracker->max_queries(1000);
};

subtest 'disable/enable' => sub {
    $tracker->clear();

    $tracker->enabled(0);
    $db->exec('SELECT 1');
    is(scalar(@{$tracker->queries}), 0, 'Disabled: no tracking');

    $tracker->enabled(1);
    $db->exec('SELECT 1');
    is(scalar(@{$tracker->queries}), 1, 'Enabled: tracking');
};

subtest 'query info structure' => sub {
    $tracker->clear();
    $db->val('SELECT name FROM test_profiler WHERE id = ?', 1);

    my $q = $tracker->queries->[0];
    ok($q->{sql},       'sql present');
    ok($q->{params},    'params present');
    ok($q->{duration},  'duration present');
    ok($q->{time},      'timestamp present');
    ok(defined $q->{stack}, 'stack present');
};

subtest 'detailed stats by type' => sub {
    $tracker->clear();
    $db->exec('SELECT 1');
    $db->insert('test_profiler', { name => 'x', value => 0 });
    $db->up('test_profiler', { value => 1 }, { name => 'x' });
    $db->delete('test_profiler', { name => 'x' });

    my $stats = $tracker->get_detailed_stats();
    ok($stats->{SELECT}, 'SELECT stats');
    ok($stats->{INSERT}, 'INSERT stats');
    ok($stats->{UPDATE}, 'UPDATE stats');
    ok($stats->{DELETE}, 'DELETE stats');
};

done_testing();
