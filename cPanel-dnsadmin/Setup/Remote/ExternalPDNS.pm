package Cpanel::NameServer::Setup::Remote::ExternalPDNS;

# cpanel - Cpanel/NameServer/Setup/Remote/ExternalPDNS.pm
#                                                  Copyright 2024
#                                                           All rights reserved.
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use Cpanel::HTTP::Client    ();
use Cpanel::FileUtils::Copy ();
use Whostmgr::ACLS          ();
use Cpanel::JSON            ();

## no critic (RequireUseWarnings) -- requires auditing for potential warnings

Whostmgr::ACLS::init_acls();

sub setup {
    my ( $self, %OPTS ) = @_;

    if ( !Whostmgr::ACLS::checkacl('clustering') ) {
        return 0, 'User does not have the clustering ACL enabled.';
    }

    return 0, 'No API URL given'                      if !defined $OPTS{'api_url'};
    return 0, 'No apikey given'                       if !defined $OPTS{'apikey'};
    return 0, 'No Namserver Configuration Specified' if !defined $OPTS{'ns_config'};

    my $api_url   = $OPTS{'api_url'};
    my $apikey    = $OPTS{'apikey'};
    my $server_id = $OPTS{'server_id'} || 'localhost';
    my $ns_config = $OPTS{'ns_config'};
    my $powerdns_ns = $OPTS{'powerdns_ns'} || '';

    # Validate debug parameter.
    # This is a boolean.
    # We do not care, nor want, the passed value, just its truthyness.

    my $debug = $OPTS{'debug'} ? 1 : 0;

    # Validate api_url parameter.

    $api_url =~ tr/\r\n\f\0//d;
    return 0, 'Invalid API URL given' if !$api_url;
    # Remove trailing slash if present
    $api_url =~ s/\/$//;

    # Validate apikey parameter.

    $apikey =~ tr/\r\n\f\0//d;
    return 0, 'Invalid apikey given' if !$apikey;

    # Validate server_id parameter.

    $server_id =~ tr/\r\n\f\0//d;
    return 0, 'Invalid server ID given' if !$server_id;

    # Validate ns_config parameter.

    if ( $ns_config !~ /\A(?:force|ensure|default)\z/ ) {
        return ( 0, 'Invalid nameserver configuration value given' );
    }

    # Validate powerdns_ns if ns_config is force or ensure
    if ( ( $ns_config eq 'force' || $ns_config eq 'ensure' ) && !$powerdns_ns ) {
        return ( 0, 'PowerDNS nameservers must be specified when using force or ensure mode' );
    }

    # do some stuff to write out the config files.
    my $ua = Cpanel::HTTP::Client->new(
        timeout    => 60,
        keep_alive => 1,
    );

    # Test API connection
    my $test_url = $api_url;
    $test_url .= '/' unless $test_url =~ /\/$/;
    $test_url .= "api/v1/servers/$server_id";

    my $resp = $ua->get(
        $test_url,
        {
            headers => {
                'Accept'        => 'application/json',
                'X-API-Key'     => $apikey,
            }
        }
    );

    if ( !$resp->{'success'} ) {
        return 0, 'There was an error trying to connect to PowerDNS API, please verify your API URL, server ID, and API key';
    }

    my $safe_remote_user = $ENV{'REMOTE_USER'};
    $safe_remote_user =~ s/\///g;
    mkdir '/var/cpanel/cluster',                                  0700 if !-e '/var/cpanel/cluster';
    mkdir '/var/cpanel/cluster/' . $safe_remote_user,             0700 if !-e '/var/cpanel/cluster/' . $safe_remote_user;
    mkdir '/var/cpanel/cluster/' . $safe_remote_user . '/config', 0700 if !-e '/var/cpanel/cluster/' . $safe_remote_user . '/config';

    if ( open my $config_fh, '>', '/var/cpanel/cluster/' . $safe_remote_user . '/config/externalpdns' ) {
        chmod 0600, '/var/cpanel/cluster/' . $safe_remote_user . '/config/externalpdns'
          or warn "Failed to secure permissions on cluster configuration: $!";
        print {$config_fh} "#version 2.0\n";
        print {$config_fh} "api_url=$api_url\n";
        print {$config_fh} "apikey=$apikey\n";
        print {$config_fh} "server_id=$server_id\n";
        print {$config_fh} "ns_config=$ns_config\n";
        print {$config_fh} "powerdns_ns=$powerdns_ns\n";
        print {$config_fh} "module=ExternalPDNS\n";
        print {$config_fh} "debug=$debug\n";
        close $config_fh;
    }
    else {
        warn "Could not write DNS trust configuration file: $!";
        return 0, "The trust relationship could not be established, please examine /usr/local/cpanel/logs/error_log for more information.";
    }

    # case 48931
    if ( !-e '/var/cpanel/cluster/root/config/externalpdns' && Whostmgr::ACLS::hasroot() ) {
        Cpanel::FileUtils::Copy::safecopy( '/var/cpanel/cluster/' . $safe_remote_user . '/config/externalpdns', '/var/cpanel/cluster/root/config/externalpdns' );
    }

    return ( 1, 'The trust relationship with External PDNS has been established.', '', 'externalpdns' );
}

sub get_config {
    my %config = (
        'options' => [
            {
                'name'        => 'api_url',
                'type'        => 'text',
                'locale_text' => 'PowerDNS API URL',
            },
            {
                'name'        => 'apikey',
                'type'        => 'text',
                'locale_text' => 'PowerDNS API key',
            },
            {
                'name'        => 'server_id',
                'type'        => 'text',
                'default'     => 'localhost',
                'locale_text' => 'PowerDNS Server ID',
            },
            {
                'name'        => 'ns_config',
                'type'        => 'radio',
                'default'     => 'force',
                'locale_text' => 'Method for handling NS lines',
                'options'     => [
                    { value => 'force',   label => 'Force NS records to PowerDNS nameservers', },
                    { value => 'ensure',  label => 'Ensure that PowerDNS nameservers are included', },
                    { value => 'default', label => 'Do not modify', },
                ],
            },
            {
                'name'        => 'powerdns_ns',
                'type'        => 'text',
                'locale_text' => 'PowerDNS Nameservers (comma-separated, e.g., ns1.example.com,ns2.example.com)',
            },
            {
                'name'        => 'debug',
                'locale_text' => 'Debug mode',
                'type'        => 'binary',
                'default'     => 0,
            },
        ],
        'name' => 'External PDNS',
    );

    return wantarray ? %config : \%config;
}

1;

