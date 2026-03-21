package DBIx::Fast::Profile::MariaDB;

use v5.38;
use Object::Pad 0.807;
use Time::HiRes qw(time);

class DBIx::Fast::Profile::MariaDB :isa(DBIx::Fast::Profile::Base) {

    method init () {
        $self->dbix->exec('SET profiling = 1');
        $self->dbix->exec('SET profiling_history_size = 100');
        eval { $self->dbix->exec('SET session profiling_use_getrusage = 1') };
    }

    method get_slow_queries () {
        my $queries = $self->dbix->all(q{
            SELECT
                query_id,
                SUM(duration) as total_time,
                query as sql_text,
                COUNT(*) as stages
            FROM information_schema.profiling
            GROUP BY query_id, query
            HAVING total_time > ?
            ORDER BY total_time DESC
        }, $self->slow_query);

        return $queries;
    }

    method get_query_profile ($query_id) {
        return $self->dbix->all(q{
            SELECT
                state,
                duration,
                cpu_user,
                cpu_system,
                context_voluntary,
                context_involuntary,
                block_ops_in,
                block_ops_out,
                messages_sent,
                messages_received,
                page_faults_major,
                page_faults_minor,
                swaps,
                source_function,
                source_file,
                source_line
            FROM information_schema.profiling
            WHERE query_id = ?
            ORDER BY seq
        }, $query_id);
    }

    method get_stats () {
        my $stats = {};

        my $global = $self->dbix->all(q{
            SHOW GLOBAL STATUS WHERE Variable_name IN (
                'Questions',
                'Slow_queries',
                'Com_select',
                'Com_insert',
                'Com_update',
                'Com_delete',
                'Created_tmp_tables',
                'Created_tmp_disk_tables',
                'Select_full_join',
                'Select_full_range_join',
                'Select_range',
                'Select_range_check',
                'Select_scan',
                'Sort_merge_passes',
                'Sort_range',
                'Sort_rows',
                'Sort_scan'
            )
        });

        $stats->{global} =
          { map { $_->{Variable_name} => $_->{Value} } @$global };

        my $session = $self->dbix->hash(q{
            SELECT
                COUNT(*) as total_queries,
                SUM(CASE WHEN command = 'Query' THEN 1 ELSE 0 END) as query_count,
                SUM(CASE WHEN command = 'Sleep' THEN 1 ELSE 0 END) as sleep_count
            FROM information_schema.processlist
            WHERE id = CONNECTION_ID()
        });

        $stats->{session} = $session;

        return $stats;
    }

    method print_stats () {
        my $stats = $self->get_stats();

        print "\n=== MariaDB Query Statistics ===\n";
        print "\nGlobal Statistics:\n";
        printf "Questions: %d\n",      $stats->{global}->{Questions};
        printf "Slow Queries: %d\n",   $stats->{global}->{Slow_queries};
        printf "SELECT queries: %d\n", $stats->{global}->{Com_select};
        printf "INSERT queries: %d\n", $stats->{global}->{Com_insert};
        printf "UPDATE queries: %d\n", $stats->{global}->{Com_update};
        printf "DELETE queries: %d\n", $stats->{global}->{Com_delete};

        print "\nOptimization Statistics:\n";
        printf "Temp tables: %d (disk: %d)\n",
          $stats->{global}->{Created_tmp_tables},
          $stats->{global}->{Created_tmp_disk_tables};
        printf "Full table scans: %d\n", $stats->{global}->{Select_scan};
        printf "Range queries: %d\n",    $stats->{global}->{Select_range};
        printf "Sort merges: %d\n", $stats->{global}->{Sort_merge_passes};

        print "\nSession Statistics:\n";
        printf "Total Queries: %d\n", $stats->{session}->{total_queries} // 0;
        printf "Query Count: %d\n",   $stats->{session}->{query_count} // 0;
        printf "Sleep Count: %d\n",   $stats->{session}->{sleep_count} // 0;
    }

    method explain_query ($sql, @params) {
        return $self->dbix->all( "EXPLAIN EXTENDED $sql", @params );
    }

