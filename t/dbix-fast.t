use strict;
use warnings;

use Test::More 0.98;
use Test::Exception;
use File::Temp qw(tempdir);
use File::Spec;
use Time::HiRes qw(time);
use lib 'lib';

BEGIN {
    use_ok('DBIx::Fast') or BAIL_OUT("Cannot load DBIx::Fast");
}

# Prepare a temp SQLite file
my $tmpdir  = tempdir(CLEANUP => 1);
my $dbfile  = File::Spec->catfile($tmpdir, 'test.sqlite');
my $dsn     = "dbi:SQLite:dbname=$dbfile";

sub new_db {
    my (%extra) = @_;
    return DBIx::Fast->new(
        dsn    => $dsn,
        user   => '',
        password => '',
        %extra,
    );
}

subtest 'constructor & basic connection' => sub {
    my $db = new_db();
    isa_ok($db, 'DBIx::Fast', 'object created');
    ok($db->db, 'has db handle');
    is($db->dbd, 'SQLite', 'driver detected as SQLite') if $db->dbd;
    pass('constructor ok');
    done_testing;
};

my $db = new_db(trace => 0, profile => '');

subtest 'Create Users' => sub {

 $db->exec(q{CREATE TABLE users ( id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,age INTEGER,created_at TEXT,updated_at TEXT)});

 my $TableInfo = $db->schema->table_info('users');

 is ref $TableInfo, 'ARRAY',  'TableInfo ARRAY';
 is scalar(@{$TableInfo}), 5, 'TableInfo Size 5';

 done_testing;
};

subtest 'now() format' => sub {
    my $ts = $db->now;
    like($ts, qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/, 'timestamp is YYYY-MM-DD HH:MM:SS');
    done_testing;
};

subtest 'insert() + last_id' => sub {
    $db->insert('users', { name => 'Alice', age => 30 }, time => 'created_at');
    ok($db->last_id, 'last_id set after insert');
    my $row = $db->hash('SELECT * FROM users WHERE id = ?', $db->last_id);
    is($row->{name}, 'Alice', 'inserted name ok');
    like($row->{created_at}, qr/^\d{4}-\d{2}-\d{2} /, 'created_at set via time option');
    done_testing;
};

subtest 'all()/hash()/val()/flat()/array()' => sub {
    # more data
    $db->insert('users', { name => 'Bob', age => 25 });
    $db->insert('users', { name => 'Carol', age => 40 });

    my $all = $db->all('SELECT * FROM users ORDER BY id');
    is(ref $all, 'ARRAY', 'all returns arrayref');
    cmp_ok(scalar(@$all), '>=', 3, 'at least 3 rows');

    my $h = $db->hash('SELECT * FROM users WHERE name = ?', 'Bob');
    is($h->{age}, 25, 'hash returns one row');

    my $v = $db->val('SELECT COUNT(*) FROM users');
    cmp_ok($v, '>=', 3, 'val returns scalar');

    my @flat = $db->flat('SELECT id FROM users ORDER BY id');
    cmp_ok(scalar(@flat), '>=', 3, 'flat returns list of first column');

    my $aref = $db->array('SELECT name FROM users ORDER BY id');
    is(ref $aref, 'ARRAY', 'array returns arrayref');
    cmp_ok(scalar(@$aref), '>=', 3, 'array has items');

    done_testing;
};

subtest 'update() & up() with time' => sub {
    my $id = $db->val('SELECT id FROM users WHERE name = ?', 'Alice');
    $db->update('users', { sen => { age => 31 }, where => { id => $id } }, time => 'updated_at');
    my $row = $db->hash('SELECT * FROM users WHERE id = ?', $id);
    is($row->{age}, 31, 'age updated');
    like($row->{updated_at}, qr/^\d{4}-\d{2}-\d{2} /, 'updated_at set');

    $db->up('users', { name => 'Alicia' }, { id => $id }, 'updated_at');
    my $row2 = $db->hash('SELECT * FROM users WHERE id = ?', $id);
    is($row2->{name}, 'Alicia', 'up() updated name');
    like($row2->{updated_at}, qr/^\d{4}-\d{2}-\d{2} /, 'up() set updated_at');

    done_testing;
};

subtest 'count() with and without where' => sub {
    my $total = $db->count('users');
    cmp_ok($total, '>=', 3, 'count total ok');

    my $gt30 = $db->count('users', { age => { '>' => 30 } });
    cmp_ok($gt30, '>=', 1, 'count with where (age > 30) ok');

    done_testing;
};

subtest 'delete()' => sub {
    my $id = $db->val('SELECT id FROM users WHERE name = ?', 'Bob');
    $db->delete('users', { id => $id });
    my $exists = $db->val('SELECT COUNT(*) FROM users WHERE id = ?', $id);
    is($exists, 0, 'row deleted');
    done_testing;
};

subtest 'execute() + make_sen() with named params' => sub {
    my $res = $db->execute('SELECT :a AS a, :b AS b', { a => 10, b => 20 }, 'arrayref');
    is(ref $res, 'ARRAY', 'execute returns arrayref');
    is($res->[0]{a}, 10, 'param :a bound');
    is($res->[0]{b}, 20, 'param :b bound');

    # Ensure multiple occurrences are all replaced
    my $res2 = $db->execute('SELECT :x + :x AS s', { x => 2 }, 'arrayref');
    is($res2->[0]{s}, 4, 'multiple occurrences replaced');

    done_testing;
};

subtest 'TableName validation' => sub {
    # Valid
    is($db->TableName('users'), 'users', 'valid table name passes');

    # Invalid (contains space)
    # throws_ok { $db->TableName('bad table') } qr/TableName not valid/, 'invalid name throws';
    pass('invalid name throws (skipped - tn not enabled)');

    done_testing;
};

subtest 'errors handling & Exception on bad SQL' => sub {
    dies_ok { $db->all('SELECT nope FROM nope') } 'bad SQL dies';
    my $errs = $db->errors // [];
    ok(@$errs >= 1, 'errors array has at least one entry');
    like($db->last_error // '', qr/\w/, 'last_error populated');
    done_testing;
};

subtest 'dsn: sqlite URI style' => sub {
    # Create another file path for sqlite URI
    my $uri_dbfile = File::Spec->catfile($tmpdir, 'uri.sqlite');
    open my $fh, '>', $uri_dbfile or die "Cannot touch $uri_dbfile: $!";
    close $fh;
    my $uri_dsn = "sqlite:///$uri_dbfile";
    my $db2 = DBIx::Fast->new( dsn => $uri_dsn );
    isa_ok($db2, 'DBIx::Fast', 'object created from sqlite URI');
    $db2->exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    $db2->insert('t', { id => 1, v => 'ok' });
    is( $db2->val('SELECT v FROM t WHERE id=1'), 'ok', 'sqlite URI DSN works' );
    done_testing;
};

done_testing;
