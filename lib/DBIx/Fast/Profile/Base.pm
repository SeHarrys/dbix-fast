package DBIx::Fast::Profile::Base;

use v5.38;
use Object::Pad 0.807;
use Carp qw(croak);
use Scalar::Util qw(weaken);

class DBIx::Fast::Profile::Base {
    field $dbix       :param :reader;
    field $enabled    :param :accessor = 1;
    field $slow_query :param :accessor = 1.0;

    ADJUST {
        croak "Missing required parameter 'dbix'" unless defined $dbix;
        weaken($dbix);
    }

    method add_query        { }
    method init             { croak "Not implemented" }
    method get_slow_queries { croak "Not implemented" }
    method get_stats        { croak "Not implemented" }
    method print_stats      { croak "Not implemented" }
}

1;

__END__

=head1 NAME

DBIx::Fast::Profile::Base - Abstract base class for database driver profiles

=head1 DESCRIPTION

Defines the interface that all driver-specific profile classes must implement.
Subclasses (e.g. L<DBIx::Fast::Profile::MariaDB>, L<DBIx::Fast::Profile::SQLite>)
override these methods to provide driver-native profiling and diagnostics.

=head1 METHODS

=head2 init

Initializes profiling for the specific database driver. Must be implemented by
subclasses.

=head2 add_query

Hook called when a query is executed. The base implementation is a no-op;
subclasses may override to record driver-level metrics.

=head2 get_slow_queries

Returns slow queries using driver-native facilities. Must be implemented by
subclasses.

=head2 get_stats

Returns driver-specific query and server statistics. Must be implemented by
subclasses.

=head2 print_stats

Prints a formatted report of driver-specific statistics. Must be implemented by
subclasses.

=head1 AUTHOR

Harun Delgado

=head1 LICENSE

This is free software under the Artistic License 2.0.

=cut