    method get_table_stats ($table) {
        return $self->dbix->all(q{
            SELECT
                table_name,
                engine,
                table_rows,
                avg_row_length,
                data_length,
                index_length
            FROM information_schema.tables
            WHERE table_schema = DATABASE()
            AND table_name = ?
        }, $table);
    }

    method get_index_stats ($table) {
        return $self->dbix->all(q{
            SELECT
                index_name,
                column_name,
                seq_in_index,
                cardinality
            FROM information_schema.statistics
            WHERE table_schema = DATABASE()
            AND table_name = ?
            ORDER BY index_name, seq_in_index
        }, $table);
    }

    method analyze_indexes ($table) {
        my $stats = {
            table           => $table,
            indexes         => {},
            problems        => [],
            recommendations => []
        };

        my $indexes = $self->dbix->all(q{
            SELECT
                index_name,
                GROUP_CONCAT(column_name ORDER BY seq_in_index) as columns,
                index_type,
                non_unique,
                cardinality,
                nullable,
                GROUP_CONCAT(seq_in_index) as column_positions
            FROM information_schema.statistics
            WHERE table_schema = DATABASE()
            AND table_name = ?
            GROUP BY index_name
            ORDER BY index_name, seq_in_index
        }, $table);

        for my $index (@$indexes) {
            $stats->{indexes}->{ $index->{index_name} } = $index;
        }

        my $index_usage = $self->dbix->all(q{
            SELECT
                index_name,
                count_star as uses,
                count_read as reads,
                count_write as writes,
                count_fetch as fetches
            FROM performance_schema.table_io_waits_summary_by_index_usage
            WHERE object_schema = DATABASE()
            AND object_name = ?
        }, $table);

        for my $usage (@$index_usage) {
            $stats->{indexes}->{ $usage->{index_name} }->{usage} = $usage;
        }

        $self->_analyze_index_problems($stats);
        $self->_generate_index_recommendations($stats);

        return $stats;
    }

    method _analyze_index_problems ($stats) {
        for my $index_name ( keys %{ $stats->{indexes} } ) {
            my $index = $stats->{indexes}->{$index_name};
            my $usage = $index->{usage} || {};

            if ( !$usage->{uses} && $index_name ne 'PRIMARY' ) {
                push @{ $stats->{problems} },
                  {
                    type    => 'unused_index',
                    index   => $index_name,
                    message => "Index '$index_name' has never been used"
                  };
            }

            if ( $usage->{uses} && $usage->{uses} < 10
                && $index_name ne 'PRIMARY' )
            {
                push @{ $stats->{problems} },
                  {
                    type  => 'rarely_used_index',
                    index => $index_name,
                    message =>
                      "Index '$index_name' is rarely used (only $usage->{uses} times)"
                  };
            }

            if ( $index->{cardinality} && $index->{cardinality} < 10 ) {
                push @{ $stats->{problems} },
                  {
                    type  => 'low_cardinality',
                    index => $index_name,
                    message =>
                      "Index '$index_name' has very low cardinality ($index->{cardinality})"
                  };
            }
        }

        $self->_check_redundant_indexes($stats);
    }

    method _check_redundant_indexes ($stats) {
        my %column_sets;
        for my $index_name ( keys %{ $stats->{indexes} } ) {
            my $index   = $stats->{indexes}->{$index_name};
            my @columns = split /,/, $index->{columns};

            my $column_key = join( ",", sort @columns );

            if ( $column_sets{$column_key} ) {
                push @{ $stats->{problems} },
                  {
                    type         => 'redundant_index',
                    index        => $index_name,
                    duplicate_of => $column_sets{$column_key},
                    message =>
                      "Index '$index_name' is redundant with '$column_sets{$column_key}'"
                  };
            }
            $column_sets{$column_key} = $index_name;
        }
    }

    method _generate_index_recommendations ($stats) {
        my $frequent_queries = $self->dbix->all(q{
            SELECT
                sql_text,
                count_star as executions,
                sum_timer_wait/1000000000000 as total_latency
            FROM performance_schema.events_statements_summary_by_digest
            WHERE schema_name = DATABASE()
            AND sql_text LIKE ?
            ORDER BY count_star DESC
            LIMIT 10
        }, '%' . $stats->{table} . '%');

        for my $query (@$frequent_queries) {
            my $explained = eval {
                $self->dbix->all("EXPLAIN " . $query->{sql_text});
            };
            next unless $explained && @$explained;

            my $rows = $explained->[0]->{rows} // 0;
            if ( $rows > 1000 ) {
                push @{ $stats->{recommendations} },
                  {
                    type  => 'missing_index',
                    query => $query->{sql_text},
                    rows  => $rows,
                    message =>
                      "Consider adding an index for query executed $query->{executions} times (examines $rows rows)"
                  };
            }
        }
    }

