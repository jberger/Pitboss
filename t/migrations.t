use Mojo::Base -strict;

use Mojo::File 'curfile';
use Mojo::Pg;

use Test2::V0;

my $url = $ENV{PITBOSS_TEST_URL};
die 'PITBOSS_TEST_URL is required' unless $url;
my $pg = Mojo::Pg->new($url)->auto_migrate(0);

my $schema = 't_migrations';
$pg->search_path([$schema]);
$pg->db->query("drop schema if exists $schema cascade");
$pg->db->query("create schema $schema");

$pg->migrations->from_file(curfile->dirname->sibling('share')->child('pitboss.sql'));

# this test tests (to some amount at least) the version migration down by 
# migrating up, down, and up again, at the very least this shouldn't error out

ok( 
  lives {
    $pg->migrations->migrate(0);
    $pg->migrations->migrate;
  }, 
  'migrate up down and up again lives'
) or note($@);

done_testing;


