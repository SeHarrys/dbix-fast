#!perl -T
use strict;
use warnings;

use Test::More;
use Test::Exception;

use DBIx::Fast;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74" if $@;

my ($db,$args);
my $sql_db = 't/db/test.db';

$db = DBIx::Fast->new( SQLite => $sql_db , quote  => '`' );

is $db->args->{driver},'SQLite',"SQLite = driver";
is $db->args->{db},$sql_db,"SQLite = db";

is $db->args->{quote},'`',"quote => '`'";

$db->_set_args( { DBI => { RaiseError => 99, PrintError => 99 , AutoCommit => 99 } } );

$args = $db->args;

is $args->{DBI}->{RaiseError},99,"RaiseError => 99";
is $args->{DBI}->{RaiseError},99,"PrintError => 99";
is $args->{DBI}->{RaiseError},99,"AutoCommit => 99";

is ref $db->Q,'SQL::Abstract',' abstract => 1';

$db = DBIx::Fast->new( SQLite => $sql_db , abstract => 0);

isnt ref $db->Q,'SQL::Abstract',' abstract => 0';

done_testing();