    method print_index_analysis ($table) {
        my $stats = $self->analyze_indexes($table);

        print "\n=== Index Analysis for table '$table' ===\n\n";

        print "Current Indexes:\n";
        print "-" x 80, "\n";
        for my $index_name ( sort keys %{ $stats->{indexes} } ) {
            my $index = $stats->{indexes}->{$index_name};
            my $usage = $index->{usage} || {};

            printf "Index: %s\n",       $index_name;
            printf "  Columns: %s\n",   $index->{columns};
            printf "  Type: %s\n",      $index->{index_type};
            printf "  Cardinality: %s\n", $index->{cardinality} || 'N/A';
            printf "  Usage:\n";
            printf "    Total uses: %d\n", $usage->{uses}    || 0;
            printf "    Reads: %d\n",      $usage->{reads}   || 0;
            printf "    Writes: %d\n",     $usage->{writes}  || 0;
            printf "    Fetches: %d\n",    $usage->{fetches} || 0;
            print "\n";
        }

        if ( @{ $stats->{problems} } ) {
            print "Problems Found:\n";
            print "-" x 80, "\n";
            for my $problem ( @{ $stats->{problems} } ) {
                printf "* %s\n", $problem->{message};
            }
            print "\n";
        }

        if ( @{ $stats->{recommendations} } ) {
            print "Recommendations:\n";
            print "-" x 80, "\n";
            for my $rec ( @{ $stats->{recommendations} } ) {
                printf "* %s\n", $rec->{message};
                printf "  Query: %s\n", $rec->{query} if $rec->{query};
            }
        }
    }

    method get_index_metrics ($table) {
        return $self->dbix->all(q{
            SELECT
                object_name as table_name,
                index_name,
                count_star as uses,
                count_read as reads,
                count_write as writes,
                count_fetch as fetches,
                sum_timer_wait/1000000000000 as total_latency,
                avg_timer_wait/1000000000000 as avg_latency
            FROM performance_schema.table_io_waits_summary_by_index_usage
            WHERE object_schema = DATABASE()
            AND object_name = ?
            ORDER BY sum_timer_wait DESC
        }, $table);
    }

    method monitor_connections () {
        my $stats = {
            current   => $self->get_current_connections(),
            processes => $self->get_processes(),
            variables => $self->get_connection_variables(),
            status    => $self->get_connection_status(),
            usage     => $self->get_connection_usage(),
            problems  => [],
        };

        $self->_analyze_connection_problems($stats);

        return $stats;
    }

    method get_current_connections () {
        return $self->dbix->hash(q{
            SELECT
                COUNT(*) as total_connections,
                SUM(CASE WHEN command = 'Sleep' THEN 1 ELSE 0 END) as sleeping,
                SUM(CASE WHEN command != 'Sleep' THEN 1 ELSE 0 END) as active,
                MAX(time) as max_connection_time
            FROM information_schema.processlist
        });
    }

    method get_processes () {
        return $self->dbix->all(q{
            SELECT
                id,
                user,
                host,
                db,
                command,
                time,
                state,
                info as query,
                TIME_TO_SEC(TIMEDIFF(NOW(), time_ms)) as seconds_running
            FROM information_schema.processlist
            ORDER BY time DESC
        });
    }

    method get_connection_variables () {
        my $vars = $self->dbix->all(q{
            SHOW VARIABLES WHERE Variable_name IN (
                'max_connections',
                'max_user_connections',
                'wait_timeout',
                'interactive_timeout',
                'connect_timeout',
                'max_allowed_packet',
                'thread_cache_size',
                'thread_stack'
            )
        });
        return { map { $_->{Variable_name} => $_->{Value} } @$vars };
    }

