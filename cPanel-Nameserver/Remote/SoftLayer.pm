package Cpanel::NameServer::Remote::SoftLayer;

# cpanel - Cpanel/NameServer/Remote/SoftLayer.pm   Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
## no critic (RequireUseWarnings) -- pre-existing

use Cpanel::Logger               ();
use Cpanel::DnsUtils::RR         ();
use Cpanel::Encoder::URI         ();
use Cpanel::StringFunc::Match    ();
use Cpanel::ZoneFile             ();
use Cpanel::ZoneFile::Versioning ();
use Cpanel::JSON                 ();
use cPanel::PublicAPI            ();
use Cpanel::SocketIP             ();
use Cpanel::HTTP::Client         ();
use HTTP::Date                   ();
use MIME::Base64                 ();

## no critic (RequireUseWarnings) -- requires auditing for potential warnings
our $VERSION = '1.1';

use parent 'Cpanel::NameServer::Remote';

my %TYPE_MAP = (
    'SOA'   => 'soa',
    'CNAME' => 'cname',
    'PTR'   => 'ptr',
    'NS'    => 'ns',
    'A'     =>, 'a',
    'AAAA'  => 'aaaa',
    'MX'    =>, 'mx',
    'TXT'   => 'txt',
    'SRV'   => 'srv',
);

my %KNOWN_RECORD_FIELDS = (
    'ttl'               => undef,
    'type'              => undef,
    'host'              => undef,
    'data'              => undef,
    'preference'        => undef,
    'serial'            => undef,
    'minimum'           => undef,
    'expire'            => undef,
    'refresh'           => undef,
    'retry'             => undef,
    'responsiblePerson' => undef,
);

my %DATA_MAP = ( 'SOA' => 'rname', 'A' => 'address', 'NS' => 'nsdname', 'CNAME' => 'cname', 'MX' => 'exchange', 'AAAA' => 'address', 'TXT' => 'txtdata' );

our $API_HOST                = 'api.softlayer.com';
our $DNS_END_POINT           = '/rest/v3/SoftLayer_Dns_Domain';
our $DNSRECORD_END_POINT     = '/rest/v3/SoftLayer_Dns_Domain_ResourceRecord';
our $MX_DNSRECORD_END_POINT  = '/rest/v3/SoftLayer_Dns_Domain_ResourceRecord_MxType';
our $SOA_DNSRECORD_END_POINT = '/rest/v3/SoftLayer_Dns_Domain_ResourceRecord_SoaType';
our $SRV_DNSRECORD_END_POINT = '/rest/v3/SoftLayer_Dns_Domain_ResourceRecord_SrvType';
our $ACCOUNT_END_POINT       = '/rest/v3/SoftLayer_Account';

