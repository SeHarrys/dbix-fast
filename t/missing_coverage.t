#!perl -T
use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBIx::Fast;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74 required" if $@;

my $db = DBIx::Fast->new( dsn => 'dbi:SQLite:dbname=:memory:', driver => 'SQLite', RaiseError => 1 );

# Setup schema
$db->exec(q{ CREATE TABLE test_missing ( id INTEGER PRIMARY KEY, name TEXT, value INTEGER ) });

subtest 'q() method' => sub {
    $db->q('SELECT * FROM test_missing WHERE id = ?', 1);
    is($db->sql, 'SELECT * FROM test_missing WHERE id = ?', 'q() sets sql');
    is_deeply($db->p, [1], 'q() sets params');
};

subtest 'execute_prepare()' => sub {
    $db->sql('INSERT INTO test_missing (name, value) VALUES (?, ?)');
    lives_ok { $db->execute_prepare('test1', 100) } 'execute_prepare runs';
    is($db->last_sql, 'INSERT INTO test_missing (name, value) VALUES (?, ?)', 'last_sql set');

    my $count = $db->val('SELECT COUNT(*) FROM test_missing');
    is($count, 1, 'Row inserted via execute_prepare');
};

subtest 'up()' => sub {
    lives_ok {
        $db->up('test_missing', { value => 200 }, { name => 'test1' })
    } 'up runs';

    my $val = $db->val('SELECT value FROM test_missing WHERE name = ?', 'test1');
    is($val, 200, 'Value updated via up');
};

subtest 'make_sen()' => sub {
    $db->sql('SELECT * FROM test_missing WHERE name = :name AND value = :val');
    my $args = { name => 'test1', val => 200 };
    
    $db->make_sen($args);
    
    is($db->sql, 'SELECT * FROM test_missing WHERE name = ? AND value = ?', 'SQL placeholders replaced');
    is_deeply($db->p, ['test1', 200], 'Params extracted correctly');
    
    $db->sql('SELECT :x + :x as double_x');
    $db->make_sen({ x => 5 });
    is($db->sql, 'SELECT ? + ? as double_x', 'Multiple occurrences replaced');
    is_deeply($db->p, [5, 5], 'Params duplicated correctly');
};

subtest 'load_extension()' => sub {
    my $schema = $db->load_extension('Schema');
    isa_ok($schema, 'DBIx::Fast::Schema', 'Extension loaded');
    
    my $schema2 = $db->load_extension('Schema');
    is($schema, $schema2, 'Extension cached');
    
    throws_ok { $db->load_extension('NonExistent') } qr/Error: load_extension/, 'Loading non-existent extension fails';
};

subtest '_dsn_to_dbi parsing' => sub {
    # Postgres
    my $pg_dsn = 'postgres://user:pass@host:5432/dbname';

    my $dbi_str = $db->_dsn_to_dbi('postgres://u:p@h:5432/d');
    is($dbi_str, 'dbi:Pg:dbname=d;host=h;port=5432', 'Postgres URI parsed');
    is($db->args->{Auth}->{user}, 'u', 'User parsed');
    is($db->args->{Auth}->{password}, 'p', 'Password parsed');
    
    # MariaDB
    $dbi_str = $db->_dsn_to_dbi('mariadb://u:p@h:3306/d');
    is($dbi_str, 'dbi:MariaDB:dbname=d;host=h;port=3306', 'MariaDB URI parsed');
    
    # MySQL
    $dbi_str = $db->_dsn_to_dbi('mysql://u:p@h:3306/d');
    is($dbi_str, 'dbi:mysql:dbname=d;host=h;port=3306', 'MySQL URI parsed');
    
    # SQLite
    $dbi_str = $db->_dsn_to_dbi('sqlite:////tmp/foo.db');
    is($dbi_str, 'dbi:SQLite:dbname=/tmp/foo.db', 'SQLite URI parsed');
};

done_testing();
