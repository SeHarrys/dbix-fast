#!perl -T
use strict;
use warnings;

use Test::More;
use Test::Exception;
use DBIx::Fast;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74" if $@;

plan tests => 12;

my $db = DBIx::Fast->new( SQLite => 't/db/test.db' , tn => 1 );

ok($db->schema, 'Schema object created');
isa_ok($db->schema, 'DBIx::Fast::Schema');

my $tables = $db->schema->_load_tables_name;

ok $tables->{test},  "table test: test";
ok $tables->{test2}, "table test2: test";
ok $tables->{test3}, "table test3: test";

isnt defined($tables->{notftaf}),1, "table no exist";

is $db->TableName('test'),'test',   'TableName("test")';
is $db->TableName('test2'),'test2', 'TableName("test2")';
is $db->TableName('test3'),'test3', 'TableName("test3")';

{ local $SIG{__DIE__} = sub { like($_[0], qr/Exception: TableName/, "TableName - Not exist"); }; eval { $db->TableName('asfnbaw') }; }

is scalar(@{$db->schema->table_info('test')}),4, 'Scalar 4';

my $table_size = $db->schema->table_size('test');
is $table_size->{rows},5, 'Schema table_size 5';

done_testing();
