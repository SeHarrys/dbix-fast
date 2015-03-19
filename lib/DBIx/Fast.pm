package DBIx::Fast;

use strict;
use warnings FATAL => 'all';

our $VERSION = '0.05';

use Moo;
use DBIx::Connector;
use DateTime::Format::MySQL;

has db  => ( is => 'rw' );
has sql => ( is => 'rw' );
has p   => ( is => 'rw' );
has last_id => ( is => 'rw');
has results => ( is => 'rw');
has errors => ( is => 'rw');
has dbd => ( is => 'rwp');

sub set_error {
    my $self = shift;
    my $error = {
	id => shift,
	error => shift
    };

    my $Errors = $self->errors;
    push @{$Errors} ,$error;

    $self->errors($Errors);
}

sub BUILD {
    my ($self,$args) = @_;
    my $dsn;

    my $dbi_args = {
	RaiseError => 0,
	PrintError => 0,
	AutoCommit => 1,
    };

    $args->{host} = '127.0.0.1' unless $args->{host};

    $args->{host} eq 'sqlite' ? $self->_set_dbd('sqlite') :
	$self->_set_dbd('mysql');

    if ( $self->dbd eq 'sqlite' ) {
	$dsn = 'dbi:SQLite:'.$args->{db};
	$self->db(DBIx::Connector->new( $dsn, $args->{user}, $args->{passwd},
					$dbi_args ));
    } else {
	$dsn= 'dbi:mysql:database='.$args->{db}.':'.$args->{host};

	$self->db(DBIx::Connector->new( $dsn, $args->{user}, $args->{passwd},
					$dbi_args ));

	$self->db->mode('ping');
    }

    $self->db->dbh->{HandleError} = sub {
	$self->set_error($DBI::err,$DBI::errstr);
    };

    $self->db->dbh->trace($args->{trace},'dbix-fast-trace') if $args->{trace};

    $self->profile($args->{profile}) if $args->{profile};
}

=head2 profile
    Save profile with the PID
=cut
sub profile {
    my $self = shift;
    my $stat = shift."/DBI::ProfileDumper/";

    $stat .= qq{File:dbix-fast-$$.prof};

    $self->db->dbh->{Profile} = $stat;
}

=head2 Compatibility
    scalar @_ > 1 ? $self->execute(@_,'arrayref') :
    $self->execute(@_,undef,'arrayref');
=cut
sub all {
    my $self = shift;

    $self->q(@_);

    my $res = $self->db->dbh->selectall_arrayref($self->sql,
						 { Slice => {} },@{$self->p});

    $self->results($res) unless $DBI::err;
}

sub hash {
    my $self = shift;

    $self->q(@_);

    my $sth = $self->db->dbh->prepare($self->sql);

    $sth->execute(@{$self->p});

    my $res = $sth->fetchrow_hashref;

    $self->results($res) unless $DBI::err;
}

=head2 val
    Return one value
=cut
sub val {
    my $self = shift;

    $self->q(@_);

    return $self->db->dbh->selectrow_array($self->sql, undef, @{$self->p});
}

=head2 array
    Return array
=cut
sub array {
    my $self = shift;

    $self->q(@_);

    my $sth = $self->db->dbh->prepare($self->sql);

    $sth->execute(@{$self->p});

    my @rows = @{ $self->db->dbh->selectcol_arrayref(
		     $self->sql, undef, @{ $self->p } ) };

    $self->results(\@rows) unless $DBI::err;
}

sub count {
    my $self  = shift;
    my $table = shift;
    my $skeel = shift;

    $self->sql("SELECT COUNT(*) FROM $table");

    unless ( $skeel ) {
	return $self->db->dbh->selectrow_array($self->sql);
    }

    $self->_make_where($skeel);

    return $self->db->dbh->selectrow_array($self->sql, undef, @{$self->p});
}

sub _make_where {
    my $self  = shift;
    my $skeel = shift;
    my @p;

    my $sql = " WHERE ";

    for my $K ( keys %{$skeel} ) {
	#my $key = each %{$skeel->{$K}};
	my $key = (keys %{$skeel->{$K}})[0];
	push @p,$skeel->{$K}->{$key};
	$sql .= qq{$K $key ? };
    }

    $sql =~ s/,$//;

    $self->sql($self->sql.$sql);
    $self->p(\@p);
}

