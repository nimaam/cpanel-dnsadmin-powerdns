package Cpanel::NameServer::Remote::ExternalPDNS;

# cpanel - Cpanel/NameServer/Remote/ExternalPDNS.pm   Copyright 2024
#                                                           All rights reserved.
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
use Cpanel::HTTP::Client         ();
use HTTP::Date                   ();

## no critic (RequireUseWarnings) -- requires auditing for potential warnings
our $VERSION = '1.0';

use parent 'Cpanel::NameServer::Remote';

my %TYPE_MAP = (
    'SOA'   => 'SOA',
    'CNAME' => 'CNAME',
    'PTR'   => 'PTR',
    'NS'    => 'NS',
    'A'     => 'A',
    'AAAA'  => 'AAAA',
    'MX'    => 'MX',
    'TXT'   => 'TXT',
    'SRV'   => 'SRV',
);

my %DATA_MAP = (
    'SOA'   => 'rname',
    'A'     => 'address',
    'NS'    => 'nsdname',
    'CNAME' => 'cname',
    'MX'    => 'exchange',
    'AAAA'  => 'address',
    'TXT'   => 'txtdata'
);

sub new {
    my ( $class, %OPTS ) = @_;
    my $self = {};

    my $api_url        = $OPTS{'api_url'};
    my $apikey         = $OPTS{'apikey'};
    my $server_id      = $OPTS{'server_id'} || 'localhost';
    my $remote_timeout = $OPTS{'timeout'};
    my $dnspeer        = $OPTS{'host'};

    $self->{'name'}            = $dnspeer;
    $self->{'api_url'}         = $api_url;
    $self->{'apikey'}          = $apikey;
    $self->{'server_id'}       = $server_id;
    $self->{'update_type'}     = $OPTS{'update_type'};
    $self->{'local_timeout'}   = $OPTS{'local_timeout'};
    $self->{'remote_timeout'}  = $OPTS{'remote_timeout'};
    $self->{'queue_callback'}  = $OPTS{'queue_callback'};
    $self->{'output_callback'} = $OPTS{'output_callback'};
    $self->{'ns_config'}       = $OPTS{'ns_config'} || '';
    $self->{'powerdns_ns'}     = $OPTS{'powerdns_ns'} || '';
    $self->{'debug'}           = $OPTS{'debug'} || 0;

    $self->{'pdns_log'} = Cpanel::Logger->new( { 'alternate_logfile' => '/usr/local/cpanel/logs/dnsadmin_externalpdns_log' } );

    $self->{'ua'} = Cpanel::HTTP::Client->new(
        timeout    => $remote_timeout,
        keep_alive => 1,
    );

    # Ensure API URL doesn't have trailing slash
    $self->{'api_url'} =~ s/\/$//;

    $self->{'pdns_log'}->info( "ExternalPDNS module initialized for host: $dnspeer, API URL: $api_url, Server ID: $server_id" );

    return bless $self, $class;
}

sub _exec_json {
    my $self     = shift;
    my $uri      = shift;
    my $method   = shift;
    my $formdata = shift;

    my $url = $uri;
    if ( $uri !~ /^https?:\/\// ) {
        $url = $self->{'api_url'} . $uri;
    }

    $self->{'pdns_log'}->info('---');
    $self->{'pdns_log'}->info("$method $url");
    $self->{'pdns_log'}->info("FORMDATA: $formdata") if defined $formdata;

    my ($resp) = $self->{'ua'}->request(
        $method,
        $url,
        {
            headers => {
                'Accept'       => 'application/json',
                'Content-Type' => 'application/json',
                'X-API-Key'    => $self->{'apikey'},
            },
            ( defined $formdata ? ( content => $formdata ) : () )
        }
    );

    my ( $is_success, $page ) = ( $resp->{success}, \$resp->{content} );
    my $error = $is_success ? '' : "$resp->{status} $resp->{reason}";
    $self->{'publicapi'}{'error'} = $error;

    $self->{'pdns_log'}->info("STATUS: " . ( $is_success ? 'SUCCESS' : 'FAILED' ) );
    $self->{'pdns_log'}->info("ERROR: $error") if $error;

    my $logged_page = ref $page ? $$page : $page;
    if ( length($logged_page) > 2000 ) {
        $self->{'pdns_log'}->info( "RESPONSE: " . substr( $logged_page, 0, 2000 ) . "... (truncated)" );
    }
    else {
        $self->{'pdns_log'}->info( "RESPONSE: " . $logged_page );
    }

    return ( $is_success, $error, $page );
}