sub new {
    my ( $class, %OPTS ) = @_;
    my $self = {};

    my $user           = $OPTS{'user'};
    my $pass           = $OPTS{'apikey'};
    my $remote_timeout = $OPTS{'timeout'};
    my $dnspeer        = $OPTS{'host'};

    $self->{'name'}            = $dnspeer;
    $self->{'update_type'}     = $OPTS{'update_type'};
    $self->{'local_timeout'}   = $OPTS{'local_timeout'};
    $self->{'remote_timeout'}  = $OPTS{'remote_timeout'};
    $self->{'queue_callback'}  = $OPTS{'queue_callback'};
    $self->{'output_callback'} = $OPTS{'output_callback'};
    $self->{'ns_config'}       = $OPTS{'ns_config'} || '';
    $self->{'debug'}           = $OPTS{'debug'}     || 0;
    $self->{'sl_log'}          = Cpanel::Logger->new( { 'alternate_logfile' => '/usr/local/cpanel/logs/dnsadmin_softlayer_log' } );
    $self->{'auth'}            = MIME::Base64::encode_base64( "$user:$pass", '' );
    $self->{'ua'}              = Cpanel::HTTP::Client->new(
        timeout    => $remote_timeout,
        keep_alive => 1,
    );

    return bless $self, $class;
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub _get_zone_serial {
    my $self = shift;
    return $self->getByDomainName( @_, 'serial' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub _get_zone_updateDate {
    my $self = shift;
    return $self->getByDomainName( @_, 'updateDate' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub _get_zone_id {
    my $self = shift;
    return $self->getByDomainName( @_, 'id' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub getByDomainName {
    my ( $self, $zone, $record ) = @_;

    return $self->{'DOMAIN_INFO'}{$zone}->{$record} if exists $self->{'DOMAIN_INFO'}{$zone} && ref $self->{'DOMAIN_INFO'}{$zone};

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNS_END_POINT . '/ByDomainName/' . $zone . '.json', 'GET' );

    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        if ( ref $data eq 'ARRAY' ) {
            foreach my $hashref ( @{$data} ) {
                next                                                           if ref $hashref ne 'HASH';
                return ( $self->{'DOMAIN_INFO'}{$zone} = $hashref )->{$record} if $hashref->{'name'} eq $zone;
            }
        }
        return undef;
    }
    else {
        $self->{'error'} = "Failed to get zone $record: $!";
    }
    return 0;

}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub _fetch_domain_info {
    my $self = shift;

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $ACCOUNT_END_POINT . '/Domains' . '.json', 'GET' );

    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        $self->{'DOMAIN_INFO'} = { map { $_->{'name'} => $_ } @{$data} };
        return 1;
    }
    else {
        $self->{'error'} = "Failed to get zone ids: $!";
    }
    return 0;
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub _exec_json {
    my $self     = shift;
    my $uri      = shift;
    my $method   = shift;
    my $formdata = shift;

    my ($resp) = $self->{'ua'}->request(
        $method,
        "https://$API_HOST$uri",
        {
            headers => {
                'Accept'        => 'application/json',
                'Content-Type'  => 'application/json',
                'Authorization' => "Basic $self->{'auth'}",
            },
            ( defined $formdata ? ( content => $formdata ) : () )
        }
    );
    my ( $is_success, $page ) = ( $resp->{success}, \$resp->{content} );
    my $error = $is_success ? '' : "$resp->{status} $resp->{reason}";
    $self->{'publicapi'}{'error'} = $error;
    if ( $self->{'debug'} || !$is_success ) {
        $self->{'sl_log'}->info('---');
        $self->{'sl_log'}->info("$method $uri");
        $self->{'sl_log'}->info("ERROR: $error");
        $self->{'sl_log'}->info("FORMDATA: $formdata");

        my $logged_page = ref $page ? $$page : $page;
        $self->{'sl_log'}->info( "RESPONSE: " . $logged_page );
    }
    return ( $is_success, $error, $page );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub getallzones {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;

    if ( exists $self->{'DOMAIN_INFO'} || $self->_fetch_domain_info() ) {
        return $self->getzones( $unique_dns_request_id, { 'zones' => join( ",", keys %{ $self->{'DOMAIN_INFO'} } ) }, $rawdata );
    }

    my @check_action_results = $self->_check_action( "get all zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
    return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get all the zones remote server [$self->{'name'}] ($self->{'error'})" );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub cleandns {
    my ($self) = @_;
    $self->output("No cleanup needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub removezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );

    my $zone_id = $self->_get_zone_id( $dataref->{'zone'} );

    my @check_action_results = $self->_check_action( "remove the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
    return (@check_action_results)                                                                                                                                                                                                           if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to remove the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not fetch zone id : $self->{'publicapi'}->{'error'})" ) if !$zone_id;

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNS_END_POINT . '/' . $zone_id . '.json', 'DELETE' );

    delete $self->{'DOMAIN_INFO'}->{ $dataref->{'zone'} } if exists $self->{'DOMAIN_INFO'};

    $self->output("Removed zone $dataref->{'zone'} (zone id $zone_id)\n");

    if ( ref $page_ref && $$page_ref eq 'true' ) {
        return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
    }

    return $self->_check_action( "remove the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );

}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub removezones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    chomp( $dataref->{'zones'} );

    my $count = 0;

    foreach my $zone ( split( /\,/, ( $dataref->{'zones'} || $dataref->{'zone'} ) ) ) {
        $count++;
        $zone =~ s/^\s*|\s*$//g;
        my ( $removezone_status, $removezone_message ) = $self->removezone( $unique_dns_request_id . '_' . $count, { 'zone' => $zone } ) . "\n";

        {
            my @check_action_results = $self->_check_action( "remove the zone(s): " . ( $dataref->{'zones'} || $dataref->{'zone'} ), $Cpanel::NameServer::Constants::QUEUE );
            return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_IS_RECOVERABLE_ERROR];    # Only bail if we can recover later, otherwise keep going though the list.
        }

    }

    return $self->_check_action( "remove the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub reloadbind {
    my ($self) = @_;
    $self->output("No reload needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub reloadzones {
    my ($self) = @_;
    $self->output("No reload needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub reconfigbind {
    my ($self) = @_;
    $self->output("No reconfigneeded on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub savezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );

    my $zone_id = $self->_get_zone_id( $dataref->{'zone'} );

    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    my $zonefile_obj;
    eval { $zonefile_obj = Cpanel::ZoneFile->new( 'domain' => $dataref->{'zone'}, 'text' => $dataref->{'zonedata'} ); };
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone $dataref->{'zone'} on the remote server [$self->{'name'}] (Could not parse zonefile)" )                            if !$zonefile_obj;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone $dataref->{'zone'} on the remote server [$self->{'name'}] (Could not parse zonefile - $zonefile_obj->{'error'})" ) if $zonefile_obj->{'error'};

    if ( !$zone_id ) {

        # For compat, we auto create the zone
        my ( $status, $statusmsg ) = $self->addzoneconf( $unique_dns_request_id, { 'zone' => $dataref->{'zone'} } );
        return ( $status, "Unable to save the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;

        # NO NEED TO QUEUE THIS REQUEST if !$status as addzoneconf does a queue

        $zone_id = $self->_get_zone_id( $dataref->{'zone'} );

        {
            my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
            return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
        }
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] (Could not fetch zone id : $self->{'publicapi'}->{'error'})" ) if !$zone_id;
    }

    my $zone_serial = $self->_get_zone_serial( $dataref->{'zone'} );
    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] (Could not fetch zone serial)" ) if !$zone_serial;
    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNS_END_POINT . '/' . $zone_id . '/getResourceRecords.json', 'GET' );

    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;

    my $remote_dns_records = Cpanel::JSON::Load($$page_ref);
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not parse remote zone record)" ) if ref $remote_dns_records ne 'ARRAY';

    my $soa_record_id;
    my $soa_record_domain_id;
    for ( 0 .. $#{$remote_dns_records} ) {
        if ( $remote_dns_records->[$_]->{'type'} eq 'soa' ) {

            $soa_record_id                        = $remote_dns_records->[$_]->{'id'};
            $soa_record_domain_id                 = $remote_dns_records->[$_]->{'domainId'};
            $remote_dns_records->[$_]->{'serial'} = $zone_serial;
            last;
        }
    }
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not fetch domain record id or domainId)" ) if !$soa_record_id || !$soa_record_domain_id;

    # only one TTL are is permitted per host on softlayer's system
    my %SEEN_TTLS;
    my $dns_records;

    my @srv_records = ();

    foreach my $record ( @{ $zonefile_obj->{'dnszone'} } ) {

        #        print "[checking $record->{'type'}]\n";
        if ( !exists $TYPE_MAP{ $record->{'type'} } ) {
            $self->{'sl_log'}->info( 'Unsupported record type requested: ' . $record->{'type'} ) if $self->{'debug'};
            next;
        }

        #        print "[adding $record->{'type'}]\n";
        #next if ( $record->{'type'} eq 'SOA' || $record->{'type'} eq 'NS' );
        my $host = lc( _collapse_name( $dataref->{'zone'}, $record->{'name'}, $record->{'type'} ) );
        my $type = $TYPE_MAP{ $record->{'type'} };
        my $ttl  = $record->{'ttl'};
        my $data = $record->{ $DATA_MAP{ $record->{'type'} } } . ( ( $record->{'type'} eq 'CNAME' || $record->{'type'} eq 'SOA' || $record->{'type'} eq 'NS' || $record->{'type'} eq "MX" ) ? '.' : '' );

        if ( $record->{'type'} eq 'TXT' ) {
            $data = Cpanel::DnsUtils::RR::encode_and_split_dns_txt_record_value($data);
        }

        if ( $record->{'type'} eq 'SRV' ) {
            $data = $record->{'target'} . ( substr( $record->{'target'}, -1 ) eq "." ? "" : "." );    # add '.' if needed
        }

        if ( exists $SEEN_TTLS{$host} ) {
            $ttl = $SEEN_TTLS{$host};
        }
        else {
            $SEEN_TTLS{$host} = $ttl;
        }

        my $change = {
            'ttl'  => $ttl,
            'type' => $type,
            'host' => $host,
            'data' => $data,
            (
                exists $record->{'preference'}
                ? ( 'mxPriority' => $record->{'preference'} )
                : ()
            ),
            (
                $record->{'serial'}
                ? ( 'serial' => ( $zone_serial ? $zone_serial : $record->{'serial'} ) )
                : ()
            ),
            (
                $record->{'minimum'}
                ? ( 'minimum' => $record->{'minimum'} )
                : ()
            ),

            (
                $record->{'expire'}
                ? ( 'expire' => $record->{'expire'} )
                : ()
            ),

            (
                $record->{'refresh'}
                ? ( 'refresh' => $record->{'refresh'} )
                : ()
            ),

            (
                $record->{'retry'}
                ? ( 'retry' => $record->{'retry'} )
                : ()
            ),
            (
                $record->{'mname'}
                ? ( 'responsiblePerson' => $record->{'mname'} . '.' )
                : ()
            ),

            #minimum
            #refresh
            #retry
            #ttl
            #expire
            #responsiblePersonf
        };

        if ( $record->{'type'} eq 'SRV' ) {
            delete $change->{'host'};
            if ( $host =~ /^(.+)\._(.+)$/ ) {
                $change->{'service'} = $1;
                my $second = $2;
                if ( $second =~ /^(.+)\.(.+)$/ ) {
                    $change->{'protocol'} = '_' . $1;
                    $change->{'host'}     = $2;
                }
                else {
                    $change->{'protocol'} = '_' . $second;
                }
            }
            else {
                $change->{'service'}  = $host;
                $change->{'protocol'} = '_tcp';
            }
            $change->{'priority'} = $record->{'priority'};
            $change->{'weight'}   = $record->{'weight'};
            $change->{'port'}     = $record->{'port'};
            $change->{'domainId'} = $zone_id;
            push @srv_records, $change;
        }

        if ( $record->{'type'} eq 'SOA' ) {
            if ( $change->{'expire'} < 604800 ) {
                $change->{'expire'} = 604801;
            }
        }

        unless ( $record->{'type'} eq 'NS' && $self->{'ns_config'} eq 'force' ) {
            push @{$dns_records}, $change;
        }
    }

    # option force = force NS records to be dns1.vps.net (default)
    # option ensure = add NS records for dns1.vps.net
    # option any = leave records intact
    if ( $self->{'ns_config'} eq 'force' ) {
        push @{$dns_records}, { 'ttl' => 86400, 'type' => $TYPE_MAP{'NS'}, 'host', '@', 'data' => 'ns1.softlayer.com.' }, { 'ttl' => 86400, 'type' => $TYPE_MAP{'NS'}, 'host', '@', 'data' => 'ns2.softlayer.com.' };
    }
    elsif ( $self->{'ns_config'} eq 'ensure' ) {
        push @{$dns_records}, { 'ttl' => 86400, 'type' => $TYPE_MAP{'NS'}, 'host', '@', 'data' => 'ns1.softlayer.com.' } if !grep { $_->{'type'} eq $TYPE_MAP{'NS'} && $_->{'data'} eq 'ns1.softlayer.com.' } @{$dns_records};
        push @{$dns_records}, { 'ttl' => 86400, 'type' => $TYPE_MAP{'NS'}, 'host', '@', 'data' => 'ns2.softlayer.com.' } if !grep { $_->{'type'} eq $TYPE_MAP{'NS'} && $_->{'data'} eq 'ns2.softlayer.com.' } @{$dns_records};
    }

    my %NEW_RECORDS = map { _sorted_hashref_txt($_) => $_ } @{$dns_records};
    my %OLD_RECORDS = map { _sorted_hashref_txt($_) => $_ } @{$remote_dns_records};

    foreach my $record ( keys %NEW_RECORDS ) {
        $NEW_RECORDS{$record}->{'domainId'} = $zone_id;
        if ( $OLD_RECORDS{$record} ) {
            delete $NEW_RECORDS{$record};
            delete $OLD_RECORDS{$record};
        }
    }

    if ( scalar keys %OLD_RECORDS ) {
        foreach my $record ( values %OLD_RECORDS ) {
            next if $record->{'type'} eq 'soa';
            next if $record->{'type'} eq 'ns' && $record->{'data'} eq 'ns1.softlayer.com.';
            next if $record->{'type'} eq 'ns' && $record->{'data'} eq 'ns2.softlayer.com.';
            my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNSRECORD_END_POINT . '/' . $record->{'id'} . '.json', 'DELETE' );
            {
                my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }
        }

    }
    if ( grep { $_->{'type'} ne 'mx' && $_->{'type'} ne 'soa' && $_->{'type'} ne 'srv' } values %NEW_RECORDS ) {
        foreach my $record ( values %NEW_RECORDS ) {
            if ( $record->{'type'} eq 'srv' || $record->{'type'} eq 'soa' || $record->{'type'} eq 'mx' ) {
                next;
            }
            my $json = Cpanel::JSON::Dump( { 'parameters' => [$record] } );
            my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNSRECORD_END_POINT . '.json', 'POST', $json );
            {
                my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }
        }
    }
    if ( grep { $_->{'type'} eq 'soa' } values %NEW_RECORDS ) {
        foreach my $record ( grep { $_->{'type'} eq 'soa' } values %NEW_RECORDS ) {
            delete $record->{'serial'};

            #delete $record->{'data'};
            #delete $record->{'host'};
            #$record->{'id'} = $soa_record_id;
            my $json = Cpanel::JSON::Dump( { 'parameters' => [$record] } );
            my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNS_END_POINT . '/' . $soa_record_domain_id . '/ResourceRecords/' . $soa_record_id . '.json', 'PUT', $json );
            {
                my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }
        }
    }
    if ( grep { $_->{'type'} eq 'srv' } values %NEW_RECORDS ) {
        foreach my $record (@srv_records) {
            my $json = Cpanel::JSON::Dump( { 'parameters' => [$record] } );

            my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $SRV_DNSRECORD_END_POINT . '.json', 'POST', $json );
            {
                my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }
        }
    }
    if ( grep { $_->{'type'} eq 'mx' } values %NEW_RECORDS ) {
        foreach my $record ( grep { $_->{'type'} eq 'mx' } values %NEW_RECORDS ) {
            my $json = Cpanel::JSON::Dump( { 'parameters' => [$record] } );
            my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $MX_DNSRECORD_END_POINT . '.json', 'POST', $json );
            {
                my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }
        }
    }
    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub synczones {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;

    $rawdata = $self->_strip_dnsuniqid($rawdata);

    my %CZONETABLE = map { ( split( /=/, $_, 2 ) )[ 0, 1 ] } split( /\&/, $rawdata );
    delete @CZONETABLE{ grep( !/^cpdnszone-/, keys %CZONETABLE ) };

    if ( !exists $self->{'DOMAIN_INFO'} && !$self->_fetch_domain_info() ) {
        {
            my @check_action_results = $self->_check_action( "sync zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
            return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
        }

        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to sync zones to the remote server [$self->{'name'}] (Could not fetch domain id: Unknown error)" );
    }

    local $self->{'ua'}->{'timeout'} = ( ( int( $self->{'local_timeout'} / 2 ) > $self->{'remote_timeout'} ) ? int( $self->{'local_timeout'} / 2 ) : $self->{'remote_timeout'} );    #allow long timeout
    my $zone;
    my $count = 0;
    my ( $status, $statusmsg );
    foreach my $zonekey ( keys %CZONETABLE ) {
        $zone = $zonekey;
        $zone =~ s/^cpdnszone-//g;
        if ( !exists $self->{'DOMAIN_INFO'}->{$zone} ) {
            ( $status, $statusmsg ) = $self->addzoneconf( $unique_dns_request_id . '_' . ++$count, { 'zone' => Cpanel::Encoder::URI::uri_decode_str($zone) } );
            return ( $status, $statusmsg ) if $self->is_recoverable_error($status);
        }
        ( $status, $statusmsg ) = $self->savezone( $unique_dns_request_id . '_' . ++$count, { 'zone' => Cpanel::Encoder::URI::uri_decode_str($zone), 'zonedata' => Cpanel::Encoder::URI::uri_decode_str( $CZONETABLE{$zonekey} ) } );
        return ( $status, $statusmsg ) if $self->is_recoverable_error($status);
    }

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub quickzoneadd {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    my ( $addstatus, $addstatus_message ) = $self->addzoneconf( $unique_dns_request_id . '_1', $dataref );

    return ( $addstatus, $addstatus_message ) if !$addstatus;

    my ( $savestatus, $savestatus_message ) = $self->savezone( $unique_dns_request_id . '_2', $dataref );

    return ( $savestatus, $savestatus_message ) if !$savestatus;

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub addzoneconf {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );

    my $json = Cpanel::JSON::Dump(
        {
            'parameters' => [
                {
                    "name"            => $dataref->{'zone'},
                    'resourceRecords' => []
                }
            ]
        }
    );
    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNS_END_POINT . '.json', 'POST', $json );

    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        if ( ref $data eq 'HASH' ) {
            if ( exists $data->{'error'} ) {
                if ( $data->{'error'} =~ /already exists/i ) {
                    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
                }
                else {
                    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to add the zone $dataref->{'zone'} on the remote server [$self->{'name'}] ($data->{'error'})" );
                }
            }
            elsif ( exists $data->{'id'} ) {
                $self->{'DOMAIN_INFO'}{ $dataref->{'zone'} } = $data->{'id'};
            }
        }
    }

    return $self->_check_action("add the zone: $dataref->{'zone'}");
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub getzone {
    my $self = shift;
    my ( $status, $statusmsg, $zonedata ) = $self->_getzone(@_);
    $self->output($zonedata) if $zonedata;
    return ( $status, $statusmsg );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub _getzone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );

    my $zone_id = $self->_get_zone_id( $dataref->{'zone'} );
    {
        my @check_action_results = $self->_check_action( "get the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }
    if ( !$zone_id ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not fetch zone id)" );
    }

    my $zone_updateDate = $self->_get_zone_updateDate( $dataref->{'zone'} );
    {
        my @check_action_results = $self->_check_action( "get the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }
    if ( !$zone_updateDate ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not fetch zone id)" );
    }

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( $DNS_END_POINT . '/' . $zone_id . '/ZoneFileContents.json', 'GET' );

    {
        my @check_action_results = $self->_check_action( "get the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;

    my $data = Cpanel::JSON::Load($$page_ref);

    if ( !$data ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone $dataref->{'zone'} from the remote server [$self->{'name'}] (No zone data returned from remote server)" );
    }

    my $update_time = HTTP::Date::str2time($zone_updateDate);

    $data = Cpanel::ZoneFile::Versioning::version_line( '', $update_time, $self->{'name'} ) . "\n" . $data;

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK', $data );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub getzones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    chomp( $dataref->{'zones'} );

    my $count = 0;
    my ( $status, $statusmsg, $zonedata );
    foreach my $zone ( split( /\,/, ( $dataref->{'zones'} || $dataref->{'zone'} ) ) ) {
        ( $status, $statusmsg, $zonedata ) = $self->_getzone( $unique_dns_request_id . '_' . ++$count, { 'zone' => $zone } );
        last if $self->is_recoverable_error($status);
        next if ( !$status || !$zonedata );
        $self->output( 'cpdnszone-' . Cpanel::Encoder::URI::uri_encode_str($zone) . '=' . Cpanel::Encoder::URI::uri_encode_str($zonedata) . '&' );
    }
    return ( $status,                                              $statusmsg ) if defined $status;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zones " . ( $dataref->{'zones'} || $dataref->{'zone'} ) . " from the remote server [$self->{'name'}] (unknown error)" );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub getzonelist {
    my ($self) = @_;

    if ( exists $self->{'DOMAIN_INFO'} || $self->_fetch_domain_info() ) {
        $self->output( join( "\n", keys %{ $self->{'DOMAIN_INFO'} } ) );
    }

    else {

        my @check_action_results = $self->_check_action( "get the zone list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;

    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub zoneexists {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );

    if ( $self->_get_zone_id( $dataref->{'zone'} ) ) {
        $self->output('1');
    }
    else {
        $self->output('0');
    }

    return $self->_check_action("check for the existance of $dataref->{'zone'}");
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub getips {
    my ($self) = @_;
    my @ips;
    push @ips, Cpanel::SocketIP::_resolveIpAddress('ns1.softlayer.com');
    push @ips, Cpanel::SocketIP::_resolveIpAddress('ns2.softlayer.com');
    $self->output( join( "\n", @ips ) . "\n" );
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH SoftLayer -jnk 2/14/2011
sub getpath {
    my ($self) = @_;
    $self->output( join( "\n", map { $self->{'name'} . ' ' . $_ } ( 'ns1.softlayer.com', 'ns2.softlayer.com' ) ) . "\n" );
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub version {
    return $VERSION;
}

sub _collapse_name {
    my $zone = shift;
    my $name = shift;
    my $type = shift;

    if ( Cpanel::StringFunc::Match::endmatch( $name, '.' . $zone . '.' ) ) {
        $name =~ s/\Q.$zone.\E$//g;
    }
    elsif ( $name eq "$zone." && $type ne 'TXT' ) {
        $name = '@';
    }

    return $name;
}

sub _sorted_hashref_txt {
    my $hashref = shift;
    return join(
        '_____', map { exists $KNOWN_RECORD_FIELDS{$_} && defined $hashref->{$_} && ( $_ ne 'responsiblePerson' || $hashref->{'type'} eq 'soa' ) ? ( $_, $hashref->{$_} ) : () }
          sort keys %$hashref
    );    #sort is important for order;
}

1;
