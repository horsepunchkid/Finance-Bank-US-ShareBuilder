#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Finance::Bank::US::ShareBuilder' );
}

diag( "Testing Finance::Bank::US::ShareBuilder $Finance::Bank::US::ShareBuilder::VERSION, Perl $], $^X" );