sub _get_zone_fqdn {
    my ( $self, $zone ) = @_;
    my $zone_fqdn = $zone;
    $zone_fqdn =~ s/\s+//g;
    $zone_fqdn .= '.' unless $zone_fqdn =~ /\.$/;
    return lc($zone_fqdn);
}

sub _ensure_fqdn_dot {
    my ( $self, $name ) = @_;
    return $name if !defined $name || $name eq '';
    $name =~ s/\s+//g;
    $name = lc($name);
    $name .= '.' unless $name =~ /\.$/;
    return $name;
}

sub _rrkey {
    my ( $self, $name, $type ) = @_;
    $name = $self->_ensure_fqdn_dot($name);
    return "$name|$type";
}

sub _get_zone_id {
    my ( $self, $zone ) = @_;

    my $zone_fqdn = $self->_get_zone_fqdn($zone);

    if ( exists $self->{'ZONE_INFO'}->{$zone} ) {
        return $zone_fqdn;
    }

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( "/api/v1/servers/$self->{'server_id'}/zones/$zone_fqdn", 'GET' );

    if ( $status && $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        if ( ref $data eq 'HASH' && exists $data->{'id'} ) {
            $self->{'ZONE_INFO'}->{$zone} = $data;
            return $zone_fqdn;
        }
    }

    return undef;
}

sub _fetch_domain_info {
    my $self = shift;

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( "/api/v1/servers/$self->{'server_id'}/zones", 'GET' );

    if ( $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        if ( ref $data eq 'ARRAY' ) {
            $self->{'ZONE_INFO'} = {};
            foreach my $zone_obj ( @{$data} ) {
                if ( ref $zone_obj eq 'HASH' && exists $zone_obj->{'name'} ) {
                    my $zone_name = $zone_obj->{'name'};
                    $zone_name =~ s/\.$//;
                    $self->{'ZONE_INFO'}->{$zone_name} = $zone_obj;
                }
            }
            return 1;
        }
    }
    else {
        $self->{'error'} = "Failed to get zone list: $!";
    }
    return 0;
}

