#!perl -T
use strict;
use warnings FATAL => 'all';

use Test::More;
use DBIx::Fast;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74" if $@;

my $db = DBIx::Fast->new(
    db     => 't/db/test.db',
    driver => 'SQLite',
    PrintError => 1 );

can_ok($db,qw(insert update delete q val all hash array count));

$db->delete('test', { id => { '>' => 0 } });

for (qw(be eb)) { $db->execute("SELECT * FROM $_"); }

is ref $db->errors,'ARRAY'  ,'Errors Set';
is scalar(@{$db->errors}),2 ,'Errors Size 2';

is $db->val('select count(*) from test'), 0, 'empty';

is $db->count('test'), 0, 'empty';
is $db->count('test', { id => { '>' => 999 } }), 0, 'empty count where';

is $db->insert('test',{ name => 'test', status  => 1 }, time => 'time'),1,'empty';
is $db->last_id,1,'last insert';

$db->update('test',{ sen => { name => 'update t3st' }, where => { id => 1 } }, time => 'time' );

my $val = $db->val('select name from test where id = 1');
like $val, qr/update t3st/, 'update tests';

$db->up('test', { name => 'update test' }, { id => 1 }, time => 'time' );

$val = $db->val('select name from test where id = ?',1);
like $val, qr/update test/, 'update tests';

$db->insert('test',{ name => rand(6) }, time => 'time') for 1 .. 5;

my @flat = $db->flat('SELECT name FROM test WHERE 1');

is ref \@flat,'ARRAY','flat() ARRAY';
is scalar(@flat),6,'flat() Scalar 6';

$db->flat('SELECT name FROM test WHERE 1');
is ref $db->results,'ARRAY','Results Flat OK';

$db->array('SELECT * FROM test WHERE 1');
is ref $db->results,'ARRAY','Results Array OK';

$db->hash('SELECT * FROM test WHERE id = ? ',1);
is ref $db->results, 'HASH','results hash';

like $db->results->{time}, qr//, 'time NOW()';

$db->all('select * from test');
is ref $db->results, 'ARRAY','results all';

is $db->delete('test', { id => { '=' => $db->last_id } }), 1, 'delete last_id';
is $db->sql,'DELETE FROM test WHERE id = ? ','Delete ID Multi Args =';

$db->delete('test', { id => { '>' => 999 } });
is $db->sql,'DELETE FROM test WHERE id > ? ','Delete ID Multi Args >';

$db->delete('test', { id => 999 } );
is $db->sql,'DELETE FROM test WHERE id = ? ','Delete ID';

like $db->TableName('TableName'), qr/TableName/, 'TableName OK';

done_testing();