    method get_connection_status () {
        my $status = $self->dbix->all(q{
            SHOW GLOBAL STATUS WHERE Variable_name IN (
                'Threads_connected',
                'Threads_created',
                'Threads_cached',
                'Threads_running',
                'Connections',
                'Aborted_connects',
                'Aborted_clients',
                'Connection_errors_accept',
                'Connection_errors_internal',
                'Connection_errors_max_connections',
                'Connection_errors_peer_address',
                'Connection_errors_select',
                'Connection_errors_tcpwrap'
            )
        });

        return { map { $_->{Variable_name} => $_->{Value} } @$status };
    }

    method get_connection_usage () {
        return $self->dbix->all(q{
            SELECT
                user as username,
                COUNT(*) as total_connections,
                SUM(CASE WHEN command = 'Sleep' THEN 1 ELSE 0 END) as sleeping,
                SUM(CASE WHEN command != 'Sleep' THEN 1 ELSE 0 END) as active,
                MAX(time) as max_time
            FROM information_schema.processlist
            GROUP BY user
        });
    }

    method _analyze_connection_problems ($stats) {
        my $max_conn     = $stats->{variables}->{max_connections} || 1;
        my $current_conn = $stats->{status}->{Threads_connected} || 0;
        my $usage_percent = ( $current_conn / $max_conn ) * 100;

        if ( $usage_percent > 80 ) {
            push @{ $stats->{problems} },
              {
                type     => 'high_connection_usage',
                message  => sprintf(
                    "High connection usage: %.2f%% (%d of %d)",
                    $usage_percent, $current_conn, $max_conn
                ),
                severity => 'warning'
              };
        }

        my $total_conns  = $stats->{status}->{Connections} || 1;
        my $aborted_rate =
          ($stats->{status}->{Aborted_connects} || 0)
          / $total_conns * 100;

        if ( $aborted_rate > 5 ) {
            push @{ $stats->{problems} },
              {
                type     => 'high_abort_rate',
                message  => sprintf( "High connection abort rate: %.2f%%",
                    $aborted_rate ),
                severity => 'error'
              };
        }

        if ( $stats->{current}->{sleeping} > 50 ) {
            push @{ $stats->{problems} },
              {
                type     => 'many_sleeping_connections',
                message  => sprintf(
                    "High number of sleeping connections: %d",
                    $stats->{current}->{sleeping}
                ),
                severity => 'warning'
              };
        }

        for my $error_type ( grep /^Connection_errors_/,
            keys %{ $stats->{status} } )
        {
            if ( $stats->{status}->{$error_type} > 0 ) {
                push @{ $stats->{problems} },
                  {
                    type     => 'connection_errors',
                    message  => sprintf( "%s: %d occurrences",
                        $error_type, $stats->{status}->{$error_type} ),
                    severity => 'error'
                  };
            }
        }
    }

    method print_connection_monitor () {
        my $stats = $self->monitor_connections();

        print "\n=== MariaDB Connection Monitor ===\n\n";

        print "Current Connections:\n";
        print "-" x 80, "\n";
        printf "Total: %d (Active: %d, Sleeping: %d)\n",
          $stats->{current}->{total_connections},
          $stats->{current}->{active},
          $stats->{current}->{sleeping};
        printf "Max Connection Time: %d seconds\n\n",
          $stats->{current}->{max_connection_time};

        print "Connection Settings:\n";
        print "-" x 80, "\n";
        for my $var ( sort keys %{ $stats->{variables} } ) {
            printf "%-25s: %s\n", $var, $stats->{variables}->{$var};
        }
        print "\n";

        print "Connection Status:\n";
        print "-" x 80, "\n";
        for my $var ( sort keys %{ $stats->{status} } ) {
            printf "%-30s: %s\n", $var, $stats->{status}->{$var};
        }
        print "\n";

        print "Connection Usage by User:\n";
        print "-" x 80, "\n";
        for my $user ( @{ $stats->{usage} } ) {
            printf "User: %s\n",               $user->{username};
            printf "  Total Connections: %d\n", $user->{total_connections};
            printf "  Active: %d\n",            $user->{active};
            printf "  Sleeping: %d\n",          $user->{sleeping};
            printf "  Max Time: %d seconds\n",  $user->{max_time};
            print "\n";
        }

        print "Active Processes:\n";
        print "-" x 80, "\n";
        for my $proc ( @{ $stats->{processes} } ) {
            next if $proc->{command} eq 'Sleep';
            printf "ID: %d\n",                    $proc->{id};
            printf "  User: %s\n",                $proc->{user};
            printf "  Host: %s\n",                $proc->{host};
            printf "  DB: %s\n",                  $proc->{db}    || 'None';
            printf "  State: %s\n",               $proc->{state} || 'None';
            printf "  Running Time: %d seconds\n", $proc->{seconds_running};
            if ( $proc->{query} ) {
                printf "  Query: %s\n",
                  substr( $proc->{query}, 0, 100 )
                  . ( length( $proc->{query} ) > 100 ? '...' : '' );
            }
            print "\n";
        }

        if ( @{ $stats->{problems} } ) {
            print "Problems Detected:\n";
            print "-" x 80, "\n";
            for my $problem ( @{ $stats->{problems} } ) {
                printf "[%s] %s\n",
                  uc( $problem->{severity} ),
                  $problem->{message};
            }
        }
    }

