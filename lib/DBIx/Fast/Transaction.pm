package DBIx::Fast::Transaction;

use v5.38;
use Object::Pad 0.807;
use Time::HiRes qw(time);

use constant {
    DELAY   => 1,
    RETRIES => 3,
    SLOW    => 5
};

class DBIx::Fast::Transaction :isa(DBIx::Fast::Base) {
    field $level      :accessor = 0;
    field $savepoints :accessor = {};
    field $start_time :accessor = undef;
    field $stats      :accessor = {
        avg_duration   => 0,
        deadlock_count => 0,
        error_count    => 0,
        success_count  => 0,
        total_count    => 0,
        total_duration => 0,
        max_duration   => 0
    };

    method do ($code, $options = {}) {
        $self->dbix->Exception("Transaction code block required")
          unless ref $code eq 'CODE';

        my $max_retries = $options->{max_retries} // RETRIES;
        my $retry_delay = $options->{retry_delay} // DELAY;

        $start_time = time();
        $stats->{total_count}++;

        my $result;
        my $retries = 0;

        while ( $retries <= $max_retries ) {
            eval {
                $self->_begin_work if $level == 0;

                $level++;

                $result = $code->();

                $self->_commit if $level == 1;

                $level--;
                $self->_update_stats(1);
            };

            if ( my $error = $@ ) {
                if ( $error =~ /deadlock/i ) {
                    $stats->{deadlock_count}++;
                    if ( $retries < $max_retries ) {
                        $retries++;
                        sleep($retry_delay);
                        next;
                    }
                }

                # Rollback only at outermost level
                if ( $level == 1 ) {
                    eval { $self->_rollback() };
                }

                $level-- if $level > 0;
                $self->_update_stats(0);

                if ( $level == 0 ) {
                    $savepoints = {};
                }

                $self->dbix->set_error( 500, "Transaction failed: $error" );
                die $error;
            }
            last;
        }
        return $result;
    }

    method _begin_work () {
        eval {
            $self->dbix->db->dbh->begin_work;
        };

        if ($@) {
            $self->dbix->set_error( 500,
                "Could not begin transaction: $@" );
            die $@;
        }
    }

    method _commit () {
        eval {
            $self->dbix->db->dbh->commit;
        };
        if ($@) {
            $self->dbix->set_error( 500,
                "Could not commit transaction: $@" );
            die $@;
        }
    }

    method _rollback () {
        eval {
            $self->dbix->db->dbh->rollback;
        };

        if ($@) {
            $self->dbix->set_error( 500,
                "Could not rollback transaction: $@" );
            die $@;
        }
    }

    method savepoint ($name) {
        $self->dbix->Exception(
            "DBIx::Fast::Transaction - Savepoint name required")
          unless $name;
        $self->dbix->Exception(
            "DBIx::Fast::Transaction - Invalid savepoint name: $name")
          unless $name =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/;
        return unless $level > 0;

        $savepoints->{$name} = {
            level => $level,
            time  => time()
        };

        eval {
            $self->dbix->exec("SAVEPOINT $name");
        };
        if ($@) {
            delete $savepoints->{$name};
            $self->dbix->set_error( 500,
                "Could not create savepoint: $@" );
            die $@;
        }

        return 1;
    }

    method rollback_to ($name) {
        $self->dbix->Exception(
            "DBIx::Fast::Transaction - Savepoint name required")
          unless $name;
        $self->dbix->Exception(
            "DBIx::Fast::Transaction - Invalid savepoint name: $name")
          unless $name =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/;

        unless ( exists $savepoints->{$name} ) {
            $self->dbix->set_error( 500,
                "Savepoint '$name' does not exist" );
            return;
        }

        eval {
            $self->dbix->exec("ROLLBACK TO SAVEPOINT $name");
        };

        if ($@) {
            $self->dbix->set_error( 500,
                "Could not rollback to savepoint: $@" );
            die $@;
        }

        my $current_level = $savepoints->{$name}->{level};
        for my $sp ( keys %{$savepoints} ) {
            if ( $savepoints->{$sp}->{level} > $current_level ) {
                delete $savepoints->{$sp};
            }
        }

        return 1;
    }

    method _update_stats ($success) {
        my $duration = time() - $start_time;

        if ($success) {
            $stats->{success_count}++;
        }
        else {
            $stats->{error_count}++;
        }

        $stats->{total_duration} += $duration;
        $stats->{max_duration} = $duration
          if $duration > $stats->{max_duration};
        $stats->{avg_duration} =
          $stats->{total_duration} / $stats->{total_count};

        if ( $duration > SLOW ) {
            warn sprintf(
                "Slow transaction detected: %.2fs (threshold: %ds)",
                $duration, SLOW );
        }
    }

    method get_stats () { return $stats }

    method reset_stats () {
        $stats = {
            total_count    => 0,
            success_count  => 0,
            error_count    => 0,
            deadlock_count => 0,
            total_duration => 0,
            max_duration   => 0,
            avg_duration   => 0
        };
    }
}

1;

__END__

=head1 NAME

DBIx::Fast::Transaction - Transaction management for DBIx::Fast

=head1 DESCRIPTION

Manages database transactions with support for nested transactions, savepoints,
automatic deadlock retry, and performance statistics tracking. Transactions that
exceed the slow threshold (5 seconds) emit a warning.

=head1 METHODS

=head2 do

    my $result = $tx->do(sub { ... }, \%options);

Executes a code block inside a transaction. Supports nested calls, automatic
commit/rollback, and deadlock retry. Options: C<max_retries> (default 3),
C<retry_delay> (default 1 second).

=head2 savepoint

    $tx->savepoint('my_savepoint');

Creates a named savepoint within an active transaction.

=head2 rollback_to

    $tx->rollback_to('my_savepoint');

Rolls back to the named savepoint and removes any savepoints created after it.

=head2 get_stats

    my $stats = $tx->get_stats();

Returns a hashref with transaction statistics: total_count, success_count,
error_count, deadlock_count, total_duration, max_duration, and avg_duration.

=head2 reset_stats

Resets all transaction statistics counters to zero.

=head1 AUTHOR

Harun Delgado

=head1 LICENSE

This is free software under the Artistic License 2.0.

=cut
