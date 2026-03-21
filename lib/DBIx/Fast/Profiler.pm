package DBIx::Fast::Profiler;

use v5.38;
use Object::Pad 0.807;
use Time::HiRes qw(time);
use JSON;
use Term::ANSIColor;

class DBIx::Fast::Profiler :isa(DBIx::Fast::Base) {
    field $auto_print  :param :accessor = 1;
    field $queries     :accessor        = [];
    field $enabled     :param :accessor = 1;
    field $slow_query  :param :accessor = 1.0;
    field $max_queries :param :accessor = 1000;

    method add_query ($sql, $params, $start_time, $end_time) {
        return unless $enabled;

        my $duration   = $end_time - $start_time;
        my $query_info = {
            sql      => $sql,
            params   => $params,
            start    => $start_time,
            end      => $end_time,
            duration => $duration,
            stack    => $self->_get_stack_trace(),
            time     => scalar( localtime($start_time) )
        };

        if ( @{$queries} >= $max_queries ) {
            shift @{$queries};
        }

        push @{$queries}, $query_info;

        $self->print_query($query_info) if $auto_print;
    }

    method print_query ($query_info) {
        my $duration_color =
            $query_info->{duration} >= $slow_query       ? 'red'
          : $query_info->{duration} >= ( $slow_query / 2 ) ? 'yellow'
          :                                                  'green';

        print "\n", "=" x 80, "\n";
        print color('bold blue'), "Query at ", $query_info->{time},
          color('reset'), "\n";

        print color('bold'), "Duration: ",
          color($duration_color),
          sprintf( "%.6fs", $query_info->{duration} ),
          color('reset'), "\n";

        print color('bold cyan'), "SQL: ", color('reset'),
          $self->_format_sql( $query_info->{sql} ), "\n";

        if ( @{ $query_info->{params} } ) {
            print color('bold magenta'), "Params: ", color('reset'),
              encode_json( $query_info->{params} ), "\n";
        }

        if ( $query_info->{duration} >= $slow_query ) {
            print color('red'), "Stack Trace:\n", color('reset'),
              $query_info->{stack}, "\n";
        }
    }

    method _format_sql ($sql) {
        my @keywords =
          qw(SELECT FROM WHERE INSERT UPDATE DELETE JOIN ON GROUP BY HAVING ORDER LIMIT);

        for my $keyword (@keywords) {
            $sql =~ s/\b$keyword\b/\n$keyword/g;
        }

        return $sql;
    }

    method get_detailed_stats () {
        my %stats;
        for my $query ( @{$queries} ) {
            my $type = $self->_get_query_type( $query->{sql} );

            $stats{$type}->{count}++;
            $stats{$type}->{total_time} += $query->{duration};
            $stats{$type}->{avg_time} =
              $stats{$type}->{total_time} / $stats{$type}->{count};

            if (  !defined $stats{$type}->{min_time}
                || $query->{duration} < $stats{$type}->{min_time} )
            {
                $stats{$type}->{min_time} = $query->{duration};
            }

            if (  !defined $stats{$type}->{max_time}
                || $query->{duration} > $stats{$type}->{max_time} )
            {
                $stats{$type}->{max_time} = $query->{duration};
            }
        }

        return \%stats;
    }

    method _get_query_type ($sql) {
        return 'SELECT' if $sql =~ /^\s*SELECT/i;
        return 'INSERT' if $sql =~ /^\s*INSERT/i;
        return 'UPDATE' if $sql =~ /^\s*UPDATE/i;
        return 'DELETE' if $sql =~ /^\s*DELETE/i;
        return 'CREATE' if $sql =~ /^\s*CREATE/i;
        return 'ALTER'  if $sql =~ /^\s*ALTER/i;
        return 'DROP'   if $sql =~ /^\s*DROP/i;
        return 'OTHER';
    }

    method print_summary () {
        my $stats = $self->get_detailed_stats();

        print "\n", "=" x 80, "\n";
        print color('bold'), "Query Statistics Summary\n", color('reset');
        print "=" x 80, "\n";

        for my $type ( sort keys %$stats ) {
            print color('bold blue'), "\n$type Queries:\n", color('reset');
            printf( "  Count: %d\n",        $stats->{$type}->{count} );
            printf( "  Total Time: %.6fs\n", $stats->{$type}->{total_time} );
            printf( "  Avg Time: %.6fs\n",   $stats->{$type}->{avg_time} );
            printf( "  Min Time: %.6fs\n",   $stats->{$type}->{min_time} );
            printf( "  Max Time: %.6fs\n",   $stats->{$type}->{max_time} );
        }
    }

    method _get_stack_trace () {
        my $trace = "";
        my $i     = 0;

        while ( my @caller = caller( $i++ ) ) {
            next if $caller[0] =~ /^DBIx::Fast/;
            $trace .= sprintf( "%s line %d\n", $caller[1], $caller[2] );
        }

        return $trace;
    }