sub execute {
    my $self = shift;
    my $sql  = shift;
    my $extra = shift;
    my $type  = shift // 'arrayref';
    my $res;

    $self->sql($sql);

    ## Extra Arguments
    $self->make_sen($extra) if $extra;

    if ( $type eq 'hash' ) {
	my $sth = $self->db->dbh->prepare($self->sql);
	if ( $self->p ) {
	    $sth->execute(@{$self->p});
	} else {
	    $sth->execute;
	}
	$res = $sth->fetchrow_hashref;
    } else {
	if ($self->p ) {
	    $res = $self->db->dbh->selectall_arrayref($self->sql,
						      { Slice => {} },@{$self->p});
	} else {
	    $res = $self->db->dbh->selectall_arrayref($self->sql,
						      { Slice => {} } );
	}
    }

    unless ( $DBI::err ) {
	$self->results($res);
    }

}

sub update {
    my $self  = shift;
    my $table = shift;
    my $skeel = shift;

    $skeel->{sen} = $self->extra_args($skeel->{sen},@_) if scalar @_ > 0;

    my @p;

    my $sql = "UPDATE $table SET ";

    for ( keys %{$skeel->{sen}} ) {
	push @p,$skeel->{sen}->{$_};
	$sql .= $_.' = ? ,';
    }

    $sql =~ s/,$//;
    $sql .= 'WHERE ';

    for my $K ( keys %{$skeel->{where}} ) {
	push @p,$skeel->{where}->{$K};
	$sql .= $K.' = ? ,';
    }

    $sql =~ s/,$//;

    $self->sql($sql);
    $self->execute_prepare(@p);
}

sub insert {
    my $self = shift;
    my $table = shift;
    my $skeel = shift;

    $skeel = $self->extra_args($skeel,@_) if scalar @_ > 0;

    my @p;

    my $sql= "INSERT INTO $table ( ";

    for ( keys %{$skeel} ) {
       push @p,$skeel->{$_};
       $sql .= $_.',';
    }

    $sql =~ s/,$/ )/;
    $sql .= ' VALUES ( '.join(',', ('?') x @p).' )';

    $self->sql($sql);
    $self->execute_prepare(@p);

    if ( $self->dbd eq 'mysql' ) {
	$self->last_id($self->db->dbh->{mysql_insertid});
    } elsif ( $self->dbd eq 'sqlite' ) {
	$self->last_id($self->db->dbh->sqlite_last_insert_rowid());
    }

}

sub delete {
    my $self = shift;
    my $table = shift;
    my $skeel = shift;

    $self->sql("DELETE FROM $table");

    #unless ( $skeel ) {
    #    return $self->db->dbh->selectrow_array($self->sql);
    #}

    $self->_make_where($skeel);

    my $sth = $self->db->dbh->prepare($self->sql);
    $sth->execute(@{$self->p});
}

=head2 function
    Extra Args :

    time : NOW()
=cut
sub extra_args {
    my $self  = shift;
    my $skeel = shift;
    my %args = @_;

    $skeel->{$args{time}} = DateTime::Format::MySQL->format_datetime(DateTime->now)
	if $args{time};

    return $skeel;
}

## FIXME : Hacer con execute_prepare
sub make_sen {
    my $self = shift;
    my $skeel = shift;
    my $sql = $self->sql();
    my @p;

    ## Ha de encontrar resultados por el orden de entrada parsear debidamente
    for ( keys %{$skeel} ) {
	my $arg = ':'.$_;
	push @p,$skeel->{$_};
	$sql =~ s/$arg/\?/;
    }

    $sql =~ s/,$//;

    $self->sql($sql);
    $self->p(\@p);
}

sub q {
    my $self = shift;
    my $sql  = shift;
    my @p;

    map { push @p,$_ } @_;

    $self->sql($sql);
    $self->p(\@p);
}

sub execute_prepare {
    my $self = shift;
    my @p    = @_;

    my $sth = $self->db->dbh->prepare($self->sql);

    $sth->execute(@p);
}

=head1 NAME

    DBIx::Fast

=head1 SYNOPSIS

    $db = DBIx::Fast->new( db => 'test' , user => 'test' , passwd => 'test');

    $db = DBIx::Fast->new( db => 'test' , user => 'test' , passwd => 'test',
    trace => '1' , profile => '!Statement:!MethodName' );

=head1 DESCRIPTION

=head1 SUBROUTINES/METHODS

=cut

1;
