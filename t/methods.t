#!perl -T
use warnings FATAL => 'all';

use Test::More tests => 12;

use DBIx::Fast;

my $db = DBIx::Fast->new( db => 't/db/test.db', host => 'sqlite');
##trace => '1' , profile => '!Statement:!MethodName' );

$db->delete('test', { id => { '>' => 0 } });

#for (qw(cc co ce)) { $d->execute('SELECT * FROM '.$_); }
#print Dumper $d->errors;

can_ok($db,qw(insert update delete q val count));

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

$db->hash('SELECT * FROM test WHERE id = ? ',1);
is_deeply ref $db->results, 'HASH','results hash';

like $db->results->{time}, qr//, 'time NOW()';

$db->all('select * from test');
is_deeply ref $db->results, 'ARRAY','results all';

is_deeply $db->delete('test', { id => { '=' => $db->last_id } }), 1,
    'delete last_id';

done_testing();
