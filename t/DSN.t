#!perl -T
use strict;
use warnings;

use Test::More;
use DBIx::Fast;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74" if $@;

my $db = DBIx::Fast->new(
    db     => 't/db/test.db',
    driver => 'SQLite',
    PrintError => 1
    );

my $DSN = {
    'postgresql://user@127.0.0.1:5432/dbname?reconnect=60' => "dbi:Pg:dbname=dbname;host=127.0.0.1;port=5432",
    'postgresql://user:123456@127.0.0.1:5432/dbname' => "dbi:Pg:dbname=dbname;host=127.0.0.1;port=5432",
    'postgres://user:123456@db:5432/dbname' => "dbi:Pg:dbname=dbname;host=db;port=5432",
    'mysql://user:pass@localhost:3306/dbname?get-server-public-key=true' => "dbi:mysql:dbname=dbname;host=localhost;port=3306",
    'mysql://user:pass@localhost:3306/dbname?get-server-public-key=true&k=v&k=v&k=v' => "dbi:mysql:dbname=dbname;host=localhost;port=3306",
    'mariadb://user:pass@server:3306/db' => "dbi:MariaDB:dbname=db;host=server;port=3306",
};

for my $Key (keys %{$DSN}) {
    is $db->_dsn_to_dbi($Key),$DSN->{$Key},'_dsn_to_dbi : '.$Key;
}

is $db->_dsn_to_dbi('SSS://sql:pass@host:/dbname'),undef,'_dsn_to_dbi : Bad string';
is $db->_dsn_to_dbi('sql://user@host/dbname')     ,undef,'_dsn_to_dbi : Bad DSN';

done_testing();
