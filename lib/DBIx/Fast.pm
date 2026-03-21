package DBIx::Fast;

use v5.38;
use Object::Pad;

our $VERSION = '0.16';

use DBI;
use DBIx::Connector;
use SQL::Abstract;
use Carp qw(croak);
use Time::HiRes qw(time);

use DBIx::Fast::Schema;
use DBIx::Fast::Transaction;
use DBIx::Fast::Profiler;

class DBIx::Fast {

    # Public accessor fields
    field $db       :accessor = undef;
    field $sql      :accessor = undef;
    field $last_sql :accessor = undef;
    field $p        :accessor = undef;
    field $Q        :accessor = undef;
    field $results  :accessor = undef;
    field $last_id  :accessor = undef;

    # Internal state with readers
    field $_args       :reader(args)       = undef;
    field $_dbd        :reader(dbd)        = undef;
    field $_dsn        :reader(dsn)        = undef;
    field $_errors     :reader(errors)     = [];
    field $_last_error :reader(last_error) = undef;

    # Lazy subsystems
    field $_schema;
    field $_transaction;
    field $_profiler;       # Driver-specific profile (MariaDB/SQLite)
    field $_query_tracker;  # Generic query profiler (DBIx::Fast::Profiler)
    field %_extensions;


    # Constructor params
    field $_init_db         :param(db)                 = undef;
    field $_init_dsn        :param(dsn)                = '';
    field $_init_SQLite     :param(SQLite)             = undef;
    field $_init_driver     :param(driver)             = '';
    field $_init_user       :param(user)               = '';
    field $_init_password   :param(password)           = '';
    field $_init_host       :param(host)               = '';
    field $_init_tn         :param(tn)                 = 0;
    field $_init_quote      :param(quote)              = '';
    field $_init_trace      :param(trace)              = '';
    field $_init_profile    :param(profile)            = '';
    field $_init_abstract   :param(abstract)           = 1;
    field $_init_RaiseError :param(RaiseError)         = undef;
    field $_init_PrintError :param(PrintError)         = undef;
    field $_init_AutoCommit :param(AutoCommit)         = undef;
    field $_init_mysql_utf8 :param(mysql_enable_utf8)  = 0;
    field $_init_Error      :param(Error)              = undef;  # Accepted for compat, use RaiseError/PrintError

    ADJUST {
        # SQLite shortcut
        if ($_init_SQLite) {
            $_init_db     //= $_init_SQLite;
            $_init_driver   = 'SQLite';
        }

        # Build processed config
        $_args = {
            DBI => {
                RaiseError => $_init_RaiseError // 1,
                PrintError => $_init_PrintError // 0,
                AutoCommit => $_init_AutoCommit // 1,
            },
            Auth => {
                user     => $_init_user,
                password => $_init_password,
                host     => $_init_host,
            },
            tn       => $_init_tn,
            db       => $_init_db // '',
            dsn      => $_init_dsn,
            driver   => $_init_driver,
            quote    => $_init_quote,
            trace    => $_init_trace,
            profile  => $_init_profile,
            abstract => $_init_abstract,
        };

        $_args->{DBI}->{mysql_enable_utf8} = 1 if $_init_mysql_utf8;

        # SQLite file check
        if ($_init_SQLite) {
            $self->Exception("No DB Found : $_init_SQLite")
              unless -e $_init_SQLite;
        }

        $Q = SQL::Abstract->new if $_args->{abstract};

        unless ($_args->{dsn} || $_args->{db}) {
            $self->Exception("Need a DSN or Host");
        }

        $_dsn = $_args->{dsn}
          ? $self->_check_dsn($_args->{dsn})
          : $self->_make_dsn($_args);

        # Handle db param: connector object or string
        if ($_init_db && ref($_init_db)) {
            $db = $_init_db;
        }
        else {
            $db = DBIx::Connector->new(
                $_dsn,
                $_args->{Auth}->{user},
                $_args->{Auth}->{password},
                $_args->{DBI}
            );
        }

        $db->mode('ping');

        $db->dbh->quote($_args->{quote}) if $_args->{quote};

        $db->dbh->{HandleError} = sub {
            $self->set_error($DBI::err, $DBI::errstr);
            return 0;  # Let DBI continue with RaiseError/PrintError
        };

        $db->dbh->trace($_args->{trace}, 'dbix-fast-trace')
          if $_args->{trace};

        $self->_profile($_args->{profile}) if $_args->{profile};

        $self->schema->_load_tables_name if $_args->{tn};
    }

