#!perl -T
use strict;
use warnings;

use Test::More;
use DBIx::Fast;

plan skip_all => "DBIX_FAST_TEST_MYSQL" unless $ENV{DBIX_FAST_TEST_MYSQL};

eval "use DBD::mysql 5.01";
plan skip_all => "DBD::mysql 5.01" if $@;

my $db = DBIx::Fast->new( dsn => $ENV{DBIX_FAST_TEST_MYSQL} );

done_testing();
