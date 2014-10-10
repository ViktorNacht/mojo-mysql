package Mojo::Pg::Migrations;
use Mojo::Base -base;

use Carp 'croak';
use Mojo::Loader;
use Mojo::Util 'slurp';

has name => 'migrations';
has 'pg';

sub active { $_[0]->_active($_[0]->pg->db) }

sub from_class {
  my ($self, $class) = @_;
  $class //= caller;
  return $self->from_string(Mojo::Loader->new->data($class, $self->name));
}

sub from_file { shift->from_string(slurp pop) }

sub from_string {
  my ($self, $sql) = @_;

  my ($version, $way);
  my $migrations = $self->{migrations} = {up => {}, down => {}};
  for my $line (split "\n", $sql // '') {
    ($version, $way) = ($1, lc $2) if $line =~ /^\s*--\s*(\d+)\s*(up|down)/i;
    $migrations->{$way}{$version} .= "$line\n" if $version;
  }

  return $self;
}

sub latest { (sort keys %{shift->{migrations}{up}})[-1] || 0 }

sub migrate {
  my ($self, $target) = @_;
  $target //= $self->latest;

  # Already the right version
  my $db = $self->pg->db;
  return $self if (my $active = $self->_active($db)) == $target;

  # Unknown version
  my $up = $self->{migrations}{up};
  croak "Version $target has no migration" if $target != 0 && !$up->{$target};

  # Up
  my $sql;
  if ($active < $target) {
    $sql = join '',
      map { $up->{$_} } grep { $_ <= $target && $_ > $active } sort keys %$up;
  }

  # Down
  else {
    my $down = $self->{migrations}{down};
    $sql = join '',
      map { $down->{$_} }
      grep { $_ > $target && $_ <= $active } reverse sort keys %$down;
  }

  local @{$db->dbh}{qw(RaiseError AutoCommit)} = (0, 1);
  $sql .= ';update mojo_migrations set version = ? where name = ?;';
  my $results = $db->begin->query($sql, $target, $self->name);
  if ($results->sth->err) {
    my $err = $results->sth->errstr;
    $db->rollback;
    croak $err;
  }
  $db->commit;

  return $self;
}

sub _active {
  my ($self, $db) = @_;

  my $name = $self->name;
  my $dbh  = $db->dbh;
  local @$dbh{qw(AutoCommit RaiseError)} = (1, 0);
  my $results
    = $db->query('select version from mojo_migrations where name = ?', $name);
  if (my $next = $results->array) { return $next->[0] }

  local @$dbh{qw(AutoCommit RaiseError)} = (1, 1);
  $db->query(
    'create table if not exists mojo_migrations (
       name    varchar(255),
       version varchar(255)
     );'
  ) if $results->sth->err;
  $db->query('insert into mojo_migrations values (?, ?);', $name, 0);

  return 0;
}

1;

=encoding utf8

=head1 NAME

Mojo::Pg::Migrations - Migrations

=head1 SYNOPSIS

  use Mojo::Pg::Migrations;

  my $migrations = Mojo::Pg::Migrations->new(pg => $pg);

=head1 DESCRIPTION

L<Mojo::Pg::Migrations> performs database migrations for L<Mojo::Pg>.
Migration files are just a collection of sql blocks, with one or more
statements, separated by comments of the form C<-- VERSION UP/DOWN>.

  -- 1 up
  create table if not exists foo (bar varchar(255));
  -- 1 down
  drop table if exists foo;
  -- 2 up (...you can comment freely here...)
  create table if not exists baz (yada varchar(255));
  -- 2 down
  drop table if exists baz;

The current version, which is tied to the L</"name">, gets stored in an
automatically created table with the name C<mojo_migrations>.

=head1 ATTRIBUTES

L<Mojo::Pg::Migrations> implements the following attributes.

=head2 name

  my $name    = $migrations->name;
  $migrations = $migrations->name('foo');

Name for this set of migrations, defaults to C<migrations>.

=head2 pg

  my $pg      = $migrations->pg;
  $migrations = $migrations->pg(Mojo::Pg->new);

L<Mojo::Pg> object these migrations belong to.

=head1 METHODS

L<Mojo::Pg::Migrations> inherits all methods from L<Mojo::Base> and implements
the following new ones.

=head2 active

  my $version = $migrations->active;

Currently active version.

=head2 from_class

  $migrations = $migrations->from_class;
  $migrations = $migrations->from_class('main');

Extract migrations from a file identified by L</"name"> in the DATA section of
a class with L<Mojo::Loader>, defaults to using the caller class.

  __DATA__
  @@ migrations
  -- 1 up
  create table if not exists foo (bar varchar(255));
  -- 1 down
  drop table if exists foo;

=head2 from_file

  $migrations = $migrations->from_file('/Users/sri/migrations.sql');

Extract migrations from a file.

=head2 from_string

  $migrations = $migrations->from_string(
    '-- 1 up
     create table foo (bar varchar(255));
     -- 1 down
     drop table foo;'
  );

Extract migrations from string.

=head2 latest

  my $version = $migrations->latest;

Latest version available.

=head2 migrate

  $migrations = $migrations->migrate;
  $migrations = $migrations->migrate(3);

Migrate from L</"active"> to a different version, up or down, defaults to
using L</"latest">. All version numbers need to be positive, with version C<0>
representing an empty database.

  # Reset database
  $migrations->migrate(0)->migrate;

=head1 SEE ALSO

L<Mojo::Pg>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut