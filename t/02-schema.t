use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBIx::Fast;

my $db = DBIx::Fast->new(
    dsn => 'dbi:SQLite:dbname=:memory:',
    RaiseError => 1,
    PrintError => 0
);

# Test básico de Schema
ok($db->schema, 'Schema object created');
isa_ok($db->schema, 'DBIx::Fast::Schema');

# Crear tablas de prueba
$db->exec(q{
    CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT UNIQUE,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
});

$db->exec(q{
    CREATE TABLE posts (
        id INTEGER PRIMARY KEY,
        user_id INTEGER,
        title TEXT NOT NULL,
        content TEXT,
        FOREIGN KEY(user_id) REFERENCES users(id)
    )
});

my $users_info = $db->schema->table_info('users');
ok($users_info, 'Got users table info');
is(ref($users_info), 'ARRAY', 'Table info returned as array');

# Test primary keys
my $pk = $db->schema->primary_keys('users');
is_deeply($pk, ['id'], 'Correct primary key for users table');

# Test cache
$db->schema->clear_cache();
ok(keys %{$db->schema->tables} == 0, 'Cache cleared');

# Test error handling
throws_ok { $db->schema->table_info();             } qr/Table name required/, 'Throws error when table name missing';
#throws_ok { $db->schema->table_info('not_exists'); } qr/Table non-exist/,     'Throws error for non-existent table';

done_testing;