    method get_stats () {
        my $stats = {
            total_queries     => 0,
            total_time        => 0,
            avg_time          => 0,
            min_time          => undef,
            max_time          => 0,
            slow_queries      => 0,
            query_types       => {},
            last_query_time   => 0,
            queries_per_second => 0
        };

        return $stats unless @{$queries};

        my $first_query_time = $queries->[0]->{start};
        my $last_query_time  = $queries->[-1]->{end};

        for my $query ( @{$queries} ) {
            $stats->{total_queries}++;
            $stats->{total_time} += $query->{duration};

            if ( !defined $stats->{min_time}
                || $query->{duration} < $stats->{min_time} )
            {
                $stats->{min_time} = $query->{duration};
            }

            if ( $query->{duration} > $stats->{max_time} ) {
                $stats->{max_time} = $query->{duration};
            }

            $stats->{slow_queries}++ if $query->{duration} > $slow_query;

            my $type = $self->_get_query_type( $query->{sql} );
            $stats->{query_types}->{$type} ||= {
                count      => 0,
                total_time => 0,
                min_time   => undef,
                max_time   => 0,
                avg_time   => 0
            };

            my $type_stats = $stats->{query_types}->{$type};
            $type_stats->{count}++;
            $type_stats->{total_time} += $query->{duration};

            if ( !defined $type_stats->{min_time}
                || $query->{duration} < $type_stats->{min_time} )
            {
                $type_stats->{min_time} = $query->{duration};
            }

            if ( $query->{duration} > $type_stats->{max_time} ) {
                $type_stats->{max_time} = $query->{duration};
            }

            $type_stats->{avg_time} =
              $type_stats->{total_time} / $type_stats->{count};
        }

        $stats->{avg_time} = $stats->{total_time} / $stats->{total_queries};

        my $total_elapsed = $last_query_time - $first_query_time;
        if ( $total_elapsed > 0 ) {
            $stats->{queries_per_second} =
              $stats->{total_queries} / $total_elapsed;
        }

        $stats->{last_query_time} = $last_query_time;

        $stats->{slow_query_percentage} =
          ( $stats->{slow_queries} / $stats->{total_queries} ) * 100;

        return $stats;
    }

    method print_stats () {
        my $stats = $self->get_stats();

        print "\n", "=" x 80, "\n";
        print color('bold'), "Query Statistics\n", color('reset');
        print "=" x 80, "\n\n";

        printf "Total Queries: %d\n",  $stats->{total_queries};
        printf "Total Time: %.4fs\n",  $stats->{total_time};
        printf "Average Time: %.4fs\n", $stats->{avg_time};
        printf "Min Time: %.4fs\n",     $stats->{min_time};
        printf "Max Time: %.4fs\n",     $stats->{max_time};
        printf "Slow Queries: %d (%.2f%%)\n",
          $stats->{slow_queries},
          $stats->{slow_query_percentage};
        printf "Queries/second: %.2f\n", $stats->{queries_per_second};

        print "\nBy Query Type:\n";
        print "-" x 40, "\n";

        for my $type ( sort keys %{ $stats->{query_types} } ) {
            my $type_stats = $stats->{query_types}->{$type};
            print color('bold blue'), "\n$type:\n", color('reset');
            printf "  Count: %d\n",        $type_stats->{count};
            printf "  Total Time: %.4fs\n", $type_stats->{total_time};
            printf "  Avg Time: %.4fs\n",   $type_stats->{avg_time};
            printf "  Min Time: %.4fs\n",   $type_stats->{min_time};
            printf "  Max Time: %.4fs\n",   $type_stats->{max_time};
        }
    }

    method get_slow_queries ($limit = 10) {
        my @sorted =
          sort { $b->{duration} <=> $a->{duration} } @{$queries};

        $limit = scalar @sorted if $limit > scalar @sorted;
        return [ @sorted[ 0 .. ( $limit - 1 ) ] ];
    }

    method clear () { $queries = [] }
}

1;

__END__

=head1 NAME

DBIx::Fast::Profiler - Query profiling and statistics for DBIx::Fast

=head1 DESCRIPTION

Records and analyzes SQL query execution times, providing detailed statistics,
slow query detection, and colored terminal output. Queries are stored in a
circular buffer controlled by C<max_queries>.

=head1 METHODS

=head2 add_query

    $profiler->add_query($sql, \@params, $start_time, $end_time);

Records a query execution with its SQL, bind parameters, and timing. Automatically
prints the query if C<auto_print> is enabled.

=head2 print_query

    $profiler->print_query(\%query_info);

Prints a single query's details to STDOUT with color-coded duration (green,
yellow, or red). Includes a stack trace for slow queries.

=head2 print_summary

Prints a summary of query statistics grouped by query type (SELECT, INSERT, etc.)
with count, total time, average, min, and max for each type.

=head2 print_stats

Prints comprehensive query statistics including totals, averages, slow query
percentage, queries per second, and a per-type breakdown.

=head2 get_stats

    my $stats = $profiler->get_stats();

Returns a hashref with aggregate statistics: total_queries, total_time,
avg_time, min_time, max_time, slow_queries, slow_query_percentage,
queries_per_second, and query_types breakdown.

=head2 get_detailed_stats

    my $stats = $profiler->get_detailed_stats();

Returns a hashref keyed by query type with count, total_time, avg_time,
min_time, and max_time for each type.

=head2 get_slow_queries

    my $slow = $profiler->get_slow_queries($limit);

Returns an arrayref of the top C<$limit> (default 10) slowest queries, sorted
by duration descending.

=head2 clear

Clears all recorded queries from the profiler buffer.

=head1 AUTHOR

Harun Delgado

=head1 LICENSE

This is free software under the Artistic License 2.0.

=cut
