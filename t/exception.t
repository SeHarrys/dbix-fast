#!perl
use strict;
use DBIx::Fast;
use Test::More;
use Test::Exception;

plan( skip_all => 'Skip tests on Windows' ) if $^O eq 'MSWin32';

dies_ok { 1 / 0 } 'Ilegal division 1 / 0';

my $db = DBIx::Fast->new( SQLite => 't/db/test.db' , PrintError => 1 , RaiseError => 0);

dies_ok { $db->_dsn_to_dbi('SSS://sql:pass@host:/dbname') } '_dsn_to_dbi : Bad string';
dies_ok { $db->_dsn_to_dbi('sql://user@host/dbname') }      '_dsn_to_dbi : Bad DSN';

$db = DBIx::Fast->new( SQLite => 't/db/test.db' , PrintError => 1 , RaiseError => 0);

dies_ok { DBIx::Fast->new( driver => 'MrTester' ) } 'DBIx::Fast->new( driver => "MrTester" ) dies';

can_ok $db,'Exception';

{ local $SIG{__DIE__} = sub { like($_[0], qr/Exception: TableName not valid/,"Exception => TableName()"); }; eval { $db->TableName('("4928') }; }
{ local $SIG{__DIE__} = sub { like($_[0], qr/Exception: Tester/,"Exception('Tester')"); }; eval { $db->Exception('Tester') }; }

{ local $SIG{__DIE__} = sub { like($_[0], qr/Exception/, "_check_dsn Failed DBI"); };      eval { $db->_check_dsn('dbx:KikoTT:db:bd') }; }
{ local $SIG{__DIE__} = sub { like($_[0], qr/Exception/, "_check_dsn Failed DataBase"); }; eval { $db->_check_dsn('dbi:MariaDB::bd') }; }
{ local $SIG{__DIE__} = sub { like($_[0], qr/Exception/, "_check_dsn Failed Host"); };     eval { $db->_check_dsn('dbi:MariaDB:db:') }; }

{ local $SIG{__DIE__} = sub { like($_[0], qr/Exception: Need a DSN or Host/, "Need a DSN or Host"); }; eval { DBIx::Fast->new( Error => 1 ) }; }

done_testing();
