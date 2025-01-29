#!perl -T
use strict;
use warnings;

use Test::More;
use DBIx::Fast;

eval "use DBD::MariaDB 1.23";
plan skip_all => "DBD::MariaDB 1.23" if $@;
plan skip_all => "DBIX_FAST_TEST_MARIADB" unless $ENV->{DBIX_FAST_TEST_MARIADB};

my $db = DBIx::Fast->new( dsn => $ENV->{DBIX_FAST_TEST_MARIADB} );

done_testing();
