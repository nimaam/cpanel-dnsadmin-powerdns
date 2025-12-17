package Cpanel::NameServer::Remote::VPSNET;

# cpanel - Cpanel/NameServer/Remote/VPSNET.pm      Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
## no critic(RequireUseWarnings)

use HTTP::Date                    ();
use Cpanel::Encoder::URI          ();
use Cpanel::StringFunc::Match     ();
use Cpanel::NameServer::Constants ();
use Cpanel::ZoneFile              ();
use Cpanel::JSON                  ();
use Cpanel::HTTP::Client          ();
use MIME::Base64                  ();

our $VERSION       = '1.1';
our $USE_TEMPLATES = 0;
use parent 'Cpanel::NameServer::Remote';

my %TYPE_MAP = ( 'SOA' => 'soa',   'CNAME' => 'cname',   'NS' => 'ns', 'A' =>, 'a', 'AAAA' => 'aaaa', 'MX' =>, 'mx', 'TXT' => 'txt' );
my %DATA_MAP = ( 'SOA' => 'rname', 'A'     => 'address', 'NS' => 'nsdname', 'CNAME' => 'cname', 'MX' => 'exchange', 'AAAA' => 'address', 'TXT' => 'txtdata' );

our $API_HOST = 'api.vps.net';

sub new {
    my ( $class, %OPTS ) = @_;
    my $self = {%OPTS};
    bless $self, $class;

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
    $self->{'auth'}            = MIME::Base64::encode_base64( "$user:$pass", '' );

    $self->{'ua'} = Cpanel::HTTP::Client->new(
        timeout    => $remote_timeout,
        keep_alive => 1,
    );

    if ( $self->{'debug'} ) {
        foreach my $key ( keys %{$self} ) {
            print STDERR __PACKAGE__ . " DEBUG:new [$key]=[$self->{$key}]\n";
        }
    }

    if ( !$pass || !$user || !$dnspeer ) {
        print STDERR __PACKAGE__ . " : Missing one of the required keys: user, apikey, or host\n";
    }

    return $self;
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub _get_zone_id {
    my ( $self, $zone ) = @_;

    if ( exists $self->{'DOMAIN_IDS'} ) {
        return exists $self->{'DOMAIN_IDS'}->{$zone} ? $self->{'DOMAIN_IDS'}->{$zone} : undef;
    }
    if ( $self->_fetch_domain_ids() ) {
        return exists $self->{'DOMAIN_IDS'}->{$zone} ? $self->{'DOMAIN_IDS'}->{$zone} : undef;
    }
    return undef;
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub _fetch_dns_templates {
    my $self = shift;

    #
    #{"domain":{"name":"nickcpaneltest.com","created_at":"2011-01-23T01:50:58-06:00","updated_at":"2011-01-23T01:50:58-06:00","id":40903,"ip_address":"127.0.0.1"}}
    #

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/dns_templates.api10json', 'GET' );

    print STDERR __PACKAGE__ . " :_fetch_dns_templates: (dns_templates.api10json) $$page_ref\n" if $self->{'debug'};

    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        $self->{'DNS_TEMPLATES'} = { map { $_->{'dns_template'}->{'template_name'} => $_->{'dns_template'}->{'id'} } @{$data} };
        return 1;
    }
    else {
        $self->{'error'} = "Failed to get dns templates: $!";
    }
    return 0;
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub _fetch_domain_ids {
    my $self = shift;

    #
    #{"domain":{"name":"nickcpaneltest.com","created_at":"2011-01-23T01:50:58-06:00","updated_at":"2011-01-23T01:50:58-06:00","id":40903,"ip_address":"127.0.0.1"}}
    #

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/domains.api10json', 'GET' );

    print STDERR __PACKAGE__ . " :__fetch_domain_ids: (domains.api10json) $$page_ref\n" if $self->{'debug'};

    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        $self->{'DOMAIN_IDS'} = { map { $_->{'domain'}->{'name'} => $_->{'domain'}->{'id'} } @{$data} };
        return 1;
    }
    else {
        $self->{'error'} = "Failed to get zone ids: $!";
    }
    return 0;
}

sub _get {
    my $self = shift;
    my $uri  = shift;

    my ($resp) = $self->{'ua'}->request(
        'GET',
        "https://$API_HOST$uri",
        {
            headers => {
                'Accept'        => 'application/json',
                'Authorization' => "Basic $self->{'auth'}",
            },
        }
    );
    my ( $is_success, $page ) = ( $resp->{success}, \$resp->{content} );
    my $error = $is_success ? '' : "$resp->{status} $resp->{reason}";
    $self->{'publicapi'}{'error'} = $error;
    return ( $is_success, $error, $page );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
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
    return ( $is_success, $error, $page );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub getallzones {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;

    if ( exists $self->{'DOMAIN_IDS'} || $self->_fetch_domain_ids() ) {
        return $self->getzones( $unique_dns_request_id, { 'zones' => join( ",", keys %{ $self->{'DOMAIN_IDS'} } ) }, $rawdata );
    }

    my @check_action_results = $self->_check_action( "get all zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
    return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get all the zones remote server [$self->{'name'}] ($self->{'error'})" );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub cleandns {
    my ($self) = @_;
    $self->output("No cleanup needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub removezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );

    my $zone_id = $self->_get_zone_id( $dataref->{'zone'} );

    my @check_action_results = $self->_check_action( "remove the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
    return (@check_action_results)                                                                                                                                                                                                           if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to remove the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not fetch zone id : $self->{'publicapi'}->{'error'})" ) if !$zone_id;

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/domains/' . $zone_id . '.api10json', 'DELETE' );

    # Error checking of _exec_json is done by _check_action

    delete $self->{'DOMAIN_IDS'}->{ $dataref->{'zone'} } if exists $self->{'DOMAIN_IDS'};

    $self->output("Removed zone $dataref->{'zone'} (zone id $zone_id)\n");

    return $self->_check_action( "remove the zone: $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
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

    return $self->_check_action( "remove the zone(s): " . ( $dataref->{'zones'} || $dataref->{'zone'} ), $Cpanel::NameServer::Constants::QUEUE );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub reloadbind {
    my ($self) = @_;
    $self->output("No reload needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub reloadzones {
    my ($self) = @_;
    $self->output("No reload needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub reconfigbind {
    my ($self) = @_;
    $self->output("No reload needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub savezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );

    my $zone_id = $self->_get_zone_id( $dataref->{'zone'} );
    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

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

    my $zonefile_obj;
    eval { $zonefile_obj = Cpanel::ZoneFile->new( 'domain' => $dataref->{'zone'}, 'text' => $dataref->{'zonedata'} ); };
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone $dataref->{'zone'} on the remote server [$self->{'name'}] (Could not parse zonefile)" ) if !$zonefile_obj;

    # only one TTL are is permitted per host on vps.net's system
    my %SEEN_TTLS;
    my @dns_records;
    foreach my $record ( @{ $zonefile_obj->{'dnszone'} } ) {
        next if !exists $TYPE_MAP{ $record->{'type'} };

        my $host = lc( _collapse_name( $dataref->{'zone'}, $record->{'name'} ) );
        my $type = $TYPE_MAP{ $record->{'type'} };
        my $ttl  = $record->{'ttl'};
        if ( exists $SEEN_TTLS{$host} ) {
            $ttl = $SEEN_TTLS{$host};
        }
        else {
            $SEEN_TTLS{$host} = $ttl;
        }

        push @dns_records,
          {
            'ttl'  => $ttl,
            'type' => $type,
            'host' => $host,
            'data' => lc( $record->{ $DATA_MAP{ $record->{'type'} } } . ( ( $record->{'type'} eq 'MX' || $record->{'type'} eq 'CNAME' || $record->{'type'} eq 'NS' ) ? '.' : '' ) ),
            ( $record->{'type'} eq 'MX' ? ( 'mx_priority' => $record->{'preference'} ) : () ),
          }
          unless ( $record->{'type'} eq 'NS' && $self->{'ns_config'} eq 'force' );
    }

    # option force = force NS records to be dns1.vps.net (default)
    # option ensure = add NS records for dns1.vps.net
    # option any = leave records intact
    if ( $self->{'ns_config'} eq 'force' ) {
        push @dns_records, { 'ttl' => 86400, 'type' => 'NS', 'host', '@', 'data' => 'dns1.vps.net.' }, { 'ttl' => 86400, 'type' => 'NS', 'host', '@', 'data' => 'dns2.vps.net.' };
    }
    elsif ( $self->{'ns_config'} eq 'ensure' ) {
        push @dns_records, { 'ttl' => 86400, 'type' => 'NS', 'host', '@', 'data' => 'dns1.vps.net.' } if !grep { $_->{'type'} eq 'NS' && $_->{'data'} eq 'dns1.vps.net.' } @dns_records;
        push @dns_records, { 'ttl' => 86400, 'type' => 'NS', 'host', '@', 'data' => 'dns2.vps.net.' } if !grep { $_->{'type'} eq 'NS' && $_->{'data'} eq 'dns2.vps.net.' } @dns_records;
    }

    my $json = Cpanel::JSON::Dump( { 'domain_records' => [ map { ( { 'domain_record' => $_ } ) } @dns_records ] } );
    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/domains/' . $zone_id . '/records/update_records.api10json', 'PUT', $json );

    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone $dataref->{'zone'} on the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;

    my $data = Cpanel::JSON::Load($$page_ref);

    if ( !ref $data || !$data->{'message'} ) {
        $self->queue_request($Cpanel::NameServer::Constants::ERROR_INVALID_RESPONSE_LOGGED);
        return ( $Cpanel::NameServer::Constants::ERROR_INVALID_RESPONSE_LOGGED, __PACKAGE__ . ": Unable to save the zone $dataref->{'zone'} on the remote server [$self->{'name'}] (Invalid Response from server: $data->{'error'})" );
    }

    $self->output("Saved zone $dataref->{'zone'} ($data->{'message'})\n");

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub synczones {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;

    $rawdata = $self->_strip_dnsuniqid($rawdata);

    my %CZONETABLE = map { ( split( /=/, $_, 2 ) )[ 0, 1 ] } split( /\&/, $rawdata );
    delete @CZONETABLE{ grep( !/^cpdnszone-/, keys %CZONETABLE ) };

    if ( !exists $self->{'DOMAIN_IDS'} && !$self->_fetch_domain_ids() ) {
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
        if ( !exists $self->{'DOMAIN_IDS'}->{$zone} ) {
            ( $status, $statusmsg ) = $self->addzoneconf( $unique_dns_request_id . '_' . ++$count, { 'zone' => Cpanel::Encoder::URI::uri_decode_str($zone) } );
            return ( $status, $statusmsg ) if $self->is_recoverable_error($status);
        }
        ( $status, $statusmsg ) = $self->savezone( $unique_dns_request_id . '_' . ++$count, { 'zone' => Cpanel::Encoder::URI::uri_decode_str($zone), 'zonedata' => Cpanel::Encoder::URI::uri_decode_str( $CZONETABLE{$zonekey} ) } );
        return ( $status, $statusmsg ) if $self->is_recoverable_error($status);
    }

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub quickzoneadd {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    my ( $addstatus, $addstatus_message ) = $self->addzoneconf( $unique_dns_request_id . '_1', $dataref );

    return ( $addstatus, $addstatus_message ) if $addstatus != $Cpanel::NameServer::Constants::SUCCESS;

    my ( $savestatus, $savestatus_message ) = $self->savezone( $unique_dns_request_id . '_2', $dataref );

    return ( $savestatus, $savestatus_message ) if $savestatus != $Cpanel::NameServer::Constants::SUCCESS;

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub addzoneconf {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );

    if ($USE_TEMPLATES) {
        if ( !exists $self->{'DNS_TEMPLATES'} && !exists $self->{'DNS_TEMPLATES'}->{'cPanel'} ) {
            $self->_fetch_dns_templates();
            {
                my @check_action_results = $self->_check_action( "add the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }
        }

        if ( !exists $self->{'DNS_TEMPLATES'} || !exists $self->{'DNS_TEMPLATES'}->{'cPanel'} ) {

            #FIXME: Would be nice if we could just create an empty record set with a special built in template like -1 ?
            my $json = Cpanel::JSON::Dump(
                {
                    'dns_template' => {
                        'template_name' => 'cPanel',
                    }
                }
            );

            my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/dns_templates.api10json', 'POST', $json );
            {
                my @check_action_results = $self->_check_action( "add the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }
            return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to add the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] (Could not create template: $$page_ref: $statusmsg)" ) if $$page_ref !~ /cPanel/;

            $self->_fetch_dns_templates();
            {
                my @check_action_results = $self->_check_action( "add the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
                return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
            }

        }

        if ( !exists $self->{'DNS_TEMPLATES'} || !exists $self->{'DNS_TEMPLATES'}->{'cPanel'} ) {
            return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to add the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] (Could not create template)" );
        }
    }

    my $json = Cpanel::JSON::Dump(
        {
            'domain' => {
                'name'            => $dataref->{'zone'},
                'custom_template' => $USE_TEMPLATES ? $self->{'DNS_TEMPLATES'}->{'cPanel'} : '',
                'ip_address'      => '127.0.0.1',
            }
        }
    );
    print STDERR "$json\n";

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/domains.api10json', 'POST', $json );

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to add the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] (Could not create zone: $$page_ref: $statusmsg)" ) if $$page_ref =~ /^false$/i;

    delete $self->{'DOMAIN_IDS'};    #the id is not returned

    return $self->_check_action( "add the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub getzone {
    my $self = shift;
    my ( $status, $statusmsg, $zone_ref ) = $self->_getzone(@_);
    if ( ref $zone_ref ) {
        $self->output( join( "\n", @{$zone_ref} ) );
    }
    return ( $status, $statusmsg );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub _getzone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );

    my $zone_id = $self->_get_zone_id( $dataref->{'zone'} );

    {
        my @check_action_results = $self->_check_action( "get the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    if ( !$zone_id ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not fetch zone id : $self->{'publicapi'}->{'error'})" );
    }

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/domains/' . $zone_id . '.api10json', 'GET' );

    {
        my @check_action_results = $self->_check_action( "get the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;
    my $data = Cpanel::JSON::Load($$page_ref);

    print STDERR __PACKAGE__ . " :_getzone: ($zone_id.api10json) $$page_ref\n" if $self->{'debug'};

    my $serial      = $data->{'domain'}->{'serial'} || 1000000000;
    my $update_time = HTTP::Date::str2time( $data->{'domain'}->{'updated_at'} );

    ( $status, $statusmsg, $page_ref ) = $self->_exec_json( '/domains/' . $zone_id . '/records.api10json?new', 'GET' );
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;

    print STDERR __PACKAGE__ . " :_getzone: (records.api10json?new) $$page_ref\n" if $self->{'debug'};

    $data = Cpanel::JSON::Load($$page_ref);
    my $zonefile_obj;
    my $zone_ref;
    if ( ref $data eq 'ARRAY' ) {
        my $zone_text = '';
        foreach my $line ( sort { ( ( $b->{'type'} eq 'soa' ) <=> ( $a->{'type'} eq 'soa' ) ) || ( $a->{'type'} cmp $b->{'type'} || $a->{'host'} cmp $b->{'host'} ) } @{$data} ) {
            if ( $line->{'type'} eq 'soa' ) {
                $zone_text .= join( "\t", $dataref->{'zone'} . '.', $line->{'ttl'}, 'IN', uc( $line->{'type'} ), $line->{'data'}, 'admin.', "($serial 3600 300 604800 3600)" ) . "\n";
            }
            elsif ( $line->{'type'} eq 'mx' ) {
                $zone_text .= join( "\t", $line->{'host'}, $line->{'ttl'}, 'IN', uc( $line->{'type'} ), $line->{'mx_priority'}, $line->{'data'} ) . "\n";
            }
            else {
                $zone_text .= join( "\t", $line->{'host'}, $line->{'ttl'}, 'IN', uc( $line->{'type'} ), $line->{'data'} ) . "\n";
            }
        }
        eval { $zonefile_obj = Cpanel::ZoneFile->new( 'domain' => $dataref->{'zone'}, 'text' => $zone_text, 'update_time' => $update_time, 'hostname' => 'VPSNET' ); };
        $zone_ref = $zonefile_obj->serialize();
    }

    {
        my @check_action_results = $self->_check_action( "get the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    if ( ref $data ne 'ARRAY' ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone $dataref->{'zone'} from the remote server [$self->{'name'}] (Invalid JSON Returned)" );
    }
    if ( !$zonefile_obj ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not parse zone data)" );
    }
    if ( !ref $zone_ref ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone $dataref->{'zone'} from the remote server [$self->{'name'}] (Could not serialize zone data)" );
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK', $zone_ref );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub getzones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    chomp( $dataref->{'zones'} );

    my $count = 0;
    my ( $status, $statusmsg, $zone_ref );
    foreach my $zone ( split( /\,/, ( $dataref->{'zones'} || $dataref->{'zone'} ) ) ) {
        ( $status, $statusmsg, $zone_ref ) = $self->_getzone( $unique_dns_request_id . '_' . ++$count, { 'zone' => $zone } );
        last if $self->is_recoverable_error($status);       # Going to be fatal for now so we would have to retry later
        next if ( !$status || ref $zone_ref ne 'ARRAY' );
        my $zonedata = join( "\n", @{$zone_ref} );
        $self->output( 'cpdnszone-' . Cpanel::Encoder::URI::uri_encode_str($zone) . '=' . Cpanel::Encoder::URI::uri_encode_str($zonedata) . '&' );
    }
    return ( $status,                                              $statusmsg ) if defined $status;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zones " . ( $dataref->{'zones'} || $dataref->{'zone'} ) . " from the remote server [$self->{'name'}] (unknown error)" );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub getzonelist {
    my ($self) = @_;

    if ( exists $self->{'DOMAIN_IDS'} || $self->_fetch_domain_ids() ) {
        $self->output( join( "\n", keys %{ $self->{'DOMAIN_IDS'} } ) );
    }
    else {
        my @check_action_results = $self->_check_action( "get the zone list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub zoneexists {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );

    $self->output( ( $self->_get_zone_id( $dataref->{'zone'} ) ) ? '1' : '0' );

    return $self->_check_action( "determine if the zone $dataref->{'zone'} exists", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub getips {
    my ($self) = @_;

    my ( $status, $statusmsg, $page_ref ) = $self->_get("/domains/dns_hosts.api10json");

    my $valid_data = 0;
    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        if ( ref $data eq 'ARRAY' ) {
            $valid_data = 1;
            $self->output( join( "\n", map { $_->{'ip'} } @{$data} ) . "\n" );
        }
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to receive an ips list from the remote server [$self->{'name'}] (Invalid JSON Returned)" ) if !$valid_data;
    return $self->_check_action( "receive an ips list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

# TESTED WITH VPS.NET -jnk 2/9/2011
sub getpath {
    my ($self) = @_;

    my ( $status, $statusmsg, $page_ref ) = $self->_get('/domains/dns_hosts.api10json');

    my $valid_data = 0;
    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        if ( ref $data eq 'ARRAY' ) {
            $valid_data = 1;
            $self->output( join( "\n", map { $self->{'name'} . ' ' . $_->{'host'} } @{$data} ) . "\n" );
        }
    }

    return $self->_check_action( "getpath", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub version {
    return $VERSION;
}

sub _collapse_name {
    my $zone = shift;
    my $name = shift;
    if ( Cpanel::StringFunc::Match::endmatch( $name, '.' . $zone . '.' ) ) {
        $name =~ s/\Q.$zone.\E$//g;
    }
    elsif ( $name eq "$zone." ) {
        $name = '@';
    }
    return $name;
}

1;