    method start_connection_monitor ($interval = 60, $duration = 3600) {
        my $start_time = time();
        my $end_time   = $start_time + $duration;

        while ( time() < $end_time ) {
            print "\033[2J\033[H";
            $self->print_connection_monitor();
            printf "\nMonitoring... (Press Ctrl+C to stop)\n";
            printf "Running for: %d seconds\n", ( time() - $start_time );
            sleep($interval);
        }
    }
}

1;

__END__

=head1 NAME

DBIx::Fast::Profile::MariaDB - MariaDB/MySQL profiling and diagnostics

=head1 DESCRIPTION

Provides MariaDB-native query profiling, index analysis, and connection
monitoring using C<information_schema> and C<performance_schema>. Extends
L<DBIx::Fast::Profile::Base>.

=head1 METHODS

=head2 init

Enables MariaDB session profiling (C<SET profiling = 1>) and configures
history size and resource usage tracking.

=head2 get_slow_queries

Returns queries from C<information_schema.profiling> whose total duration
exceeds the C<slow_query> threshold.

=head2 get_query_profile

    my $profile = $mariadb->get_query_profile($query_id);

Returns detailed stage-by-stage profiling data for a specific query ID,
including CPU, I/O, and memory metrics.

=head2 get_stats

Returns a hashref with C<global> server status counters and C<session>-level
query statistics for the current connection.

=head2 print_stats

Prints a formatted report of global and session query statistics.

=head2 explain_query

    my $plan = $mariadb->explain_query($sql, @params);

Runs C<EXPLAIN EXTENDED> on the given SQL and returns the execution plan.

=head2 get_table_stats

    my $stats = $mariadb->get_table_stats($table);

Returns table metadata from C<information_schema.tables> including engine,
row count, and data/index sizes.

=head2 get_index_stats

    my $stats = $mariadb->get_index_stats($table);

Returns index column details and cardinality from C<information_schema.statistics>.

=head2 analyze_indexes

    my $analysis = $mariadb->analyze_indexes($table);

Performs a comprehensive index analysis combining schema metadata with
C<performance_schema> usage data. Returns indexes, detected problems, and
optimization recommendations.

=head2 print_index_analysis

    $mariadb->print_index_analysis($table);

Prints a formatted index analysis report for the given table, including usage
stats, problems, and recommendations.

=head2 get_index_metrics

    my $metrics = $mariadb->get_index_metrics($table);

Returns per-index I/O wait metrics (reads, writes, fetches, latency) from
C<performance_schema>.

=head2 monitor_connections

    my $stats = $mariadb->monitor_connections();

Returns a comprehensive snapshot of current connections, processes, variables,
status counters, per-user usage, and detected problems.

=head2 print_connection_monitor

Prints a formatted connection monitoring report including active processes,
settings, status, and any detected problems.

=head2 start_connection_monitor

    $mariadb->start_connection_monitor($interval, $duration);

Runs a continuous connection monitor that refreshes every C<$interval> seconds
(default 60) for up to C<$duration> seconds (default 3600).

=head1 AUTHOR

Harun Delgado

=head1 LICENSE

This is free software under the Artistic License 2.0.

=cut
