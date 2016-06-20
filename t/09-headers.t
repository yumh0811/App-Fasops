use strict;
use warnings;
use Test::More;
use App::Cmd::Tester;

use App::Fasops;

my $result = test_app( 'App::Fasops' => [qw(help headers)] );
like( $result->stdout, qr{headers}, 'descriptions' );

$result = test_app( 'App::Fasops' => [qw(headers t/example.fas -o stdout)] );
is( ( scalar grep {/\S/} split( /\n/, $result->stdout ) ), 3, 'line count' );
like( $result->stdout, qr{S288c.+\tYJM789.+\tRM11.+Spar}, 'names in one line' );

done_testing(3);
