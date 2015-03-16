package DBIx::Fast;

use strict;
use warnings FATAL => 'all';

our $VERSION = '0.01';

#use Carp 'croak';
use Moo;
use DBI;
use DBIx::Connector;

has db  => ( is => 'rw' );
has sql => ( is => 'rw' );
has p   => ( is => 'rw' );
has last_id => ( is => 'rw');
has results => ( is => 'rw');
has errors => ( is => 'rw');
has error => ( is => 'rwp');
has args => ( is => 'rwp');

sub set_args {
    my $self = shift;
    my @args = @_;

    $self->p(\@args);
}

sub get_args {
    my $self = shift;
}

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

    $args->{host} = '127.0.0.1' unless $args->{host};

    my $dsn = 'dbi:mysql:database='.$args->{db}.':'.$args->{host};

    $dsn = 'dbi:sqlite:'.$args->{db} if $args->{host} eq 'sqlite';

    $self->db(DBIx::Connector->new( $dsn, $args->{user}, $args->{passwd}
				    ,{
					RaiseError => 0,
					PrintError => 0,
					AutoCommit => 1,
				    } )
	);

    $self->db->dbh->{HandleError} = sub {
	$self->set_error($DBI::err,$DBI::errstr);
    };

    $self->db->dbh->trace($args->{trace},'dbix-fast-trace') if $args->{trace};

    $self->profile($args->{profile}) if $args->{profile};

    $self->db->mode('ping');
}

sub profile {
    my $self = shift;
    my $stat = shift."/DBI::ProfileDumper/";

    $stat .= "File:dbix-fast.prof";

    $self->db->dbh->{Profile} = $stat;
}

=doc Compatibility
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
    my @p;

    my $sql = "UPDATE $table SET ";

    for ( keys $skeel->{sen} ) {
	push @p,$skeel->{sen}->{$_};
	$sql .= $_.' = ? ,';
    }

    $sql =~ s/,$//;
    $sql .= 'WHERE ';

    for my $K ( keys $skeel->{where} ) {
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
    my @p;

    my $sql= "INSERT INTO $table ( ";

    for ( keys $skeel ) {
       push @p,$skeel->{$_};
       $sql .= $_.',';
    }

    $sql =~ s/,$/ )/;
    $sql .= ' VALUES ( '.join(',', ('?') x @p).' )';

    $self->sql($sql);
    $self->execute_prepare(@p);

    $self->last_id($self->db->dbh->{mysql_insertid});
}

sub delete {
    my $self = shift;
    my $table = shift;
    my $skeel = shift;
    my @p;

    my $sql = "DELETE FROM $table WHERE ";

    for ( keys $skeel ) {
	push @p,$skeel->{$_};
	$sql .= $_.' = ? ,';
    }

    $sql =~ s/,$//;

    $self->sql($sql);

    $self->execute_prepare(@p);
}

## FIXME : Hacer con execute_prepare
sub make_sen {
    my $self = shift;
    my $skeel = shift;
    my $sql = $self->sql();
    my @p;

    ## Ha de encontrar resultados por el orden de entrada parsear debidamente
    for ( keys $skeel ) {
	my $arg = ':'.$_;
	push @p,$skeel->{$_};
	$sql =~ s/$arg/\?/;
    }

    $sql =~ s/,$//;

    $self->sql($sql);
    $self->set_args(@p);
}

sub q {
    my $self = shift;
    my $sql  = shift;
    my @p;

    map { push @p,$_ } @_;

    $self->sql($sql);
    $self->set_args(@p);
}

sub execute_prepare {
    my $self = shift;
    my @p    = @_;

    my $sth = $self->db->dbh->prepare($self->sql);

    $sth->execute(@p);
}

1;
