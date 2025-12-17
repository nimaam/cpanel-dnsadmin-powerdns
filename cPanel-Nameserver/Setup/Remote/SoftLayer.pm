package Cpanel::NameServer::Setup::Remote::SoftLayer;

# cpanel - Cpanel/NameServer/Setup/Remote/SoftLayer.pm
#                                                  Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use Cpanel::HTTP::Client    ();
use Cpanel::FileUtils::Copy ();
use Whostmgr::ACLS          ();
use MIME::Base64            ();

## no critic (RequireUseWarnings) -- requires auditing for potential warnings

Whostmgr::ACLS::init_acls();

sub setup {
    my ( $self, %OPTS ) = @_;

    if ( !Whostmgr::ACLS::checkacl('clustering') ) {
        return 0, 'User does not have the clustering ACL enabled.';
    }

    return 0, 'No user given'                        if !defined $OPTS{'user'};
    return 0, 'No apikey given'                      if !defined $OPTS{'apikey'};
    return 0, 'No Namserver Configuration Specified' if !defined $OPTS{'ns_config'};

    my $user      = $OPTS{'user'};
    my $apikey    = $OPTS{'apikey'};
    my $ns_config = $OPTS{'ns_config'};

    # Validate debug parameter.
    # This is a boolean.
    # We do not care, nor want, the passed value, just its truthyness.

    my $debug = $OPTS{'debug'} ? 1 : 0;

    # Validate user paramenter.

    $user =~ tr/\r\n\f\0//d;
    return 0, 'Invalid user given' if !$user;

    # Validate apikey paramenter.

    $apikey =~ tr/\r\n\f\0//d;
    return 0, 'Invalid apikey given' if !$apikey;

    # Validate ns_config paramenter.

    if ( $ns_config !~ /\A(?:force|ensure|default)\z/ ) {
        return ( 0, 'Invalid nameserver configuration value given' );
    }

    # do some stuff to write out the config files.
    my $auth = MIME::Base64::encode_base64( "$user:$apikey", '' );
    my $ua   = Cpanel::HTTP::Client->new(
        timeout    => 60,
        keep_alive => 1,
    );

    my $resp = $ua->get(
        'https://api.softlayer.com/rest/v3/SoftLayer_Account',
        {
            headers => {
                'Accept'        => 'application/json',
                'Authorization' => "Basic $auth",
            }
        }
    );

    if ( !$resp->{'success'} ) {
        return 0, 'There was an error trying to connect to SoftLayer\'s servers, please verify your credentials';
    }

    my $safe_remote_user = $ENV{'REMOTE_USER'};
    $safe_remote_user =~ s/\///g;
    mkdir '/var/cpanel/cluster',                                  0700 if !-e '/var/cpanel/cluster';
    mkdir '/var/cpanel/cluster/' . $safe_remote_user,             0700 if !-e '/var/cpanel/cluster/' . $safe_remote_user;
    mkdir '/var/cpanel/cluster/' . $safe_remote_user . '/config', 0700 if !-e '/var/cpanel/cluster/' . $safe_remote_user . '/config';

    if ( open my $config_fh, '>', '/var/cpanel/cluster/' . $safe_remote_user . '/config/softlayer' ) {
        chmod 0600, '/var/cpanel/cluster/' . $safe_remote_user . '/config/softlayer'
          or warn "Failed to secure permissions on cluster configuration: $!";
        print {$config_fh} "#version 2.0\nuser=$user\nns_config=$ns_config\napikey=$apikey\nmodule=SoftLayer\ndebug=$debug\n";
        close $config_fh;
    }
    else {
        warn "Could not write DNS trust configuration file: $!";
        return 0, "The trust relationship could not be established, please examine /usr/local/cpanel/logs/error_log for more information.";
    }

    # case 48931
    if ( !-e '/var/cpanel/cluster/root/config/softlayer' && Whostmgr::ACLS::hasroot() ) {
        Cpanel::FileUtils::Copy::safecopy( '/var/cpanel/cluster/' . $safe_remote_user . '/config/softlayer', '/var/cpanel/cluster/root/config/softlayer' );
    }

    return ( 1, 'The trust relationship with SoftLayer has been established.', '', 'softlayer' );
}

sub get_config {
    my %config = (
        'options' => [
            {
                'name'        => 'user',
                'type'        => 'text',
                'locale_text' => 'SoftLayer API user',
            },
            {
                'name'        => 'apikey',
                'type'        => 'text',
                'locale_text' => 'SoftLayer API key',
            },
            {
                'name'        => 'ns_config',
                'type'        => 'radio',
                'default'     => 'force',
                'locale_text' => 'Method for handling NS lines',
                'options'     => [
                    { value => 'force',   label => 'Force NS records to SoftLayer servers', },
                    { value => 'ensure',  label => 'Ensure that SoftLayer servers are included', },
                    { value => 'default', label => 'Do not modify', },
                ],
            },
            {
                'name'        => 'debug',
                'locale_text' => 'Debug mode',
                'type'        => 'binary',
                'default'     => 0,
            },
        ],
        'name'       => 'SoftLayer',
        'companyids' => [ 150, 477, 425, 7 ],    # Company IDs that this module should show up for
    );

    return wantarray ? %config : \%config;
}

1;
