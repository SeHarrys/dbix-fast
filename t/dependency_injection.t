#!perl -T
use strict;
use warnings;
use Test::More;
use Test::Exception;
use DBIx::Fast;
use DBIx::Connector;

eval "use DBD::SQLite 1.74";
plan skip_all => "DBD::SQLite 1.74 required" if $@;

subtest 'Inject DBIx::Connector' => sub {
    my $dsn  = 'dbi:SQLite:dbname=:memory:';
    my $conn = DBIx::Connector->new( $dsn, '', '', { RaiseError => 1 } );

    my $db = DBIx::Fast->new(
        db     => $conn,
        driver => 'SQLite'
        ,    # Still needed for some internal logic like profile class loading
        tn => 0
    );

    isa_ok( $db, 'DBIx::Fast' );
    is( $db->db, $conn, 'Injected connection is used' );

    # Verify it works
    lives_ok { $db->exec('CREATE TABLE injected (id INT)') }
    'Can execute on injected connection';
};

subtest 'Inject Mock Object' => sub {
    {
        package MockConn;
        sub new  { bless { dbh => $_[1] }, $_[0] }
        sub dbh  { $_[0]->{dbh} }
        sub mode { }
    }
    {
        package MockDBH;
        sub new     { bless {}, $_[0] }
        sub quote   { return "'$_[1]'" }
        sub trace   { }
        sub prepare { return MockSTH->new }
        sub ping    { 1 }
    }
    {
        package MockSTH;
        sub new              { bless {}, $_[0] }
        sub execute          { 1 }
        sub fetchrow_hashref { return { id => 1, name => 'Mock' } }
    }

    my $mock_dbh  = MockDBH->new;
    my $mock_conn = MockConn->new($mock_dbh);

    my $db = DBIx::Fast->new(
        db     => $mock_conn,
        driver => 'SQLite',
        tn     => 0
    );

    is( $db->db, $mock_conn, 'Mock connection injected' );

    # Test a method that uses the db
    my $res = $db->hash('SELECT * FROM mock');
    is( $res->{name}, 'Mock', 'Mocked result returned' );
};

done_testing();
