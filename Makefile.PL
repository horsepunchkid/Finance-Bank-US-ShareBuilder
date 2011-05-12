use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Finance::Bank::US::ShareBuilder',
    AUTHOR              => q{Steven N. Severinghaus <sns-perl@severinghaus.org>},
    VERSION_FROM        => 'lib/Finance/Bank/US/ShareBuilder.pm',
    ABSTRACT_FROM       => 'lib/Finance/Bank/US/ShareBuilder.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
        'LWP::UserAgent' => 0,
        'HTTP::Cookies' => 0,
        'Date::Parse' => 0,
        'DateTime' => 0,
        'HTML::TableExtract' => 0,
        'Data::Dumper' => 0,
        'Finance::OFX::Parse' => 0,
        'Locale::Currency::Format' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Finance-Bank-US-ShareBuilder-*' },
);
