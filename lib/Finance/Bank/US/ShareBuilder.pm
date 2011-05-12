package Finance::Bank::US::ShareBuilder;

use strict;

use Carp 'croak';
use LWP::UserAgent;
use HTTP::Cookies;
use Date::Parse;
use DateTime;
use HTML::TableExtract;
use Data::Dumper;
use Finance::OFX::Parse;
use Locale::Currency::Format;

=pod

=head1 NAME

Finance::Bank::US::ShareBuilder - Check positions and transactions for US ShareBuilder investment accounts

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

  use Finance::Bank::US::ShareBuilder;

  my $sb = Finance::Bank::US::ShareBuilder->new(
    username => 'XXXXX', # Saver ID or customer number
    password => 'XXXXXXXXXX',
    image => 'I*******.jpg', # The filename of your verification image
    phrase => 'XXXXXXXXXXXXXX', # Verification phrase
  );

  my %accounts = $sb->accounts;
  for(keys %accounts) {
      printf "%10s %-15s %11s\n", $_, $accounts{$_}{nickname},
          '$'.sprintf('%.2f', $accounts{$_}{balance});
  }
  $sb->print_positions($sb->positions);

=head1 DESCRIPTION

This module provides methods to access data from US ShareBuilder accounts,
including positions and recent transactions, which can be provided in OFX
format (see Finance::OFX) or in parsed lists.

There is no support yet for executing transactions. Code for listing sell
transactions was written by analogy based on the OFX spec and has not
been tested, due to a lack of data.

=cut

my $base = 'https://www.sharebuilder.com/sharebuilder';

=pod

=head1 METHODS

=head2 new( username => '...', password => '...', image => '...', phrase => '...' )

Return an object that can be used to retrieve positions and transactions.

=cut

sub new {
    my ($class, %opts) = @_;
    my $self = bless \%opts, $class;

    $self->{ua} ||= LWP::UserAgent->new(cookie_jar => HTTP::Cookies->new);

    $self->_login;
    $self;
}

sub _login {
    my ($self) = @_;

    my $response = $self->{ua}->get("$base/authentication/signin.aspx");
    $self->_update_asp_junk($response);

    $self->{ua}->default_header(Referer => "$base/authentication/signin.aspx");
    $response = $self->{ua}->post("$base/authentication/signin.aspx", [
        $self->_get_asp_junk,
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ucUsername$ctl01$txtUsername' => $self->{username},
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ucUsername$ctl01$btnSignIn' => 'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ucUsername$ctl01$btnSignIn',
    ]);
    $self->_update_asp_junk($response);

    $self->{ua}->default_header(Referer => "$base/authentication/signin.aspx");
    $response = $self->{ua}->post("$base/authentication/signin.aspx", [
        __EVENTTARGET => 'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$nextViewPostBack',
        $self->_get_asp_junk,
    ]);
    $self->_update_asp_junk($response);

    my @lines = split /\n/, $response->content;
    my $image_check  = grep { /img.*?SelectedSecurityImage.*?ii=$self->{image}/ } @lines;
    my $phrase_check = grep { /\Q$self->{phrase}\E/ } @lines;

    $image_check && $phrase_check or croak "Couldn't verify authenticity of login page.";

    $response = $self->{ua}->post("$base/authentication/signin.aspx", [
        $self->_get_asp_junk,
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ctl08$txtPassword' => $self->{password},
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$btnNext' => 'ctl00$ctl00$MainContent$MainContent$uc',
    ]);
    $self->_update_asp_junk($response);

    $response = $self->{ua}->get("$base/account/overview.aspx");
    $self->_update_asp_junk($response);
    $self->{_account_screen} = $response->content;
}

