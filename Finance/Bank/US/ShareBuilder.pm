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

    my $response = $self->{ua}->get("$base/Login.aspx");
    $self->_update_asp_junk($response);

    $response = $self->{ua}->post("$base/Login.aspx", [
        __EVENTTARGET => 'nextViewPostBack',
        $self->_get_asp_junk,
    ]);
    $self->_update_asp_junk($response);

    $response = $self->{ua}->post("$base/Authentication/SignIn.aspx", [
        'ctl00$ctl00$Content$Content$ucSignInWorkflowView$view$ucUsername$UsernameRow$txtUsername' => $self->{username},
        'ctl00$ctl00$Content$Content$ctrlDeviceInformation$hdnDevicePrint' => 'version=1&pm_fpua=perl&pm_fpsc=24|1920|1200|1200&pm_fpsw=&pm_fptz=-4&pm_fpln=lang=en-US|syslang=|userlang=&pm_fpjv=0&pm_fpco=0',
        'ctl00$ctl00$Content$Content$ucSignInWorkflowView$view$ucUsername$UsernameRow$btnSignIn' => 'Sign+In',
        $self->_get_asp_junk,
    ]);
    $self->_update_asp_junk($response);

    my @lines = split /\n/, $response->content;
    my $image_check  = grep { /img.*?VerifyImagePhrase_ctl00_WebImage1.*?ii=$self->{image}/ } @lines;
    my $phrase_check = grep { /VerifyImagePhrase_SecurityPhrase.*?$self->{phrase}/ } @lines;

    $image_check && $phrase_check or croak "Couldn't verify authenticity of login page.";

    $response = $self->{ua}->post("$base/Authentication/SignIn.aspx", [
        'ctl00$ctl00$Content$Content$ctrlDeviceInformation$hdnDevicePrint' => 'version=1&pm_fpua=perl&pm_fpsc=24|1920|1200|1200&pm_fpsw=&pm_fptz=-4&pm_fpln=lang=en-US|syslang=|userlang=&pm_fpjv=0&pm_fpco=0',
        'ctl00$ctl00$Content$Content$ucSignInWorkflowView$view$ucPassword$UsernameRow$txtPassword' => $self->{password},
        'ctl00$ctl00$Content$Content$ucSignInWorkflowView$view$ucPassword$rowLoginLocations$ddlLoginLocation$ddlLoginLocations' => 'Home.aspx',
        'ctl00$ctl00$Content$Content$ucSignInWorkflowView$view$ctl07' => 'Sign+In',
        %{$self->{_asp_junk}},
    ]);
    $self->_update_asp_junk($response);

    $response = $self->{ua}->get("$base/Home.aspx");
    $self->_update_asp_junk($response);
    $self->{_account_screen} = $response->content;
}

sub _update_asp_junk {
    my ($self, $response) = @_;

    my @lines = split /\n/, $response->content;

    ($self->{_asp_junk}{__VIEWSTATE})       = grep { /id="__VIEWSTATE"/       } @lines;
    ($self->{_asp_junk}{__MVCSTATE})        = grep { /id="__MVCSTATE"/        } @lines;
    ($self->{_asp_junk}{__EVENTVALIDATION}) = grep { /id="__EVENTVALIDATION"/ } @lines;
    $self->{_asp_junk}{__VIEWSTATE}         =~ s/.*id="__VIEWSTATE" value="(.*?)".*/$1/;
    $self->{_asp_junk}{__MVCSTATE}          =~ s/.*id="__MVCSTATE" value="(.*?)".*/$1/;
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

    my @lines = grep { /_strAccount(Label|Value)">/ } split /\n/, $self->{_account_screen};

    my %accounts;
    for(my $i=0; $i<@lines; $i++) {
        my %account;
        $account{number} = $lines[$i];
        $account{number} =~ s/.*Content_Row(\d+)_str.*/$1/;
        $account{nickname} = $lines[$i];
        $account{nickname} =~ s/.*AccountLabel">(.*?)<.*/$1/;
        $i++;
        $account{balance} = $lines[$i];
        $account{balance} =~ s/.*AccountValue">(.*?)<.*/$1/;
        $accounts{$account{number}} = \%account;
    }

    %accounts;
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

    $response = $self->{ua}->post("$base/Account/Records/History.aspx", [
        '__EVENTTARGET' => 'ctl00$ctl00$ContentArea$Content$ctl00$SwitchAccount1$ddlAccountList',
        'ctl00$ctl00$ContentArea$Content$ctl00$bubbleContainer$ddlExportType' => '',
        'ctl00$ctl00$HeaderContent$headerControls$txtSearch' => '',
        'ctl00$ctl00$ContentArea$Content$ctl00$SwitchAccount1$ddlAccountList' => $account,
        'ctl00$ctl00$ContentArea$Content$ctl00$ddlTimePeriod' => 'Last7Days',
        'ctl00$ctl00$ContentArea$Content$ctl00$txtFromDate' => '10/08/2010',
        'ctl00$ctl00$ContentArea$Content$ctl00$txtToDate' => '10/15/2010',
        'ctl00$ctl00$ContentArea$Content$ctl00$ddlActivityType' => 'ALL',
        $self->_get_asp_junk,
    ]);
    $self->_update_asp_junk($response);

    $response = $self->{ua}->post("$base/Account/Records/History.aspx", [
        'ctl00$ctl00$ContentArea$Content$ctl00$bubbleContainer$ddlExportType' => 'OFX',
        'ctl00$ctl00$ContentArea$Content$ctl00$bubbleContainer$btnExport' => 'Download',
        'ctl00$ctl00$ContentArea$Content$ctl00$SwitchAccount1$ddlAccountList' => $account,
        'ctl00$ctl00$ContentArea$Content$ctl00$ddlTimePeriod' => 'LastMonth',
        'ctl00$ctl00$ContentArea$Content$ctl00$txtFromDate' => '09/01/2010',
        'ctl00$ctl00$ContentArea$Content$ctl00$txtToDate' => '09/30/2010',
        'ctl00$ctl00$ContentArea$Content$ctl00$ddlActivityType' => 'ALL',
        '__EVENTTARGET' => 'ctl00$ctl00$ContentArea$Content$ctl00$foDownloadActivity',
        $self->_get_asp_junk,
    ]);
    $self->_update_asp_junk($response);
    $response->is_success or croak "OFX download failed.";
    #print Dumper($response);

    my $ofx = $response->content;
    $ofx =~ s/\x0D//g;

    #print "======================================================\n";
    #print $ofx;
    #print "======================================================\n";

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