sub getallzones {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;

    if ( exists $self->{'ZONE_INFO'} || $self->_fetch_domain_info() ) {
        my @zone_names = keys %{ $self->{'ZONE_INFO'} };
        return $self->getzones( $unique_dns_request_id, { 'zones' => join( ",", @zone_names ) }, $rawdata );
    }

    my @check_action_results = $self->_check_action( "get all zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
    return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get all the zones remote server [$self->{'name'}] ($self->{'error'})" );
}

sub cleandns {
    my ($self) = @_;
    $self->{'pdns_log'}->info("cleandns called for $self->{'name'}" );
    $self->output("No cleanup needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub removezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );
    $self->{'pdns_log'}->info("removezone called for zone: $dataref->{'zone'}" );

    my $zone_fqdn = $self->_get_zone_fqdn( $dataref->{'zone'} );

    my @check_action_results = $self->_check_action( "remove the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
    return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( "/api/v1/servers/$self->{'server_id'}/zones/$zone_fqdn", 'DELETE' );

    delete $self->{'ZONE_INFO'}->{ $dataref->{'zone'} } if exists $self->{'ZONE_INFO'};

    $self->output("Removed zone $dataref->{'zone'}\n");

    return $self->_check_action( "remove the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub removezones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    chomp( $dataref->{'zones'} );

    my $count = 0;

    foreach my $zone ( split( /\,/, ( $dataref->{'zones'} || $dataref->{'zone'} ) ) ) {
        $count++;
        $zone =~ s/^\s*|\s*$//g;
        my ( $removezone_status, $removezone_message ) = $self->removezone( $unique_dns_request_id . '_' . $count, { 'zone' => $zone } );

        {
            my @check_action_results = $self->_check_action( "remove the zone(s): " . ( $dataref->{'zones'} || $dataref->{'zone'} ), $Cpanel::NameServer::Constants::QUEUE );
            return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_IS_RECOVERABLE_ERROR];
        }
    }

    return $self->_check_action( "remove the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub reloadbind {
    my ($self) = @_;
    $self->{'pdns_log'}->info("reloadbind called for $self->{'name'}" );
    $self->output("No reload needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub reloadzones {
    my ($self) = @_;
    $self->{'pdns_log'}->info("reloadzones called for $self->{'name'}" );
    $self->output("No reload needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub reconfigbind {
    my ($self) = @_;
    $self->{'pdns_log'}->info("reconfigbind called for $self->{'name'}" );
    $self->output("No reconfig needed on $self->{'name'}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub savezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );

    $self->{'pdns_log'}->info("savezone called for zone: $dataref->{'zone'}" );

    my $zone_fqdn = $self->_get_zone_fqdn( $dataref->{'zone'} );

    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    my $zonefile_obj;
    eval { $zonefile_obj = Cpanel::ZoneFile->new( 'domain' => $dataref->{'zone'}, 'text' => $dataref->{'zonedata'} ); };
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone $dataref->{'zone'} on the remote server [$self->{'name'}] (Could not parse zonefile)" )
      if !$zonefile_obj;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone $dataref->{'zone'} on the remote server [$self->{'name'}] (Could not parse zonefile - $zonefile_obj->{'error'})" )
      if $zonefile_obj->{'error'};

    # Ensure zone exists
    my $zone_id = $self->_get_zone_id( $dataref->{'zone'} );
    if ( !$zone_id ) {
        $self->{'pdns_log'}->info("Zone $dataref->{'zone'} does not exist, creating it" );
        my ( $status, $statusmsg ) = $self->addzoneconf( $unique_dns_request_id, { 'zone' => $dataref->{'zone'} } );
        return ( $status, "Unable to save the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;

        $zone_id = $self->_get_zone_id( $dataref->{'zone'} );

        {
            my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
            return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
        }

        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save the zone(s): $dataref->{'zone'} to the remote server [$self->{'name'}] (Could not fetch zone id : $self->{'publicapi'}->{'error'})" )
          if !$zone_id;
    }

    # --- Build desired rrsets from cPanel zonefile ---
    my %rrsets_by_key = ();    # Key: "name|type"

    foreach my $record ( @{ $zonefile_obj->{'dnszone'} } ) {
        if ( !exists $TYPE_MAP{ $record->{'type'} } ) {
            $self->{'pdns_log'}->info( 'Unsupported record type requested: ' . $record->{'type'} );
            next;
        }

        my $name = $record->{'name'};

        # Convert name to FQDN (trailing dot)
        if ( $name !~ /\.$/ ) {
            if ( $name eq '@' || $name eq $dataref->{'zone'} ) {
                $name = $zone_fqdn;
            }
            else {
                $name = $name . '.' . $zone_fqdn;
            }
        }
        $name = $self->_ensure_fqdn_dot($name);

        my $type = $TYPE_MAP{ $record->{'type'} };
        my $key  = $self->_rrkey( $name, $type );

        if ( !exists $rrsets_by_key{$key} ) {
            $rrsets_by_key{$key} = {
                'name'    => $name,
                'type'    => $type,
                'ttl'     => $record->{'ttl'} || 3600,
                'records' => [],
            };
        }

        my $content = '';
        if ( $record->{'type'} eq 'MX' ) {
            my $ex = $record->{'exchange'};
            $ex = $zone_fqdn if !defined $ex || $ex eq '' || $ex eq '@' || $ex eq $dataref->{'zone'};
            $ex = $self->_ensure_fqdn_dot($ex);
            $content = $record->{'preference'} . ' ' . $ex;
        }
        elsif ( $record->{'type'} eq 'SRV' ) {
            my $tgt = $record->{'target'} || '';
            $tgt = $self->_ensure_fqdn_dot($tgt) if $tgt ne '';
            $content = $record->{'priority'} . ' ' . $record->{'weight'} . ' ' . $record->{'port'} . ' ' . $tgt;
        }
        elsif ( $record->{'type'} eq 'TXT' ) {
            $content = $record->{'txtdata'};
        }
        elsif ( $record->{'type'} eq 'SOA' ) {
            my $m = $record->{'mname'} || '';
            my $r = $record->{'rname'} || '';
            $m = $self->_ensure_fqdn_dot($m) if $m ne '';
            $r = $self->_ensure_fqdn_dot($r) if $r ne '';
            $content = $m . ' ' . $r . ' ' . $record->{'serial'} . ' ' . $record->{'refresh'} . ' ' . $record->{'retry'} . ' ' . $record->{'expire'} . ' ' . $record->{'minimum'};
        }
        else {
            $content = $record->{ $DATA_MAP{ $record->{'type'} } };

            if ( $record->{'type'} eq 'CNAME' || $record->{'type'} eq 'NS' ) {
                $content = $zone_fqdn if $content eq '@' || $content eq $dataref->{'zone'};
                $content = $self->_ensure_fqdn_dot($content);
            }
        }

        push @{ $rrsets_by_key{$key}->{'records'} }, {
            'content'  => $content,
            'disabled' => Cpanel::JSON::false(),
        };
    }

    # Handle NS records based on ns_config
    if ( $self->{'ns_config'} eq 'force' && $self->{'powerdns_ns'} ) {
        $self->{'pdns_log'}->info("NS config is 'force', replacing all NS records with PowerDNS nameservers" );
        my @powerdns_ns = map {
            my $ns = $_;
            $ns =~ s/^\s+|\s+$//g;
            $ns = $self->_ensure_fqdn_dot($ns);
            $ns;
        } split( /,/, $self->{'powerdns_ns'} );

        delete $rrsets_by_key{ $self->_rrkey( $zone_fqdn, 'NS' ) };

        $rrsets_by_key{ $self->_rrkey( $zone_fqdn, 'NS' ) } = {
            'name'    => $zone_fqdn,
            'type'    => 'NS',
            'ttl'     => 86400,
            'records' => [ map { { 'content' => $_, 'disabled' => Cpanel::JSON::false() } } @powerdns_ns ],
        };
    }
    elsif ( $self->{'ns_config'} eq 'ensure' && $self->{'powerdns_ns'} ) {
        $self->{'pdns_log'}->info("NS config is 'ensure', ensuring PowerDNS nameservers are included" );
        my @powerdns_ns = map {
            my $ns = $_;
            $ns =~ s/^\s+|\s+$//g;
            $ns = $self->_ensure_fqdn_dot($ns);
            $ns;
        } split( /,/, $self->{'powerdns_ns'} );

        my $ns_key = $self->_rrkey( $zone_fqdn, 'NS' );
        if ( !exists $rrsets_by_key{$ns_key} ) {
            $rrsets_by_key{$ns_key} = {
                'name'    => $zone_fqdn,
                'type'    => 'NS',
                'ttl'     => 86400,
                'records' => [],
            };
        }

        my %existing_ns = map { $_->{'content'} => 1 } @{ $rrsets_by_key{$ns_key}->{'records'} };
        foreach my $ns (@powerdns_ns) {
            push @{ $rrsets_by_key{$ns_key}->{'records'} }, { 'content' => $ns, 'disabled' => Cpanel::JSON::false() }
              unless $existing_ns{$ns};
        }
    }
    else {
        $self->{'pdns_log'}->info("NS config is 'default', not modifying NS records" );
    }

    # --- Fetch current rrsets from PDNS to detect deletions ---
    my %existing_rr = ();
    {
        my ( $st, $msg, $page_ref ) = $self->_exec_json( "/api/v1/servers/$self->{'server_id'}/zones/$zone_fqdn", 'GET' );
        if ( $st && $page_ref && $$page_ref ) {
            my $z = Cpanel::JSON::Load($$page_ref);
            if ( ref $z eq 'HASH' && ref $z->{'rrsets'} eq 'ARRAY' ) {
                for my $rr ( @{ $z->{'rrsets'} } ) {
                    next if !$rr->{'name'} || !$rr->{'type'};
                    my $k = $self->_rrkey( $rr->{'name'}, $rr->{'type'} );
                    $existing_rr{$k} = 1;
                }
            }
        }
    }

    # Desired keys
    my %desired_rr = map { $_ => 1 } keys %rrsets_by_key;

    # Convert desired rrsets to array
    my @rrsets = values %rrsets_by_key;

    # Add DELETE rrsets for anything that exists in PDNS but not in desired
    for my $k ( keys %existing_rr ) {
        next if $desired_rr{$k};

        my ( $n, $t ) = split( /\|/, $k, 2 );

        # Safety: don't delete apex NS/SOA from diff (unless you explicitly want it)
        next if ( $n eq $zone_fqdn && ( $t eq 'NS' || $t eq 'SOA' ) );

        push @rrsets,
          {
            name       => $n,
            type       => $t,
            changetype => 'DELETE',
            records    => [],
          };
    }

    # Ensure REPLACE changetype on desired rrsets
    foreach my $rr (@rrsets) {
        next if $rr->{'changetype'} && $rr->{'changetype'} eq 'DELETE';
        $rr->{'changetype'} = 'REPLACE';
        $rr->{'name'}       = $self->_ensure_fqdn_dot( $rr->{'name'} );
    }

    my $zone_update = { 'rrsets' => \@rrsets };
    my $json        = Cpanel::JSON::Dump($zone_update);

    # IMPORTANT: use PATCH for rrset updates
    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json(
        "/api/v1/servers/$self->{'server_id'}/zones/$zone_fqdn",
        'PATCH',
        $json
    );

    {
        my @check_action_results = $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return (
        $status
        ? ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' )
        : ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to save zone $dataref->{'zone'}: $statusmsg" )
    );
}

sub synczones {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;

    $self->{'pdns_log'}->info("synczones called" );
    $rawdata = $self->_strip_dnsuniqid($rawdata);

    my %CZONETABLE = map { ( split( /=/, $_, 2 ) )[ 0, 1 ] } split( /\&/, $rawdata );
    delete @CZONETABLE{ grep( !/^cpdnszone-/, keys %CZONETABLE ) };

    if ( !exists $self->{'ZONE_INFO'} && !$self->_fetch_domain_info() ) {
        {
            my @check_action_results = $self->_check_action( "sync zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
            return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
        }

        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to sync zones to the remote server [$self->{'name'}] (Could not fetch domain id: Unknown error)" );
    }

    local $self->{'ua'}->{'timeout'} = ( ( int( $self->{'local_timeout'} / 2 ) > $self->{'remote_timeout'} ) ? int( $self->{'local_timeout'} / 2 ) : $self->{'remote_timeout'} );
    my $zone;
    my $count = 0;
    my ( $status, $statusmsg );
    foreach my $zonekey ( keys %CZONETABLE ) {
        $zone = $zonekey;
        $zone =~ s/^cpdnszone-//g;
        if ( !exists $self->{'ZONE_INFO'}->{$zone} ) {
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

    $self->{'pdns_log'}->info("quickzoneadd called for zone: $dataref->{'zone'}" );

    my ( $addstatus, $addstatus_message ) = $self->addzoneconf( $unique_dns_request_id . '_1', $dataref );
    return ( $addstatus, $addstatus_message ) if !$addstatus;

    my ( $savestatus, $savestatus_message ) = $self->savezone( $unique_dns_request_id . '_2', $dataref );
    return ( $savestatus, $savestatus_message ) if !$savestatus;

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub addzoneconf {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );
    $self->{'pdns_log'}->info("addzoneconf called for zone: $dataref->{'zone'}" );

    my $zone_fqdn = $self->_get_zone_fqdn( $dataref->{'zone'} );

    my @nameservers = ();
    if ( $self->{'powerdns_ns'} ) {
        @nameservers = map {
            my $ns = $_;
            $ns =~ s/^\s+|\s+$//g;
            $ns = $self->_ensure_fqdn_dot($ns);
            $ns;
        } split( /,/, $self->{'powerdns_ns'} );
    }

    my $zone_data = {
        'name'   => $zone_fqdn,
        'kind'   => 'Primary',
        'rrsets' => [],
    };

    if (@nameservers) {
        $zone_data->{'nameservers'} = \@nameservers;
        $self->{'pdns_log'}->info("Creating zone with nameservers: " . join( ',', @nameservers ) );
    }

    my $json = Cpanel::JSON::Dump($zone_data);

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( "/api/v1/servers/$self->{'server_id'}/zones", 'POST', $json );

    {
        my @check_action_results = $self->_check_action( "add the zone: $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    if ( !$status && $statusmsg =~ /422|already exists/i ) {
        $self->{'pdns_log'}->info("Zone $dataref->{'zone'} already exists, returning success" );
        return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
    }

    if ( $status && $page_ref && $$page_ref ) {
        my $data = Cpanel::JSON::Load($$page_ref);
        if ( ref $data eq 'HASH' && exists $data->{'id'} ) {
            $self->{'ZONE_INFO'}->{ $dataref->{'zone'} } = $data;
        }
    }

    return (
        $status
        ? ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' )
        : ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to add zone $dataref->{'zone'}: $statusmsg" )
    );
}

sub getzone {
    my $self = shift;
    my ( $status, $statusmsg, $zonedata ) = $self->_getzone(@_);
    $self->output($zonedata) if $zonedata;
    return ( $status, $statusmsg );
}

sub _getzone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );

    $self->{'pdns_log'}->info("_getzone called for zone: $dataref->{'zone'}" );

    my $zone_fqdn = $self->_get_zone_fqdn( $dataref->{'zone'} );

    {
        my @check_action_results = $self->_check_action( "get the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    my ( $status, $statusmsg, $page_ref ) = $self->_exec_json( "/api/v1/servers/$self->{'server_id'}/zones/$zone_fqdn", 'GET' );

    {
        my @check_action_results = $self->_check_action( "get the zone(s): $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone(s): $dataref->{'zone'} from the remote server [$self->{'name'}] ($statusmsg)" ) if !$status;

    my $zone_data = Cpanel::JSON::Load($$page_ref);
    if ( !$zone_data || ref $zone_data ne 'HASH' ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zone $dataref->{'zone'} from the remote server [$self->{'name'}] (No zone data returned from remote server)" );
    }

    my $zone_text = '';
    my $soa_rrset = undef;

    if ( exists $zone_data->{'rrsets'} && ref $zone_data->{'rrsets'} eq 'ARRAY' ) {
        foreach my $rrset ( @{ $zone_data->{'rrsets'} } ) {
            if ( $rrset->{'type'} eq 'SOA' ) { $soa_rrset = $rrset; last; }
        }

        if ( $soa_rrset && exists $soa_rrset->{'records'} && @{ $soa_rrset->{'records'} } ) {
            my ( $mname, $rname, $serial, $refresh, $retry, $expire, $minimum ) = split( /\s+/, $soa_rrset->{'records'}->[0]->{'content'}, 7 );
            $zone_text .= join( "\t", $zone_fqdn, $soa_rrset->{'ttl'}, 'IN', 'SOA', "$mname $rname ($serial $refresh $retry $expire $minimum)" ) . "\n";
        }

        foreach my $rrset ( @{ $zone_data->{'rrsets'} } ) {
            next if $rrset->{'type'} eq 'SOA';

            my $name = $rrset->{'name'};
            $name = '@' if $name eq $zone_fqdn;
            $name =~ s/\.$zone_fqdn$//;

            foreach my $record ( @{ $rrset->{'records'} } ) {
                if ( $rrset->{'type'} eq 'MX' ) {
                    my ( $priority, $exchange ) = split( /\s+/, $record->{'content'}, 2 );
                    $zone_text .= join( "\t", $name, $rrset->{'ttl'}, 'IN', $rrset->{'type'}, $priority, $exchange ) . "\n";
                }
                elsif ( $rrset->{'type'} eq 'SRV' ) {
                    my ( $priority, $weight, $port, $target ) = split( /\s+/, $record->{'content'}, 4 );
                    $zone_text .= join( "\t", $name, $rrset->{'ttl'}, 'IN', $rrset->{'type'}, $priority, $weight, $port, $target ) . "\n";
                }
                else {
                    $zone_text .= join( "\t", $name, $rrset->{'ttl'}, 'IN', $rrset->{'type'}, $record->{'content'} ) . "\n";
                }
            }
        }
    }

    my $update_time = time();
    if ( exists $zone_data->{'serial'} ) {
        $update_time = HTTP::Date::str2time( $zone_data->{'serial'} ) || time();
    }
    $zone_text = Cpanel::ZoneFile::Versioning::version_line( '', $update_time, $self->{'name'} ) . "\n" . $zone_text;

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK', $zone_text );
}

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
    return ( $status, $statusmsg ) if defined $status;
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, __PACKAGE__ . ": Unable to get the zones " . ( $dataref->{'zones'} || $dataref->{'zone'} ) . " from the remote server [$self->{'name'}] (unknown error)" );
}

sub getzonelist {
    my ($self) = @_;

    $self->{'pdns_log'}->info("getzonelist called" );

    if ( exists $self->{'ZONE_INFO'} || $self->_fetch_domain_info() ) {
        my @zone_names = map { my $n = $_; $n =~ s/\.$//; $n } keys %{ $self->{'ZONE_INFO'} };
        $self->output( join( "\n", @zone_names ) );
    }
    else {
        my @check_action_results = $self->_check_action( "get the zone list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub zoneexists {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );
    $self->{'pdns_log'}->info("zoneexists called for zone: $dataref->{'zone'}" );

    if ( $self->_get_zone_id( $dataref->{'zone'} ) ) {
        $self->output('1');
    }
    else {
        $self->output('0');
    }

    return $self->_check_action("check for the existance of $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
}

sub getips {
    my ($self) = @_;
    $self->{'pdns_log'}->info("getips called" );

    if ( $self->{'powerdns_ns'} ) {
        use Cpanel::SocketIP;
        my @ips = ();
        foreach my $ns ( split( /,/, $self->{'powerdns_ns'} ) ) {
            $ns =~ s/^\s+|\s+$//g;
            eval { push @ips, Cpanel::SocketIP::_resolveIpAddress($ns); };
        }
        if (@ips) {
            $self->output( join( "\n", @ips ) . "\n" );
            return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
        }
    }

    $self->output("\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub getpath {
    my ($self) = @_;
    $self->{'pdns_log'}->info("getpath called" );

    if ( $self->{'powerdns_ns'} ) {
        my @ns_list = map { my $ns = $_; $ns =~ s/^\s+|\s+$//g; $ns } split( /,/, $self->{'powerdns_ns'} );
        $self->output( join( "\n", map { $self->{'name'} . ' ' . $_ } @ns_list ) . "\n" );
    }
    else {
        $self->output("\n");
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub version { return $VERSION; }

1;
