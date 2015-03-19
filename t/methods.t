#!perl -T
use warnings FATAL => 'all';

use Test::More tests => 13;

use DBIx::Fast;

my $db = DBIx::Fast->new( db => 't/db/test.db', host => 'sqlite');

$db->delete('test', { id => { '>' => 0 } });

for (qw(be eb)) { $db->execute("SELECT * FROM $_"); }

is ref $db->errors,'ARRAY','Errors OK';

can_ok($db,qw(insert update delete q val all hash array count));

is_deeply $db->val('select count(*) from test'), 0, 'empty';
is_deeply $db->count('test'), 0, 'empty';
is_deeply $db->count('test',
		     {
			 id  => { '>' => 999 },
		     } ) , 0, 'empty count where';

is_deeply $db->insert('test',{ name => 'test', status  => 1 }, time => 'time')
    ,1,'empty';

is_deeply $db->last_id,1,'last insert';

$db->update('test',{ sen => { name => 'update test' },
		     where => { id => 1 },
	    }, time => 'time' );

my $val = $db->val('select name from test where id = 1');

like $val, qr/update test/, 'update tests';

$db->array('SELECT * FROM test WHERE 1');
is ref $db->results,'ARRAY','Results Array OK';

$db->hash('SELECT * FROM test WHERE id = ? ',1);
is_deeply ref $db->results, 'HASH','results hash';

like $db->results->{time}, qr//, 'time NOW()';

$db->all('select * from test');
is_deeply ref $db->results, 'ARRAY','results all';

is_deeply $db->delete('test', { id => { '=' => $db->last_id } }), 1,
    'delete last_id';

done_testing();
