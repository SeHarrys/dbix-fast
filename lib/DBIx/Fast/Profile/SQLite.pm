package DBIx::Fast::Profile::SQLite;

use v5.38;
use Object::Pad 0.807;

class DBIx::Fast::Profile::SQLite :isa(DBIx::Fast::Profile::Base) {

    method init                  () {}
    method get_slow_queries      () {}
    method get_query_profile     () {}
    method get_stats             () {}
    method print_stats           () {}
    method explain_query         () {}
    method get_table_stats       () {}
    method get_index_stats       () {}
    method analyze_indexes       () {}
    method print_index_analysis  () {}
    method get_index_metrics     () {}
    method monitor_connections   () {}
    method get_current_connections () {}
    method get_processes         () {}
    method print_connection_monitor  () {}
    method start_connection_monitor  () {}
}

1;

__END__

=head1 NAME

DBIx::Fast::Profile::SQLite - SQLite profiling stub

=head1 DESCRIPTION

Stub implementation of L<DBIx::Fast::Profile::Base> for SQLite. All methods
are no-ops since SQLite does not expose native profiling or performance schema
facilities. This class exists so that the profiling interface can be used
uniformly regardless of the database driver.

=head1 METHODS

All public methods from L<DBIx::Fast::Profile::Base> are implemented as no-ops:
C<init>, C<get_slow_queries>, C<get_query_profile>, C<get_stats>,
C<print_stats>, C<explain_query>, C<get_table_stats>, C<get_index_stats>,
C<analyze_indexes>, C<print_index_analysis>, C<get_index_metrics>,
C<monitor_connections>, C<print_connection_monitor>, and
C<start_connection_monitor>.

=head1 AUTHOR

Harun Delgado

=head1 LICENSE

This is free software under the Artistic License 2.0.

=cut
