package Finance::Bank::US::ShareBuilder;

use strict;

use Carp 'croak';
use LWP::UserAgent;
use HTTP::Cookies;
use Date::Parse;
use Data::Dumper;

=pod

=head1 NAME

Finance::Bank::US::INGDirect - Check balances and transactions for US INGDirect accounts

=head1 VERSION

Version 0.06

=cut

our $VERSION = '0.06';

=head1 SYNOPSIS

  use Finance::Bank::US::INGDirect;
  use Finance::OFX::Parse::Simple;

  my $ing = Finance::Bank::US::INGDirect->new(
      saver_id => '...',
      customer => '########',
      questions => {
          # Your questions may differ; examine the form to find them
          'AnswerQ1.4' => '...', # In what year was your mother born?
          'AnswerQ1.5' => '...', # In what year was your father born?
          'AnswerQ1.8' => '...', # What is the name of your hometown newspaper?
      },
      pin => '########',
  );

  my $parser = Finance::OFX::Parse::Simple->new;
  my @txs = @{$parser->parse_scalar($ing->recent_transactions)};
  my %accounts = $ing->accounts;

  for (@txs) {
      print "Account: $_->{account_id}\n";
      printf "%s %-50s %8.2f\n", $_->{date}, $_->{name}, $_->{amount} for @{$_->{transactions}};
      print "\n";
  }

=head1 DESCRIPTION

This module provides methods to access data from US INGdirect accounts,
including account balances and recent transactions in OFX format (see
Finance::OFX and related modules). It also provides a method to transfer
money from one account to another on a given date.

=cut

my $base = 'https://www.sharebuilder.com/sharebuilder';

=pod

=head1 METHODS

=head2 new( saver_id => '...', customer => '...', questions => {...}, pin => '...' )

Return an object that can be used to retrieve account balances and statements.
See SYNOPSIS for examples of challenge questions.

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

  ( '####' => [ number => '####', type => 'Orange Savings', nickname => '...',
                available => ###.##, balance => ###.## ],
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

    use HTML::TableExtract;
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

=head2 recent_transactions( $account, $days )

Retrieve a list of transactions in OFX format for the given account
(default: all accounts) for the past number of days (default: 30).

=cut

sub recent_transactions {
    my ($self, $account, $days) = @_;

    print "Getting transactions for [$account]...\n";

    $days ||= 30;

    my $response = $self->{ua}->get("$base/Account/Records/History.aspx");
    $self->_update_asp_junk($response);

    my $c = 'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$'; # ASP stupidity

    $self->{ua}->default_header(Referer => "$base/Account/Records/History.aspx");
    $response = $self->{ua}->post("$base/Account/Records/History.aspx", [
        $c.'ddlAccount' => $account,
        $c.'txtDateRange' => '11/01/2010 to 05/08/2011',
        $c.'txtDateRangeChoice' => 'Last 6 Months',
        $c.'txtTodayFromServer' => '05/08/2011',
        $c.'ddlShow' => 'ALL',
        $c.'btnView' => 'ctl00$ctl00$MainContent$MainContent$uc',
        $self->_get_asp_junk,
    ]);
    #print "{{{\n" .Dumper($response). "\n}}}\n\n";
    $self->_update_asp_junk($response);

    sleep 2;

    $response = $self->{ua}->post("$base/Account/Records/History.aspx", [
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$ddlAccount' => $account,
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$txtDateRange' => '11/01/2010 to 05/08/2011',
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$txtDateRangeChoice' => 'Last 6 Months',
        'ctl00$ctl00$MainContent$MainContent$ucView$c$views$c$txtTodayFromServer' => '05/08/2011',
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
    }

    $ofx
}

=pod

=head2 transactions( $account, $from, $to )

Retrieve a list of transactions in OFX format for the given account
(default: all accounts) in the given time frame (default: pretty far in the
past to pretty far in the future).

=cut

sub transactions {
    my ($self, $account, $from, $to) = @_;

    $account ||= 'ALL';
    $from ||= '2000-01-01';
    $to ||= '2038-01-01';

    my @from = strptime($from);
    my @to = strptime($to);

    $from[4]++;
    $to[4]++;
    $from[5] += 1900;
    $to[5] += 1900;

    my $response = $self->{ua}->post("$base/download.qfx", [
        type => 'OFX',
        TIMEFRAME => 'VARIABLE',
        account => $account,
        startDate => sprintf("%02d/%02d/%d", @from[4,3,5]),
        endDate   => sprintf("%02d/%02d/%d", @to[4,3,5]),
    ]);
    $response->is_success or croak "OFX download failed.";

    $response->content;
}

=pod

=head2 transfer( $from, $to, $amount, $when )

Transfer money from one account number to another on the given date
(default: immediately). Returns the confirmation number. Use at your
own risk.

=cut

sub transfer {
    my ($self, $from, $to, $amount, $when) = @_;
    my $type = $when ? 'SCHEDULED' : 'NOW';

    if($when) {
        my @when = strptime($when);
        $when[4]++;
        $when[5] += 1900;
        $when = sprintf("%02d/%02d/%d", @when[4,3,5]);
    }

    my $response = $self->{ua}->get("$base/INGDirect/money_transfer.vm");
    my ($page_token) = map { s/^.*value="(.*?)".*$/$1/; $_ }
        grep /<input.*name="pageToken"/,
        split('\n', $response->content);

    $response = $self->{ua}->post("$base/INGDirect/deposit_transfer_input.vm", [
        pageToken => $page_token,
        action => 'continue',
        amount => $amount,
        sourceAccountNumber => $from,
        destinationAccountNumber => $to,
        depositTransferType => $type,
        $when ? (scheduleDate => $when) : (),
    ]);
    $response->is_redirect or croak "Transfer setup failed.";

    $response = $self->{ua}->get("$base/INGDirect/deposit_transfer_validate.vm");
    ($page_token) = map { s/^.*value="(.*?)".*$/$1/; $_ }
        grep /<input.*name="pageToken"/,
        split('\n', $response->content);

    $response = $self->{ua}->post("$base/INGDirect/deposit_transfer_validate.vm", [
        pageToken => $page_token,
        action => 'submit',
    ]);
    $response->is_redirect or croak "Transfer validation failed. Check your account!";

    $response = $self->{ua}->get("$base/INGDirect/deposit_transfer_confirmation.vm");
    $response->is_success or croak "Transfer confirmation failed. Check your account!";
    my ($confirmation) = map { s/^.*Number">(\d+)<.*$/$1/; $_ }
        grep /<span.*id="confirmationNumber">/,
        split('\n', $response->content);

    $confirmation;
}

1;

=pod

=head1 AUTHOR

This version by Steven N. Severinghaus <sns-perl@severinghaus.org>
with contributions by Robert Spier.

=head1 COPYRIGHT

Copyright (c) 2010 Steven N. Severinghaus. All rights reserved. This
program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=head1 SEE ALSO

Finance::Bank::INGDirect, Finance::OFX::Parse::Simple

=cut

