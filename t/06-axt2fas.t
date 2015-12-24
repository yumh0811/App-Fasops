use Test::More tests => 4;
use App::Cmd::Tester;

use App::Fasops;

my $result = test_app( 'App::Fasops' => [qw(axt2fas t/example.axt -o stdout)] );
is( ( scalar grep {/\S/} split( /\n/, $result->stdout ) ), 8, 'line count' );
like( $result->stdout, qr{target\.X.+query\.gi_29362424.+target\.X.+query.gi_29362377}s, 'name list' );

$result = test_app( 'App::Fasops' => [qw(axt2fas t/example.axt -t S288c -q Spar -l 50 -o stdout)] );
is( ( scalar grep {/\S/} split( /\n/, $result->stdout ) ), 4, 'line count' );
like( $result->stdout, qr{S288c\.X.+Spar\.gi_29362377}s, 'change names' );