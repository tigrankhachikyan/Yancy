package Yancy::Backend::Mysql;
our $VERSION = '0.009';
# ABSTRACT: A backend for MySQL using Mojo::mysql

=head1 SYNOPSIS

    # yancy.conf
    {
        backend => 'mysql://user:pass@localhost/mydb',
        collections => {
            table_name => { ... },
        },
    }

    # Plugin
    use Mojolicious::Lite;
    plugin Yancy => {
        backend => 'mysql://user:pass@localhost/mydb',
        collections => {
            table_name => { ... },
        },
    };

=head1 DESCRIPTION

This Yancy backend allows you to connect to a MySQL database to manage
the data inside. This backend uses L<Mojo::mysql> to connect to MySQL.

See L<Yancy::Backend> for the methods this backend has and their return
values.

=head2 Backend URL

The URL for this backend takes the form C<<
mysql://<user>:<pass>@<host>:<port>/<db> >>.

Some examples:

    # Just a DB
    mysql:///mydb

    # User+DB (server on localhost:3306)
    mysql://user@/mydb

    # User+Pass Host and DB
    mysql://user:pass@example.com/mydb

=head2 Collections

The collections for this backend are the names of the tables in the
database.

So, if you have the following schema:

    CREATE TABLE people (
        id INTEGER AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        email VARCHAR(255) NOT NULL
    );
    CREATE TABLE business (
        id INTEGER AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        email VARCHAR(255) NULL
    );

You could map that schema to the following collections:

    {
        backend => 'mysql://user@/mydb',
        collections => {
            People => {
                required => [ 'name', 'email' ],
                properties => {
                    id => {
                        type => 'integer',
                        readOnly => 1,
                    },
                    name => { type => 'string' },
                    email => { type => 'string' },
                },
            },
            Business => {
                required => [ 'name' ],
                properties => {
                    id => {
                        type => 'integer',
                        readOnly => 1,
                    },
                    name => { type => 'string' },
                    email => { type => 'string' },
                },
            },
        },
    }

=head1 SEE ALSO

L<Mojo::mysql>, L<Yancy>

=cut

use v5.24;
use Mojo::Base 'Mojo';
use experimental qw( signatures postderef );
use Scalar::Util qw( looks_like_number );
use Mojo::mysql 1.0;

has mysql =>;
has collections =>;

sub new( $class, $url, $collections ) {
    my ( $connect ) = $url =~ m{^[^:]+://(.+)$};
    my %vars = (
        mysql => Mojo::mysql->new( "mysql://$connect" ),
        collections => $collections,
    );
    return $class->SUPER::new( %vars );
}

sub create( $self, $coll, $params ) {
    my $id_field = $self->collections->{ $coll }{ 'x-id-field' } || 'id';
    my $id = $self->mysql->db->insert( $coll, $params )->last_insert_id;
    return $self->get( $coll, $params->{ $id_field } || $id );
}

sub get( $self, $coll, $id ) {
    my $id_field = $self->collections->{ $coll }{ 'x-id-field' } || 'id';
    return $self->mysql->db->select( $coll, undef, { $id_field => $id } )->hash;
}

sub list( $self, $coll, $params={}, $opt={} ) {
    my $mysql = $self->mysql;
    my ( $query, @params ) = $mysql->abstract->select( $coll, undef, $params, $opt->{order_by} );
    my ( $total_query, @total_params ) = $mysql->abstract->select( $coll, [ \'COUNT(*) as total' ], $params );
    if ( scalar grep defined, $opt->@{qw( limit offset )} ) {
        die "Limit must be number" if $opt->{limit} && !looks_like_number $opt->{limit};
        $query .= ' LIMIT ' . ( $opt->{limit} // 2**32 );
        if ( $opt->{offset} ) {
            die "Offset must be number" if !looks_like_number $opt->{offset};
            $query .= ' OFFSET ' . $opt->{offset};
        }
    }
    #; say $query;
    return {
        rows => $mysql->db->query( $query, @params )->hashes,
        total => $mysql->db->query( $total_query, @total_params )->hash->{total},
    };
}

sub set( $self, $coll, $id, $params ) {
    my $id_field = $self->collections->{ $coll }{ 'x-id-field' } || 'id';
    return $self->mysql->db->update( $coll, $params, { $id_field => $id } );
}

sub delete( $self, $coll, $id ) {
    my $id_field = $self->collections->{ $coll }{ 'x-id-field' } || 'id';
    return $self->mysql->db->delete( $coll, { $id_field => $id } );
}

sub read_schema( $self ) {
    my %schema;
    my $tables_q = <<ENDQ;
SELECT * FROM INFORMATION_SCHEMA.TABLES
WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
ENDQ

    my $key_q = <<ENDQ;
SELECT * FROM information_schema.table_constraints as tc
JOIN information_schema.key_column_usage AS ccu USING ( table_name, table_schema )
WHERE tc.table_name=? AND constraint_type = 'PRIMARY KEY'
    AND tc.table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
ENDQ

    my @tables = $self->mysql->db->query( $tables_q )->hashes->@*;
    for my $t ( @tables ) {
        my $table = $t->{TABLE_NAME};
        # ; say "Got table $table";
        my @keys = $self->mysql->db->query( $key_q, $table )->hashes->@*;
        # ; say "Got keys";
        # ; use Data::Dumper;
        # ; say Dumper \@keys;
        if ( @keys && $keys[0]{COLUMN_NAME} ne 'id' ) {
            $schema{ $table }{ 'x-id-field' } = $keys[0]{COLUMN_NAME};
        }
    }

    my $columns_q = <<ENDQ;
SELECT * FROM information_schema.columns
WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
ENDQ

    my @columns = $self->mysql->db->query( $columns_q )->hashes->@*;
    for my $c ( @columns ) {
        my $table = $c->{TABLE_NAME};
        my $column = $c->{COLUMN_NAME};
        # ; use Data::Dumper;
        # ; say Dumper $c;
        $schema{ $table }{ properties }{ $column } = {
            _map_type( $c->{DATA_TYPE} ),
        };
        # Auto_increment columns are allowed to be null
        if ( $c->{IS_NULLABLE} eq 'NO' && !$c->{COLUMN_DEFAULT} && $c->{EXTRA} !~ /auto_increment/ ) {
            push $schema{ $table }{ required }->@*, $column;
        }
    }

    return \%schema;
}

sub _map_type( $db_type ) {
    if ( $db_type =~ /^(?:character|text|varchar)/i ) {
        return ( type => 'string' );
    }
    elsif ( $db_type =~ /^(?:int|integer|smallint|bigint|tinyint)/i ) {
        return ( type => 'integer' );
    }
    elsif ( $db_type =~ /^(?:double|float|money|numeric|real)/i ) {
        return ( type => 'number' );
    }
    elsif ( $db_type =~ /^(?:timestamp)/i ) {
        return ( type => 'string', format => 'date-time' );
    }
    # Default to string
    return ( type => 'string' );
}

1;