# Pull ASP junk from current page to use for the next HTTP POST
sub _update_asp_junk {
    my ($self, $response) = @_;

    my @lines = split /\n/, $response->content;

    ($self->{_asp_junk}{__VIEWSTATE})       = grep { /id="__VIEWSTATE"/       } @lines;
    ($self->{_asp_junk}{__EVENTVALIDATION}) = grep { /id="__EVENTVALIDATION"/ } @lines;
    my %codes = map { /id="([0-9a-f]{32}|\{[0-9A-F-]{36}\})"\s+value="([^"]+)"/ ? ($1=>$2) : () }
        grep { /id="[0-9a-f]{32}|\{[0-9A-F-]{36}\}"/ } @lines;
    $self->{_asp_junk}{$_} = $codes{$_} for keys %codes;

    $self->{_asp_junk}{__VIEWSTATE}         =~ s/.*id="__VIEWSTATE" value="(.*?)".*/$1/;
    $self->{_asp_junk}{__EVENTVALIDATION}   =~ s/.*id="__EVENTVALIDATION" value="(.*?)".*/$1/;
}

# Trim down ASP junk to whatever is necessary for POSTing
sub _get_asp_junk {
    my ($self) = @_;

    my %junk = %{$self->{_asp_junk}};
    for(keys %junk) {
        delete $junk{$_} unless $junk{$_};
    }

    %junk;
}

=pod

=head2 accounts( )

