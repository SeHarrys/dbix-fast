#!perl -T
use strict;
use warnings;

use Test::More;
use DBIx::Fast;

plan skip_all => "DBIX_FAST_TEST_PGDB" unless $ENV{DBIX_FAST_TEST_PGDB};

eval "use DBD::Pg 3.18";
plan skip_all => "DBD::Pg 3.18" if $@;

my $db = DBIx::Fast->new( dsn => $ENV{DBIX_FAST_TEST_PGDB} );

done_testing();