    # Setters for internal state (needed by tests and internal methods)
    method _set_args ($val) { $_args = $val }
    method _set_dbd  ($val) { $_dbd  = $val }
    method _set_dsn  ($val) { $_dsn  = $val }

    # Lazy subsystem accessors
    method schema      { $_schema      //= DBIx::Fast::Schema->new(dbix => $self) }
    method transaction { $_transaction //= DBIx::Fast::Transaction->new(dbix => $self) }
    method tracker {
        $_query_tracker //= DBIx::Fast::Profiler->new(dbix => $self, auto_print => 0);
    }

    method profiler {
        return $_profiler if $_profiler;

        my $driver        = $_dbd;
        my $profile_class = "DBIx::Fast::Profile::$driver";

        (my $_pf = "$profile_class.pm") =~ s|::|/|g; eval { require $_pf };

        if ($@) {
            warn "No profile support for $driver, using base profile";
            require DBIx::Fast::Profile::Base;
            $_profiler = DBIx::Fast::Profile::Base->new(dbix => $self);
            return $_profiler;
        }

        $_profiler = $profile_class->new(dbix => $self);
        $_profiler->init();

        return $_profiler;
    }

    # Transaction helper
    method txn ($code, $options = undef) {
        return $self->transaction->do($code, $options);
    }

    method load_extension ($extension) {
        my $module = "DBIx::Fast::$extension";

        (my $_mf = "$module.pm") =~ s|::|/|g; eval { require $_mf };
        $self->Exception("Error: load_extension => $@") if $@;

        my $attr = lc($extension);

        # Check if there's already a method for this
        if ($self->can($attr)) {
            return $self->$attr;
        }

        return $_extensions{$attr} if exists $_extensions{$attr};

        $_extensions{$attr} = $module->new(dbix => $self);
        return $_extensions{$attr};
    }

    method now () {
        my ($sec, $min, $hour, $mday, $mon, $year) = localtime;

        return sprintf(
            "%04d-%02d-%02d %02d:%02d:%02d",
            $year + 1900, $mon + 1, $mday, $hour, $min, $sec
        );
    }

    method set_error ($id, $error_msg) {
        my $error = { id => $id, error => $error_msg, time => time() };

        push @{$_errors}, $error;

        $_last_error =
          qq{$error->{time} - [$error->{id}] - $error->{error}};
    }

    # DSN handling

    method _Driver_dbd ($dbd_name) {
        $self->Exception("Error DBD Driver") unless $dbd_name;

        for my $d (qw(SQLite Pg MariaDB mysql)) {
            if (lc($dbd_name) eq lc($d)) {
                $_dbd = $d;
                last;
            }
        }

        $self->Exception("Error DBD Driver : $dbd_name") unless $_dbd;
    }

    method _dsn_dbi ($dsn_str) {
        my ($dbi, $driver, $db_part, $host) = split ':', $dsn_str;

        $self->Exception("DSN DBI: $dbi") unless $dbi eq 'dbi';
        $self->Exception("DSN DataBase: $db_part") unless $db_part;

        $self->_Driver_dbd($driver);

        return $dsn_str;
    }

    method _check_dsn ($dsn_str) {
        return $self->_dsn_dbi($dsn_str) if $dsn_str =~ /^dbi/;
        return $self->_dsn_to_dbi($dsn_str);
    }

    method _make_dsn ($args) {
        $self->Exception("DSN Driver: Not defined") unless $args->{driver};

        $self->_Driver_dbd($args->{driver});

        return 'dbi:SQLite:dbname=' . $args->{db}
          if $args->{driver} eq 'SQLite';

        $self->Exception("DSN Host: Not defined") unless $args->{host};
        $self->Exception("DSN DB: Not defined")   unless $args->{db};

        return
            'dbi:'
          . $_dbd
          . ':database='
          . $args->{db} . ':'
          . $args->{host};
    }

    method _dsn_to_dbi ($dsn_str) {
        my $URI;

        # SQLite
        if ($dsn_str =~ /^sqlite:\/\/\/(.*)$/) {
            $_dbd = 'SQLite';
            return 'dbi:SQLite:dbname=' . $1;
        }

        ($URI->{schema}, $URI->{UI}, $URI->{connect}, $URI->{db}) =
          $dsn_str =~ m{^([^:]+)://([^@]+)@([^/]+)/(.+)$};

        $self->Exception("_dsn_to_dbi : schema") unless $URI->{schema};

        $self->_Driver_dbd($URI->{schema});
        $self->Exception("_dsn_to_dbi : connect") unless $URI->{connect};

        $URI->{connect} =~ /:/
          ? ($URI->{host}, $URI->{port}) = split ':', $URI->{connect}
          : $URI->{host} = $URI->{connect};

        # UserInfo
        if ($URI->{UI} =~ /:/) {
            ($URI->{user}, $URI->{password}) = split ':', $URI->{UI};

            $_args->{Auth}->{user}     = $URI->{user};
            $_args->{Auth}->{password} = $URI->{password};
        }
        else {
            $URI->{user} = $URI->{UI};
        }

        $self->Exception('_dsn_to_dbi : No DB value') unless $URI->{db};

        if ($URI->{db} =~ s/^(.*)\?(.*)$/$1/) {
            ($URI->{attribute}, $URI->{value}) = split '=', $2;
        }

        if    ($dsn_str =~ /^(postgres|postgresql):/) { $_dbd = 'Pg'      }
        elsif ($dsn_str =~ /^(mariadb):/)             { $_dbd = 'MariaDB' }
        elsif ($dsn_str =~ /^(mysql|mysqlx):/)        { $_dbd = 'mysql'   }
        else  { $self->Exception("_dsn_to_dbi : $dsn_str") }

        $URI->{DSN} = sprintf('dbi:%s:dbname=%s;host=%s%s',
            $_dbd, $URI->{db}, $URI->{host},
            $URI->{port} ? ";port=$URI->{port}" : ''
        );

        return $URI->{DSN};
    }

    method _profile ($stat) {
        $stat .= "/DBI::ProfileDumper/";
        $stat .= qq{File:dbix-fast-$$.log};

        $db->dbh->{Profile} = $stat;
    }

    # Security: validate SQL identifier (table/column names)
    method _safe_id ($name) {
        $self->Exception("Invalid identifier")
          unless defined $name && $name =~ /^[a-zA-Z_][a-zA-Z0-9_.]*$/;
        return $name;
    }

    # Profiling helper - wraps execution with timing when tracker is active
    method _track ($code) {
        if ($_query_tracker) {
            my $t0  = Time::HiRes::time();
            my $res = $code->();
            $_query_tracker->add_query($sql, $p // [], $t0, Time::HiRes::time());
            $last_sql = $sql;
            return $res;
        }
        $last_sql = $sql;
        return $code->();
    }

    # Query methods

    method q ($stmt, @params) {
        $sql = $stmt;
        $p   = \@params;
    }

    method all (@args) {
        $sql = shift @args;
        $p   = \@args;

        $results = $self->_track(sub {
            $db->dbh->selectall_arrayref($sql, { Slice => {} }, @{$p});
        });
        return $results;
    }

    method flat (@args) {
        $sql = shift @args;
        $p   = \@args;

        my @Flat;
        $self->_track(sub {
            my $sth = $db->dbh->prepare($sql);
            $sth->execute(@{$p});
            while (my $row = $sth->fetchrow_array) {
                push @Flat, $row;
            }
            1;
        });

        $results = \@Flat;
        return @Flat;
    }

    method hash (@args) {
        $sql = shift @args;
        $p   = \@args;

        $results = $self->_track(sub {
            my $sth = $db->dbh->prepare($sql);
            $sth->execute(@{$p});
            $sth->fetchrow_hashref;
        });
        return $results;
    }

    method val (@args) {
        $sql = shift @args;
        $p   = \@args;

        $results = $self->_track(sub {
            $db->dbh->selectrow_array($sql, undef, @{$p});
        });
        return $results;
    }

    method array (@args) {
        $sql = shift @args;
        $p   = \@args;

        my $ref = $self->_track(sub {
            $db->dbh->selectcol_arrayref($sql, undef, @{$p});
        });

        $results = $ref // [];
        return $results;
    }

    method count ($table_name, $skeel = undef) {
        my $table = $self->_safe_id($self->TableName($table_name));

        $sql = "SELECT COUNT(*) FROM $table";
        $p   = [];

        unless ($skeel) {
            $results = $self->_track(sub {
                $db->dbh->selectrow_array($sql);
            });
            return $results;
        }

        $self->_make_where($skeel);

        $results = $self->_track(sub {
            $db->dbh->selectrow_array($sql, undef, @{$p});
        });
        return $results;
    }

    method _make_where ($skeel) {
        state %VALID_OPS = map { $_ => 1 }
          qw(= != <> < <= > >= LIKE NOT BETWEEN IS);

        my @params;
        my @parts;

        for my $K (sort keys %{$skeel}) {
            $self->_safe_id($K);  # validate column name

            my $val = $skeel->{$K};
            my $op  = '=';

            if (ref $val eq 'HASH') {
                ($op) = keys %$val;
                $self->Exception("Invalid operator: $op")
                  unless $VALID_OPS{uc $op};
                $val = $val->{$op};
            }

            push @parts,  "$K $op ?";
            push @params, $val;
        }

        $sql .= ' WHERE ' . join(' AND ', @parts) if @parts;
        $p = \@params;
    }

    method exec ($stmt, @params) {
        $self->Exception("exec() : SQL statement required") unless $stmt;

        $sql = $stmt;
        $p   = \@params;

        my $sth = $db->dbh->prepare($stmt);

        $self->_track(sub {
            @params ? $sth->execute(@params) : $sth->execute();
            1;
        });

        if ($DBI::err) {
            $self->set_error($DBI::err, $DBI::errstr);
            return;
        }

        return $sth;
    }

    method execute ($stmt, $extra = undef, $type = 'arrayref') {
        $sql = $stmt;

        $self->make_sen($extra) if $extra;

        $results = $self->_track(sub {
            if ($type eq 'hash') {
                my $sth = $db->dbh->prepare($sql);
                $p ? $sth->execute(@{$p}) : $sth->execute;
                return $sth->fetchrow_hashref;
            }
            else {
                return $p
                  ? $db->dbh->selectall_arrayref($sql, { Slice => {} }, @{$p})
                  : $db->dbh->selectall_arrayref($sql, { Slice => {} });
            }
        });
    }

    # CRUD
    method insert ($table_name, $skeel, @extra) {
        my $table = $self->TableName($table_name);

        $skeel = $self->extra_args($skeel, @extra) if @extra;

        my ($stmt, @bind) = $Q->insert($table, $skeel);

        $sql = $stmt;
        $self->execute_prepare(@bind);

        if ($_dbd eq 'MariaDB') {
            $last_id = $db->dbh->{mariadb_insertid};
        }
        elsif ($_dbd eq 'mysql') {
            $last_id = $db->dbh->{mysql_insertid};
        }
        elsif ($_dbd eq 'SQLite') {
            $last_id = $db->dbh->sqlite_last_insert_rowid();
        }
        elsif ($_dbd eq 'Pg') {
            $last_id =
              $db->dbh->last_insert_id(undef, undef, $table, undef);
        }
    }

    method update ($table_name, $skeel, @extra) {
        my $table = $self->TableName($table_name);

        $skeel->{sen} = $self->extra_args($skeel->{sen}, @extra)
          if @extra;

        my ($stmt, @bind) =
          $Q->update($table, $skeel->{sen}, $skeel->{where});

        $sql = $stmt;
        $self->execute_prepare(@bind);
    }

    method up ($table_name, $data, $where, $time_col = undef) {
        if ($time_col) {
            $self->update($table_name,
                { sen => $data, where => $where }, time => $time_col);
        }
        else {
            $self->update($table_name,
                { sen => $data, where => $where });
        }
    }

    method delete ($table_name, $skeel) {
        my $table = $self->TableName($table_name);

        my ($stmt, @bind) = $Q->delete($table, $skeel);

        $sql = $stmt;
        $self->execute_prepare(@bind);
    }

    method extra_args ($skeel, %args) {
        $skeel->{ $args{time} } = $self->now() if $args{time};
        return $skeel;
    }

    # Named parameter methods

    method make_sen ($skeel) {
        my $stmt = $sql // '';
        my @params;

        while ($stmt =~ /:([A-Za-z_]\w*)/) {
            my $name = $1;
            my $val  = exists $skeel->{$name} ? $skeel->{$name} : undef;
            $stmt =~ s/\Q:$name\E/?/;
            push @params, $val;
        }

        $sql = $stmt;
        $p   = \@params;
    }

    # Execute helpers

    method execute_prepare (@params) {
        my $stmt = $sql // '';

        $self->Exception("execute_prepare(): SQL not set")
          unless length $stmt;

        my $dbh = $db && $db->dbh
          or $self->Exception("execute_prepare(): No DB handle");

        my $sth = $dbh->prepare_cached($stmt)
          or $self->Exception(
            "prepare() failed: " . ($dbh->errstr // 'unknown'));

        $p = \@params;

        $self->_track(sub {
            $sth->execute(@params)
              or $self->Exception(
                "execute() failed: " . ($sth->errstr // 'unknown'));
            1;
        });

        $last_sql = $stmt;

        return $sth;
    }

    # Validation

    method TableName ($table) {
        $self->Exception("Not defined table") unless $table;

        return $table unless $_args->{tn};

        $self->Exception("TableName not exist: $table")
          unless $self->schema->tables->{$table};

        return $table;
    }

    method Exception ($msg) {
        my $full = "Exception: $msg"
          . ($_last_error ? " - Last error: $_last_error" : "");

        if ($_args && !$_args->{DBI}->{RaiseError} && !$_args->{DBI}->{PrintError}) {
            return;  # Both off: silent
        }

        croak $full;
    }
}

1;

__END__

=pod

=head1 NAME

DBIx::Fast - DBI fast & easy

=head1 SYNOPSIS

    use DBIx::Fast;

    # Connect via DSN
    my $db = DBIx::Fast->new(
        dsn      => 'dbi:MariaDB:database=mydb:localhost',
        user     => 'root',
        password => 'secret',
    );

    # Connect via URI
    my $db = DBIx::Fast->new( dsn => 'mariadb://root:secret@localhost:3306/mydb' );

    # SQLite shortcut
    my $db = DBIx::Fast->new( SQLite => '/path/to/db.sqlite' );

    # Dependency injection
    my $db = DBIx::Fast->new( db => $connector, driver => 'SQLite' );

    # Queries
    $db->all('SELECT * FROM users WHERE active = ?', 1);
    my $rows = $db->results;

    my $user = $db->hash('SELECT * FROM users WHERE id = ?', $id);
    my $name = $db->val('SELECT name FROM users WHERE id = ?', $id);
    my @ids  = $db->flat('SELECT id FROM users');
    my $total = $db->count('users', { active => 1 });

    # CRUD
    $db->insert('users', { name => 'Alice', status => 1 }, time => 'created_at');
    $db->up('users', { name => 'Bob' }, { id => 1 });
    $db->up('users', { name => 'Bob' }, { id => 1 }, 'updated_at');
    $db->delete('users', { id => 1 });

    # Transactions
    $db->txn(sub {
        $db->insert('orders', { total => 100 });
        $db->insert('order_items', { order_id => $db->last_id, product => 'Widget' });
    });

    # Named parameters
    $db->execute('SELECT * FROM users WHERE name = :name', { name => 'Alice' });

=head1 DESCRIPTION

DBIx::Fast is a lightweight database abstraction layer built on top of
L<DBI>, L<DBIx::Connector>, and L<SQL::Abstract>. It provides fast, simple
access to SQLite, PostgreSQL, MariaDB, and MySQL databases with Object::Pad.

Requires Perl v5.38 or later.

=head1 CONSTRUCTOR

=head2 new

    my $db = DBIx::Fast->new(%args);

Accepted parameters:

=over 4

=item C<dsn> - DBI DSN string or URI (C<mariadb://user:pass@host:port/db>)

=item C<SQLite> - Path to SQLite database file (shortcut)

=item C<db> - Database name string or pre-built L<DBIx::Connector> object

=item C<driver> - Database driver: SQLite, Pg, MariaDB, mysql

=item C<user>, C<password>, C<host> - Connection credentials

=item C<RaiseError>, C<PrintError>, C<AutoCommit> - DBI attributes (defaults: 1, 0, 1)

=item C<tn> - Enable table name validation (default: 0)

=item C<abstract> - Enable SQL::Abstract (default: 1)

=item C<trace>, C<profile> - DBI tracing/profiling options

=back

=head1 ACCESSORS

=head2 db

L<DBIx::Connector> instance (read/write).

=head2 dbd

Database driver name: SQLite, Pg, MariaDB, or mysql (read-only).

=head2 dsn

Processed DSN string (read-only).

=head2 Q

L<SQL::Abstract> instance (read/write).

=head2 sql

Current SQL statement (read/write).

=head2 last_sql

Last executed SQL statement (read/write).

=head2 p

Current bind parameters arrayref (read/write).

=head2 results

Last query result (read/write).

=head2 last_id

Last insert ID (read/write).

=head2 errors

All errors as arrayref (read-only).

=head2 last_error

Last error message string (read-only).

=head2 args

Processed constructor configuration hashref (read-only).

=head1 QUERY METHODS

=head2 all

    $db->all('SELECT * FROM users WHERE id > ?', 10);
    my $rows = $db->results;  # arrayref of hashrefs

Executes SQL and stores all rows in C<results>.

=head2 hash

    $db->hash('SELECT * FROM users WHERE id = ?', 1);
    my $row = $db->results;  # hashref

Executes SQL and stores a single row in C<results>.

=head2 val

    my $name = $db->val('SELECT name FROM users WHERE id = ?', 1);

Executes SQL and returns a single scalar value.

=head2 flat

    my @names = $db->flat('SELECT name FROM users');

Executes SQL and returns a flat list of values.

=head2 array

    $db->array('SELECT name FROM users');
    my $names = $db->results;  # arrayref

Executes SQL and stores a single column as arrayref in C<results>.

=head2 count

    my $total = $db->count('users');
    my $active = $db->count('users', { status => 1 });

Returns row count, optionally filtered by WHERE conditions.

=head2 exec

    my $sth = $db->exec('CREATE TABLE foo (id INT)');
    my $sth = $db->exec('INSERT INTO foo VALUES (?)', 42);

Executes raw SQL with optional bind parameters. Records query in profiler
if initialized. Returns the statement handle.

=head2 execute

    $db->execute('SELECT * FROM users WHERE name = :name', { name => 'Alice' });
    $db->execute('SELECT * FROM users WHERE id = :id', { id => 1 }, 'hash');

Executes SQL with named parameter substitution (C<:name> syntax). Third
argument selects result type: C<arrayref> (default) or C<hash>.

=head1 CRUD METHODS

=head2 insert

    $db->insert('users', { name => 'Alice', status => 1 });
    $db->insert('users', { name => 'Alice' }, time => 'created_at');
    my $id = $db->last_id;

Inserts a row using L<SQL::Abstract>. Sets C<last_id> automatically based
on the database driver.

=head2 update

    $db->update('users', {
        sen   => { name => 'Bob', status => 1 },
        where => { id => 1 },
    });
    $db->update('users', {
        sen   => { name => 'Bob' },
        where => { id => 1 },
    }, time => 'updated_at');

Updates rows using L<SQL::Abstract>. Pass C<time =E<gt> 'column_name'> to
auto-set a timestamp column to C<now()>.

=head2 up

    $db->up('users', { name => 'Bob' }, { id => 1 });
    $db->up('users', { name => 'Bob' }, { id => 1 }, 'updated_at');

Shortcut for C<update>. Arguments: table, data hashref, where hashref,
optional time column name (positional).

=head2 delete

    $db->delete('users', { id => 1 });

Deletes rows using L<SQL::Abstract>.

=head1 SUBSYSTEMS

=head2 schema

    my $schema = $db->schema;

Returns the L<DBIx::Fast::Schema> instance (lazy-loaded) for table
introspection.

=head2 transaction

    my $tx = $db->transaction;

Returns the L<DBIx::Fast::Transaction> instance (lazy-loaded).

=head2 txn

    $db->txn(sub { ... });
    $db->txn(sub { ... }, { max_retries => 5 });

Shortcut for C<< $db->transaction->do(...) >>. Executes a code block inside
a transaction with automatic commit/rollback and deadlock retry.

=head2 profiler

    my $profiler = $db->profiler;

Returns the driver-specific profile instance (L<DBIx::Fast::Profile::MariaDB>,
L<DBIx::Fast::Profile::SQLite>, etc.) for native database diagnostics.
Lazy-loaded on first access.

=head2 tracker

    my $tracker = $db->tracker;

Returns the L<DBIx::Fast::Profiler> instance for query tracking. Once
activated, all queries executed through C<all>, C<hash>, C<val>, C<flat>,
C<array>, C<exec>, C<insert>, C<update>, C<up>, and C<delete> are recorded
with timing information.

    # Activate tracking
    $db->tracker;

    # Run some queries
    $db->all('SELECT * FROM users');
    $db->insert('logs', { action => 'login' });
    $db->up('users', { last_login => $db->now }, { id => 1 });

    # Get statistics
    my $stats = $db->tracker->get_stats;
    printf "Queries: %d, Total: %.4fs, Avg: %.4fs\n",
        $stats->{total_queries}, $stats->{total_time}, $stats->{avg_time};

    # Slow queries
    my $slow = $db->tracker->get_slow_queries(5);
    for my $q (@$slow) {
        printf "%.4fs - %s\n", $q->{duration}, $q->{sql};
    }

    # Stats by type (SELECT, INSERT, UPDATE, DELETE)
    my $by_type = $db->tracker->get_detailed_stats;

    # Print formatted report
    $db->tracker->print_stats;

    # Clear recorded queries
    $db->tracker->clear;

=head2 load_extension

    my $ext = $db->load_extension('Schema');

Dynamically loads and caches a C<DBIx::Fast::*> extension module.

=head1 UTILITY METHODS

=head2 now

Returns the current timestamp in MySQL format (C<YYYY-MM-DD HH:MM:SS>).

=head2 set_error

    $db->set_error($code, $message);

Appends an error to the C<errors> array and updates C<last_error>.

=head2 make_sen

    $db->sql('SELECT * FROM users WHERE name = :name AND age = :age');
    $db->make_sen({ name => 'Alice', age => 30 });
    # $db->sql is now 'SELECT * FROM users WHERE name = ? AND age = ?'
    # $db->p is ['Alice', 30]

Replaces named placeholders (C<:name>) with C<?> in order of appearance
in the SQL string. Supports duplicate placeholders.

=head2 q

    $db->q('SELECT * FROM users WHERE id = ?', 1);

Sets C<sql> and C<p> (bind parameters) for subsequent use.

=head2 execute_prepare

    $db->sql('INSERT INTO users (name) VALUES (?)');
    $db->execute_prepare('Alice');

Prepares and executes the current C<sql> with bind parameters.

=head2 TableName

    my $table = $db->TableName('users');

Validates a table name. When C<tn =E<gt> 1> is set, checks that the table
exists in the schema cache.

=head2 Exception

    $db->Exception("Something went wrong");

Throws an exception via C<croak>, respecting C<RaiseError> and C<PrintError>
settings.

=head1 SEE ALSO

L<DBI>, L<DBIx::Connector>, L<SQL::Abstract>, L<Object::Pad>

=head1 AUTHOR

Harun Delgado E<lt>hdp@nurmol.comE<gt>

=head1 LICENSE AND COPYRIGHT

This is free software under the Artistic License 2.0.
L<http://www.perlfoundation.org/artistic_license_2_0>

=cut
