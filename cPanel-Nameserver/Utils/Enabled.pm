package Cpanel::NameServer::Utils::Enabled;

# cpanel - Cpanel/NameServer/Utils/Enabled.pm      Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;
use Cpanel::OS                 ();
use Cpanel::Config::LoadCpConf ();
use Cpanel::Server::Type       ();
use Cpanel::Resolvers          ();
use Cpanel::Services::Enabled  ();

my %supported_nameservers = (
    'bind' => {
        'display_name'          => 'BIND',
        'acts_as_caching_ns'    => 1,
        'supported_on_dns_only' => 1,
        'requires_mysql'        => 0,
    },
    'powerdns' => {
        'display_name'          => 'PowerDNS',
        'acts_as_caching_ns'    => 0,
        'supported_on_dns_only' => 1,
        'requires_mysql'        => 0,
    },
);

sub valid_nameserver_type {
    my $dnstype = defined $_[0] ? lc( $_[0] ) : current_nameserver_type();

    if ( $dnstype ne 'disabled' ) {

        if ( !exists $supported_nameservers{$dnstype} ) {
            return wantarray ? ( 0, "Unknown nameserver type specified: $dnstype." ) : 0;
        }

        my $ns = $supported_nameservers{$dnstype};

        if ( !Cpanel::OS::list_contains_value( 'dns_supported', $dnstype ) ) {
            return wantarray ? ( 0, "Systems that run " . Cpanel::OS::display_name() . " do not support $ns->{display_name}." ) : 0;
        }

        if ( !$ns->{'acts_as_caching_ns'} && Cpanel::Resolvers::requires_caching_nameserver() ) {
            return wantarray ? ( 0, "$ns->{display_name} does not act as a recursive (caching) nameserver and your resolv.conf file references a local IP address." ) : 0;
        }

        if ( !$ns->{'supported_on_dns_only'} && Cpanel::Server::Type::is_dnsonly() ) {
            return wantarray ? ( 0, "$ns->{display_name} is not supported on DNSONLY systems." ) : 0;
        }

        if ( $ns->{'requires_mysql'} ) {
            require Cpanel::MysqlUtils::Version;
            my $sqlvers = Cpanel::MysqlUtils::Version::get_mysql_version_with_fallback_to_default();
            if ( $sqlvers !~ /^\d+/ ) {
                return wantarray ? ( 0, "$ns->{display_name} needs working MySQL." ) : 0;
            }
        }
    }

    return wantarray ? ( 1, undef ) : 1;
}

sub current_nameserver_type {
    return 'disabled' unless Cpanel::Services::Enabled::is_enabled('dns');

    my $cpconf_ref = Cpanel::Config::LoadCpConf::loadcpconf();
    my $dnstype    = $cpconf_ref->{'local_nameserver_type'} || 'bind';

    return lc($dnstype);
}

sub current_nameserver_is {
    my $expected = shift;

    return unless $expected;
    return $expected eq current_nameserver_type();
}

1;
