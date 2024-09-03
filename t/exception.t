#!perl
use strict;
use warnings;

use Test::More;
use Test::Exception;
use DBIx::Fast;

plan( skip_all => 'Skip tests on Windows' ) if $^O eq 'MSWin32';

my $db = DBIx::Fast->new(
    db     => 't/db/test.db',
    driver => 'SQLite',
    RaiseError => 0,
    PrintError => 1,
    trace => 0
    );

dies_ok { 1 / 0 } 'Ilegal division 1 / 0';
dies_ok { DBIx::Fast->new( driver => 'MrTester' ) } 'DBIx::Fast->new( driver => "MrTester" ) dies';

can_ok $db,'Exception';

=testing
{
    local $SIG{__WARN__} = sub {
	like($_[0], qr/Exception/, "Exception('Tester')");
    }; $db->Exception('Tester');
}
{
    local $SIG{__WARN__} = sub {
	like($_[0], qr/Exception/, "Exception => TableName()");
    }; $db->TableName('("4928');
}
{
    local $SIG{__WARN__} = sub {
        like($_[0], qr/Exception/, "_check_dsn Failed DBI");
    }; $db->_check_dsn('dbx:KikoTT:db:bd');
}
{
    local $SIG{__WARN__} = sub {
        like($_[0], qr/Exception/, "_check_dsn Failed DataBase");
    }; $db->_check_dsn('dbi:MariaDB::bd');
}
{
    local $SIG{__WARN__} = sub {
        like($_[0], qr/Exception/, "_check_dsn Failed Host");
    }; $db->_check_dsn('dbi:MariaDB:db:');
}
=cut

done_testing();
