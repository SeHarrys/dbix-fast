package DBIx::Fast::Base;

use v5.38;
use Object::Pad 0.807;
use Carp qw(croak);

class DBIx::Fast::Base {
    field $dbix :param :reader;

    ADJUST {
        croak "DBIx::Fast instance required"
          unless ref($dbix) && ref($dbix) eq 'DBIx::Fast';
    }
}

1;

__END__

=head1 NAME

DBIx::Fast::Base - Base class for DBIx::Fast components

=head1 DESCRIPTION

Abstract base class that all DBIx::Fast submodules inherit from. It holds a
reference to the parent L<DBIx::Fast> instance and validates that the required
parameter is provided during construction.

=head1 METHODS

=head2 dbix

Accessor that returns the L<DBIx::Fast> instance passed at construction time.

=head1 AUTHOR

Harun Delgado

=head1 LICENSE

This is free software under the Artistic License 2.0.

=cut
