package DBIx::Fast::Schema;

use v5.38;
use Object::Pad 0.807;

class DBIx::Fast::Schema :isa(DBIx::Fast::Base) {
    field $tables :reader = {};

    method _set_tables ($t) { $tables = $t }

    method _load_tables_name () {
        my $driver = $self->dbix->dbd;
        my $sql    = '';

        if ( $driver eq 'MariaDB' || $driver eq 'mysql' ) {
            $sql = 'SHOW TABLES';
        }
        elsif ( $driver eq 'SQLite' ) {
            $sql = "SELECT name FROM sqlite_master WHERE type='table'";
        }
        elsif ( $driver eq 'Pg' ) {
            $sql = "SELECT tablename as name FROM pg_catalog.pg_tables WHERE schemaname != 'pg_catalog' AND schemaname != 'information_schema'";
        }
        else {
            $self->dbix->Exception("Error driver - _load_tables_name");
        }

        my $table_list;

        for my $table ( @{ $self->dbix->array($sql) } ) {
            $table_list->{$table} = time();
        }

        $tables = $table_list;
    }

    method clear_cache () { $tables = {} }

    method get_indexes ($table) {
        $self->dbix->Exception("Table required") unless $table;

        my $driver = $self->dbix->dbd;
        my $qtable = $self->dbix->_safe_id($table);
        my $sql    = '';

        if ( $driver eq 'MariaDB' || $driver eq 'mysql' ) {
            $sql = "SHOW INDEX FROM $qtable";
        }
        elsif ( $driver eq 'Pg' ) {
            $sql = qq{
                SELECT
                    i.relname as index_name,
                    a.attname as column_name,
                    ix.indisunique as is_unique
                FROM
                    pg_class t,
                    pg_class i,
                    pg_index ix,
                    pg_attribute a
                WHERE
                    t.oid = ix.indrelid
                    AND i.oid = ix.indexrelid
                    AND a.attrelid = t.oid
                    AND a.attnum = ANY(ix.indkey)
                    AND t.relkind = 'r'
                    AND t.relname = ?
            };
        }
        elsif ( $driver eq 'SQLite' ) {
            $sql = "SELECT * FROM sqlite_master WHERE type='index' AND tbl_name=?";
        }

        my $sth = $self->dbix->db->dbh->prepare($sql);
        $sth->execute( $driver =~ /^(Pg|SQLite)$/ ? $table : () );

        return $sth->fetchall_arrayref( {} );
    }

    # Deprecated alias
    method get_indexs ($table) { return $self->get_indexes($table) }

    method primary_keys ($table) {
        $self->dbix->Exception("Table name required") unless $table;

        my $driver = $self->dbix->dbd;
        my $qtable = $self->dbix->_safe_id($table);
        my $sql    = '';

        if ( $driver eq 'MariaDB' || $driver eq 'mysql' ) {
            $sql = "SHOW KEYS FROM $qtable WHERE Key_name = 'PRIMARY'";
        }
        elsif ( $driver eq 'Pg' ) {
            $sql = qq{
                SELECT a.attname
                FROM   pg_index i
                JOIN   pg_attribute a ON a.attrelid = i.indrelid
                                    AND a.attnum = ANY(i.indkey)
                WHERE  i.indrelid = ?::regclass
                AND    i.indisprimary
            };
        }
        elsif ( $driver eq 'SQLite' ) {
            $sql = "PRAGMA table_info($qtable)";
        }

        my $sth = $self->dbix->db->dbh->prepare($sql);
        $sth->execute( $driver eq 'Pg' ? $table : () );

        my @keys;
        if ( $driver eq 'SQLite' ) {
            while ( my $row = $sth->fetchrow_hashref ) {
                push @keys, $row->{name} if $row->{pk};
            }
        }
        else {
            @keys = map { $_->{Column_name} || $_->{attname} }
              @{ $sth->fetchall_arrayref( {} ) };
        }

        return \@keys;
    }

    method table_info ($table = undef) {
        $self->dbix->Exception("Table name required") unless $table;

        my $driver = $self->dbix->dbd;
        my $qtable = $self->dbix->_safe_id($table);
        my $sql    = '';

        if ( $driver eq 'MariaDB' || $driver eq 'mysql' ) {
            $sql = "SHOW CREATE TABLE $qtable";
        }
        elsif ( $driver eq 'Pg' ) {
            $sql = qq{SELECT column_name, data_type, character_maximum_length FROM information_schema.columns WHERE table_name = ?};
        }
        elsif ( $driver eq 'SQLite' ) {
            $sql = "PRAGMA table_info($qtable)";
        }

        my @params;
        push @params, $table if $driver eq 'Pg';

        my $sth = $self->dbix->db->dbh->prepare($sql);
        $sth->execute(@params);

        return $sth->fetchall_arrayref( {} );
    }

    method table_size ($table) {
        $self->dbix->Exception("Table name required") unless $table;

        my $driver = $self->dbix->dbd;
        my $qtable = $self->dbix->_safe_id($table);
        my $sql    = '';
        my @params;

        if ( $driver eq 'MariaDB' || $driver eq 'mysql' ) {
            $sql = "SELECT table_rows as `rows`, data_length + index_length as size_bytes FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?";
            @params = ($table);
        }
        elsif ( $driver eq 'Pg' ) {
            $sql = q{SELECT reltuples::bigint as rows, pg_total_relation_size(?) as size_bytes FROM pg_class WHERE relname = ?};
            @params = ( $table, $table );
        }
        elsif ( $driver eq 'SQLite' ) {
            $sql = "SELECT count(*) as rows FROM $qtable";
        }

        my $sth = $self->dbix->db->dbh->prepare($sql);
        $sth->execute(@params);

        return $sth->fetchrow_hashref;
    }
}

1;

__END__

=head1 NAME

DBIx::Fast::Schema - Schema introspection for DBIx::Fast

=head1 DESCRIPTION

Provides database schema introspection capabilities including listing tables,
retrieving index information, primary keys, column details, and table size
statistics. Supports MariaDB/MySQL, PostgreSQL, and SQLite drivers.

=head1 METHODS

=head2 tables

Reader accessor that returns the cached hash of table names.

=head2 clear_cache

Clears the internal table name cache.

=head2 get_indexes

    my $indexes = $schema->get_indexes($table);

Returns an arrayref of hashrefs describing all indexes on the given table.

=head2 primary_keys

    my $keys = $schema->primary_keys($table);

Returns an arrayref of column names that form the primary key of the given table.

=head2 table_info

    my $info = $schema->table_info($table);

Returns an arrayref of hashrefs with column metadata (name, type, length) for
the given table.

=head2 table_size

    my $size = $schema->table_size($table);

Returns a hashref with C<rows> and C<size_bytes> for the given table.

=head1 AUTHOR

Harun Delgado

=head1 LICENSE

This is free software under the Artistic License 2.0.

=cut