Retrieve a list of accounts:

  ( '####' => { number => '####', type => '...', nickname => '...', balance => ###.## },
    ...
  )

=cut

sub accounts {
    my ($self) = @_;

    return %{$self->{_accounts}} if $self->{_accounts};

    my @lines = grep { /ctl00_ctl00_MainContent_MainContent_ucView_c_acctList(Invest|Retire)_acctListRepeater_ctl01_(t\d+|lnkFillBalanceFlyout)/ } split /\n/, $self->{_account_screen};

    my %accounts;
    for(my $i=0; $i<@lines; $i++) {
        my %account;

        $account{type} = $lines[$i];
        $account{type} =~ s/.*c_acctList(Invest|Retire)_acctListRepeater.*/$1/;
        $i++;

        $account{nickname} = $lines[$i];
        $account{nickname} =~ s/.*>(.*?)<.*/$1/;
        $i++;

        $account{number} = $lines[$i];
        $account{number} =~ s/.*>(.*?)<.*/$1/;
        $i++;
        $i++;

        $account{balance} = $lines[$i];
        $account{balance} =~ s/.*>(.*?)<.*/$1/;
        $account{balance} =~ s/[\$,]//g;
        $i++;

        $accounts{$account{number}} = \%account;
    }

    $self->{_accounts} = \%accounts;

    %accounts;
}

=pod

=head2 positions( $account )

List positions for an account:

  ( { symbol => 'PERL', description => 'Perl, Inc.', quantity => 3.1416,
            value => 271.83, quote => 86.52, cost_per_share => 73.12,
            basis => 229.71, change => 42.12, change_pct => 18.33 }
    ...
  )

=cut

sub positions {
    my ($self, $account) = @_;

    my $response = $self->{ua}->get("$base/account/overview.aspx");
    $self->_update_asp_junk($response);

    $self->{ua}->default_header(Referer => "$base/account/overview.aspx");
    $response = $self->{ua}->post("$base/account/overview.aspx", [
        __EVENTTARGET => 'ctl00$ctl00$MainContent$MainContent$ucView$c$acctQuickLinks$btnPositions',
        'ctl00$ctl00$MainContent$MainContent$ucView$c$acctQuickLinks$hidAccountNumber' => $account,
        $self->_get_asp_junk,
    ]);

    $response = $self->{ua}->get("$base/account/portfolio/positions.aspx");
    $response->is_success or croak "OFX download failed.";

    my $te  = new HTML::TableExtract( headers=>['Symbol', 'Description', 'Quote',
        'Day Change', 'Quantity', 'Market Value', 'Cost / Share',
        'Cost Basis', 'Gain or Loss']);
    $te->parse($response->content);

    my @positions;
    for my $row ($te->rows)
    {
        my %p;
        (
            $p{symbol},
            $p{description},
            $p{quote},
            $p{day_change_and_pct},
            $p{quantity},
            $p{value},
            $p{cost_per_share},
            $p{basis},
            $p{change_and_pct},
        ) = map { s/^\s*//; s/\s*$//; $_ } @$row;

        ($p{day_change}, $p{day_change_pct}) = split/[\s\n]+/, $p{day_change_and_pct};
        delete $p{day_change_and_pct};
        ($p{change}, $p{change_pct}) = split/[\s\n]+/, $p{change_and_pct};
        delete $p{change_and_pct};

        $p{day_change}     =~ s/[+\$,%()]//g;
        $p{day_change_pct} =~ s/[+\$,%()]//g;
        $p{change}         =~ s/[+\$,%()]//g;
        $p{change_pct}     =~ s/[+\$,%()]//g;
        $p{day_change_pct} = '-'.$p{day_change_pct} if $p{day_change} =~ /-/;
        $p{change_pct}     = '-'.$p{change_pct}     if $p{change}     =~ /-/;

        $p{value}          =~ s/[\$,]//g;
        $p{quote}          =~ s/[\$,]//g;
        $p{basis}          =~ s/[\$,]//g;
        $p{cost_per_share} =~ s/[\$,]//g;

        push @positions, \%p if $p{description};
    }

    @positions
}

=pod

=head2 print_positions( @positions )

Pretty-print a set of positions as returned by positions().

=cut

sub print_positions {
    my ($self, @positions) = @_;
    for(@positions) {
        printf "%-8s  % 9.4f * %7s = %9s ; %-4s %9s (%7s) from %9s\n",
            $_->{symbol}, $_->{quantity}, usd($_->{quote}), usd($_->{value}),
            $_->{change} =~ /-/ ? 'down' : 'up', usd($_->{change}), "$_->{change_pct}%", usd($_->{basis});
    }
}

=pod

=head2 recent_transactions( $account, $days )

Retrieve a list of transactions in OFX format for the given account
for the past number of days (default: 30).

=cut

sub recent_transactions {
    my ($self, $account, $days) = @_;

    $days ||= 30;

    my $to = DateTime->today;
    my $from = $to->clone->add(days => -$days);

    $self->transactions($account, $from->ymd('-'), $to->ymd('-'));
}

=pod

=head2 transactions( $account, $from, $to )

Retrieve a list of transactions in OFX format for the given account
in the given time frame (default: past three months).

=cut

sub transactions {
    my ($self, $account, $from, $to) = @_;

    $to   = $to   ? DateTime->from_epoch(epoch => str2time($to))   : DateTime->today;
    $from = $from ? DateTime->from_epoch(epoch => str2time($from)) : $to->clone->add(months => -6);

    my $response = $self->{ua}->get("$base/Account/Records/History.aspx");
    $self->_update_asp_junk($response);

    my $c = 'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$'; # ASP stupidity

    $self->{ua}->default_header(Referer => "$base/Account/Records/History.aspx");
    $response = $self->{ua}->post("$base/Account/Records/History.aspx", [
        $c.'ddlAccount' => $account,
        $c.'txtDateRange' => $from->mdy('/').' to '.$to->mdy('/'),
        $c.'ddlShow' => 'ALL',
        $c.'btnView' => 'ctl00$ctl00$MainContent$MainContent$uc',
        $self->_get_asp_junk,
    ]);
    #print "{{{\n" .Dumper($response). "\n}}}\n\n";
    $self->_update_asp_junk($response);

    $response = $self->{ua}->post("$base/Account/Records/History.aspx", [
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ddlAccount' => $account,
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$txtDateRange' => $from->mdy('/').' to '.$to->mdy('/'),
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ddlShow' => 'ALL',
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ddlFinancialSoftware' => 'OFX',
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$btnDownload' => 'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$btnDownload',
        $self->_get_asp_junk,
    ]);
    #print "{{{\n" .Dumper($response). "\n}}}\n\n";
    $self->_update_asp_junk($response);
    $response->is_success or croak "OFX download failed.";

    my $ofx = $response->content;
    $ofx =~ s/\x0D//g;

    if($ofx =~ /Unable to process transaction/) {
        croak "OFX returned, but with a failure.";
        $ofx =~ s/></>\n</g;
        print Dumper($ofx);
    }

    $ofx
}

=pod

=head2 transaction_list( $account, $from, $to )

Return transactions as a list instead of as OFX.

=cut

sub transaction_list {
    my ($self, $account, $from, $to) = @_;

    my $ofx = $self->transactions($account, $from, $to);

    my $tree = Finance::OFX::Parse::parse($ofx);

    my %secmap = map { $_->{secinfo}{secid}{uniqueid} => $_->{secinfo}{ticker} }
        @{$tree->{ofx}{seclistmsgsrsv1}{seclist}{stockinfo}};

    my $invlist = $tree->{ofx}{invstmtmsgsrsv1}{invstmttrnrs}{invstmtrs}{invtranlist};
    my @buys  = @{$invlist->{buystock}}  if $invlist->{buystock};
    my @sells = @{$invlist->{sellstock}} if $invlist->{sellstock};
    my @reinvests = @{$invlist->{reinvest}} if $invlist->{reinvest};

    my @txns;

    for(@buys) {
        my %txn;

        $txn{type} = 'buy';
        $txn{symbol} = $secmap{$_->{invbuy}{secid}{uniqueid}};
        $txn{date} = DateTime->from_epoch(epoch => $_->{invbuy}{invtran}{dttrade})->ymd('-');
        $txn{total} = 0 - $_->{invbuy}{total};
        $txn{commission} = $_->{invbuy}{commission};
        $txn{cost_per_share} = $_->{invbuy}{unitprice};
        $txn{quantity} = $_->{invbuy}{units};

        push @txns, \%txn;
    }

    for(@sells) {
        my %txn;

        $txn{type} = 'sell';
        $txn{symbol} = $secmap{$_->{invsell}{secid}{uniqueid}};
        $txn{date} = DateTime->from_epoch(epoch => $_->{invsell}{invtran}{dttrade})->ymd('-');
        $txn{total} = 0 - $_->{invsell}{total};
        $txn{commission} = $_->{invsell}{commission};
        $txn{cost_per_share} = $_->{invsell}{unitprice};
        $txn{quantity} = $_->{invsell}{units};

        push @txns, \%txn;
    }

    for(@reinvests) {
        my %txn;

        $txn{type} = 'reinvest';
        $txn{symbol} = $secmap{$_->{secid}{uniqueid}};
        $txn{date} = DateTime->from_epoch(epoch => $_->{invtran}{dttrade})->ymd('-');
        $txn{total} = 0 - $_->{total};
        $txn{commission} = $_->{commission}; # Should be zero
        $txn{cost_per_share} = $_->{unitprice};
        $txn{quantity} = $_->{units};

        push @txns, \%txn;
    }

    @txns
}

=pod

=head2 print_transactions( @txns )

Pretty-print a set of transactions as returned by transaction_list().

=cut

sub print_transactions {
    my ($self, @txns) = @_;
    for(sort { $b->{date} cmp $a->{date} } @txns) {
        printf "%10s %-8s %-6s %10s - %6s = %9.4f * %9s\n", $_->{date}, $_->{type}, $_->{symbol},
            usd($_->{total}), usd($_->{commission}), $_->{quantity}, usd($_->{cost_per_share});
    }
}

=pod

=head2 usd( $dollars )

Shortcut to format a floating point amount as dollars (dollar sign, commas, and two decimal places).

=cut

sub usd { currency_format('USD', $_[0], FMT_SYMBOL) }

=pod

=head1 AUTHOR

This version by Steven N. Severinghaus <sns-perl@severinghaus.org>

=head1 COPYRIGHT

Copyright (c) 2011 Steven N. Severinghaus. All rights reserved. This
program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=head1 SEE ALSO

Finance::Bank::US::INGDirect, Finance::OFX::Parse

=cut

