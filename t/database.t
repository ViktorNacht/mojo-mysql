BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }
use Mojo::Base -strict;
use Test::More;
use DBI ':sql_types';
use Mojo::IOLoop;
use Mojo::mysql;

plan skip_all => 'TEST_ONLINE=mysql://root@/test' unless $ENV{TEST_ONLINE};

my $mysql = Mojo::mysql->new($ENV{TEST_ONLINE});
ok $mysql->db->ping, 'connected';

# Blocking select
is_deeply $mysql->db->query('select 1 as one, 2 as two, 3 as three')->hash, {one => 1, two => 2, three => 3},
  'right structure';

# Non-blocking select
my ($err, $res);
my $db = $mysql->db;
is $db->backlog, 0, 'no operations waiting';
$db->query('select 1 as one, 2 as two, 3 as three' => sub { ($err, $res) = ($_[1], $_[2]->hash); Mojo::IOLoop->stop; });
is $db->backlog, 1, 'one operation waiting';
Mojo::IOLoop->start;
is $db->backlog, 0, 'no operations waiting';
ok !$err, 'no error' or diag "err=$err";
is_deeply $res, {one => 1, two => 2, three => 3}, 'right structure';

# Concurrent non-blocking selects
($err, $res) = ();
Mojo::IOLoop->delay(
  sub {
    my $delay = shift;
    my $db    = $mysql->db;
    $db->query('select 1 as one' => $delay->begin);
    $db->query('select 2 as two' => $delay->begin);
    $db->query('select 2 as two' => $delay->begin);
  },
  sub {
    my ($delay, $err_one, $one, $err_two, $two, $err_again, $again) = @_;
    $err = $err_one || $err_two || $err_again;
    $res = [$one->hashes->first, $two->hashes->first, $again->hashes->first];
  }
)->wait;
ok !$err, 'no error' or diag "err=$err";
is_deeply $res, [{one => 1}, {two => 2}, {two => 2}], 'concurrent non-blocking selects';

# Sequential and Concurrent non-blocking selects
($err, $res) = (0, []);
Mojo::IOLoop->delay(
  sub {
    $db->query('select 1 as one' => $_[0]->begin);
  },
  sub {
    $err ||= $_[1];
    push @$res, $_[2]->hashes->first;
    $db->query('select 2 as two' => $_[0]->begin);
    $db->query('select 2 as two' => $_[0]->begin);
  },
  sub {
    my ($delay, $err_two, $two, $err_again, $again) = @_;
    push @$res, $db->query('select 1 as one')->hashes->first;
    $err ||= $err_two || $err_again;
    push @$res, $two->hashes->first, $again->hashes->first;
    $db->query('select 3 as three' => $delay->begin);
  },
  sub {
    my ($delay, $err_three, $three) = @_;
    $err ||= $err_three;
    push @$res, $three->hashes->first;
  }
)->wait;
ok !$err, 'no error' or diag "err=$err";
is_deeply $res, [{one => 1}, {one => 1}, {two => 2}, {two => 2}, {three => 3}], 'right structure';

# Connection cache
is $mysql->max_connections, 5, 'right default';
my @pids = sort map { $_->pid } $mysql->db, $mysql->db, $mysql->db, $mysql->db, $mysql->db;
is_deeply \@pids, [sort map { $_->pid } $mysql->db, $mysql->db, $mysql->db, $mysql->db, $mysql->db],
  'same database pids';
my $pid = $mysql->max_connections(1)->db->pid;
is $mysql->db->pid, $pid, 'same database pid';
isnt $mysql->db->pid, $mysql->db->pid, 'different database pids';
is $mysql->db->pid, $pid, 'different database pid';
$pid = $mysql->db->pid;
is $mysql->db->pid, $pid, 'same database pid';
$mysql->db->disconnect;
isnt $mysql->db->pid, $pid, 'different database pid';
my $dbh = $mysql->db->dbh;
is $mysql->db->dbh, $dbh, 'same database handle';
isnt $mysql->close_idle_connections->db->dbh, $dbh, 'different database handles';

# Binary data
$db = $mysql->db;
my $bytes = "\xF0\xF1\xF2\xF3";
is_deeply $db->query('select binary ? as foo', {type => SQL_BLOB, value => $bytes})->hash, {foo => $bytes},
  'right data';

# Fork safety
$pid = $mysql->db->pid;
{
  local $$ = -23;
  isnt $mysql->db->pid, $pid, 'different database handles';
};

# Blocking error
eval { $mysql->db->query('does_not_exist') };
like $@, qr/does_not_exist/, 'does_not_exist sync';

# Non-blocking error
($err, $res) = ();
$mysql->db->query('does_not_exist' => sub { ($err, $res) = @_[1, 2]; Mojo::IOLoop->stop; });
Mojo::IOLoop->start;
like $err, qr/does_not_exist/, 'does_not_exist async';

# Clean up non-blocking queries
($err, $res) = ();
$db = $mysql->db;
$db->query('select 1' => sub { ($err, $res) = @_[1, 2] });
$db->disconnect;
undef $db;
is $err, 'Premature connection close', 'Premature connection close';

# Error context
($err, $res) = ();
eval { $mysql->db->query('select * from table_does_not_exist') };
like $@, qr/database\.t line/, 'error context blocking';
$mysql->db->query(
  'select * from table_does_not_exist',
  sub {
    (my $db, $err, $res) = @_;
    Mojo::IOLoop->stop;
  }
);

Mojo::IOLoop->start;
like $err, qr/database\.t line/, 'error context non-blocking';

done_testing();
