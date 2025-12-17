package Cpanel::NameServer::Remote::PowerDNS;

use strict;
use warnings;

use Cpanel::NameServer::Remote ();
use Cpanel::NameServer::Constants ();
use Cpanel::Logger ();
use cPanel::PublicAPI ();
use Cpanel::JSON ();
use Cpanel::HTTP::Client ();
use Cpanel::Encoder::URI ();
use Cpanel::StringFunc::Match ();
use Cpanel::StringFunc::Trim ();

our @ISA = qw(Cpanel::NameServer::Remote);

# Initialize the module
sub new {
    my ($class, %OPTS) = @_;

    # Parse API URL from config
    my $api_url = $OPTS{"api_url"} || "";
    my ($base_url, $host) = $class->_parse_api_url($api_url);

    # Support both "apikey" and "pass" for backward compatibility
    my $apikey = $OPTS{"apikey"} || $OPTS{"pass"} || "";

    # Get host from OPTS if provided, otherwise use parsed host
    my $dnspeer = $OPTS{"host"} || $host || "";

    my $self = bless(
        {
            "api_url" => $api_url,
            "base_url" => $base_url,
            "host" => $dnspeer,
            "name" => $dnspeer,  # Required by parent class
            "apikey" => $apikey,
            "pass" => $apikey,  # Keep for backward compatibility
            "server_name" => "localhost",
            "debug" => ($OPTS{"debug"} && $OPTS{"debug"} eq "on") ? 1 : 0,
            "logger" => $OPTS{"logger"} || Cpanel::Logger->new({"alternate_logfile" => "/usr/local/cpanel/logs/dnsadmin_powerdns_log"}),
            "dnsrole" => $OPTS{"dnsrole"},
            "local_timeout" => $OPTS{"local_timeout"} || 30,
            "remote_timeout" => $OPTS{"remote_timeout"} || 30,
            "queue_callback" => $OPTS{"queue_callback"},  # Required by parent class
            "output_callback" => $OPTS{"output_callback"},  # Required by parent class
            "update_type" => $OPTS{"update_type"},
        },
        $class
    );

    # Initialize PublicAPI client (using host from URL)
    $self->{"publicapi"} = cPanel::PublicAPI->new(
        {
            "host" => $self->{"host"},
            "user" => $OPTS{"user"} || "root",
            "pass" => $self->{"apikey"},
        }
    );

    # Initialize HTTP client using cPanel's HTTP client
    $self->{"ua"} = Cpanel::HTTP::Client->new(
        timeout    => $self->{"remote_timeout"},
        keep_alive => 1,
    );

    return $self;
}

# Helper method to parse API URL and extract base URL and host
sub _parse_api_url {
    my ($class, $api_url) = @_;

    if (!$api_url) {
        return ("", "");
    }

    # Remove trailing slashes
    $api_url =~ s/\/+$//;

    # Parse URL
    if ($api_url =~ /^(https?:\/\/[^\/]+)(\/.*)?$/) {
        my $full_base = $1;
        my $path = $2 || "";

        # Extract host (with port if present)
        my $host = $full_base;
        $host =~ s/^https?:\/\///;

        # Normalize base URL - remove standard ports
        my $normalized_base = $full_base;
        $normalized_base =~ s/:80$// if $normalized_base =~ /^http:\/\/.*:80$/;
        $normalized_base =~ s/:443$// if $normalized_base =~ /^https:\/\/.*:443$/;

        # If path was provided, use it; otherwise default to /api/v1
        my $base_url = $normalized_base . ($path || "/api/v1");

        return ($base_url, $host);
    }

    return ("", "");
}

# Helper method to get PowerDNS API base URL
sub _get_api_base_url {
    my ($self) = @_;
    return $self->{"base_url"} || "";
}

# Helper method to normalize zone name for PowerDNS API
# PowerDNS requires zone names to have a trailing dot
sub _normalize_zone_name {
    my ($self, $zone) = @_;
    return "" if !$zone;
    
    $zone =~ s/^\s+|\s+$//g;  # Trim whitespace
    return "" if !$zone;
    
    # Add trailing dot if not present
    $zone .= "." unless $zone =~ /\.$/;
    
    return $zone;
}

# Helper method to make PowerDNS API requests
sub _powerdns_api_request {
    my ($self, $method, $endpoint, $data) = @_;

    my $base_url = $self->_get_api_base_url();
    my $url = "$base_url$endpoint";

    my $headers = {
        "X-API-Key"    => $self->{"apikey"},
        "Content-Type" => "application/json",
        "Accept"       => "application/json",
    };

    my $content = undef;
    if ($data && ($method eq "POST" || $method eq "PATCH" || $method eq "PUT")) {
        $content = Cpanel::JSON::Dump($data);
    }

    if ($self->{"debug"}) {
        $self->{"logger"}->info("PowerDNS API Request: $method $url");
        $self->{"logger"}->info("Request Data: " . ($content || ""));
    }

    my $resp;
    my $request_opts = {"headers" => $headers};
    $request_opts->{"content"} = $content if defined $content;

    $resp = $self->{"ua"}->request($method, $url, $request_opts);

    my ($is_success, $page) = ($resp->{"success"}, \$resp->{"content"});
    my $error = $is_success ? "" : ($resp->{"status"} || "unknown") . " " . ($resp->{"reason"} || "unknown error");

    if ($self->{"debug"} || !$is_success) {
        $self->{"logger"}->info("PowerDNS API Response Status: " . ($resp->{"status"} || "N/A"));
        $self->{"logger"}->info("PowerDNS API Response: " . (ref($page) ? $$page : $page || ""));
        $self->{"logger"}->info("ERROR: $error") if $error;
    }

    if (!$is_success) {
        # Set error in publicapi->error so parent class _check_action can detect it
        $self->{"publicapi"}->{"error"} = "PowerDNS API error: $error";
        if (ref($page) && $$page) {
            eval {
                my $error_data = Cpanel::JSON::Load($$page);
                if (ref($error_data) eq "HASH" && $error_data->{"error"}) {
                    $self->{"publicapi"}->{"error"} .= " - " . $error_data->{"error"};
                }
            };
        }
        return undef;
    }

    if (ref($page) && $$page) {
        eval {
            return Cpanel::JSON::Load($$page);
        };
        return $$page;
    }

    return 1;
}

# Helper method to convert cPanel zone format to PowerDNS format
sub _cpanel_to_powerdns_zone {
    my ($self, $zone_data) = @_;

    # Parse cPanel zone format and convert to PowerDNS format
    # This is a simplified conversion - may need adjustment based on actual zone format
    my @records = ();
    my @lines = split(/\n/, $zone_data);

    foreach my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;
        next if !$line || $line =~ /^;|^\$TTL|^\$ORIGIN/;

        if ($line =~ /^(\S+)\s+(\d+)\s+(IN\s+)?(\S+)\s+(.+)$/) {
            my ($name, $ttl, $class, $type, $content) = ($1, $2, $3, $4, $5);
            $name =~ s/\.$//;
            push(
                @records,
                {
                    "name" => $name,
                    "type" => $type,
                    "ttl" => int($ttl),
                    "records" => [
                        {
                            "content" => $content,
                            "disabled" => 0,
                        }
                    ],
                }
            );
        }
    }

    return \@records;
}

# Helper method to convert PowerDNS zone format to cPanel format
sub _powerdns_to_cpanel_zone {
    my ($self, $zone_name, $powerdns_zone) = @_;

    my $output = "";
    $output .= "\$TTL 3600\n";
    $output .= "\$ORIGIN $zone_name.\n\n";

    if (ref($powerdns_zone) eq "HASH" && $powerdns_zone->{"rrsets"}) {
        foreach my $rrset (@{$powerdns_zone->{"rrsets"}}) {
            my $name = $rrset->{"name"} || "";
            my $type = $rrset->{"type"} || "";
            my $ttl = $rrset->{"ttl"} || 3600;

            if ($rrset->{"records"}) {
                foreach my $record (@{$rrset->{"records"}}) {
                    my $content = $record->{"content"} || "";
                    $output .= sprintf("%-30s %-6d IN %-8s %s\n", $name, $ttl, $type, $content);
                }
            }
        }
    }

    return $output;
}

# Create a method to add a zone configuration.
sub addzoneconf {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"}) if defined $dataref->{"zone"};
    my $zone = $dataref->{"zone"} || return $self->_check_action("add zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Normalize zone name for PowerDNS API (add trailing dot if needed)
    my $normalized_zone = $self->_normalize_zone_name($zone);

    # Create zone in PowerDNS
    my $zone_data = {
        "name" => $normalized_zone,
        "kind" => "Native",
        "dnssec" => 0,
        "nameservers" => [],
    };

    my $result = $self->_powerdns_api_request("POST", "/servers/$self->{'server_name'}/zones", $zone_data);

    if (!$result) {
        return $self->_check_action("add zone $zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    return $self->_check_action("add zone $zone", $Cpanel::NameServer::Constants::QUEUE);
}

# Create a method to get all zones.
sub getallzones {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    my $zones = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}/zones");

    if (!$zones || ref($zones) ne "ARRAY") {
        return $self->_check_action("get all zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    my $output = "";
    foreach my $zone (@$zones) {
        if (ref($zone) eq "HASH" && $zone->{"name"}) {
            $output .= $zone->{"name"} . "\n";
        }
    }

    $self->output($output);
    return $self->_check_action("get all zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
}

# Create a method to get a zone.
sub getzone {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"}) if defined $dataref->{"zone"};
    my $zone = $dataref->{"zone"} || return $self->_check_action("get zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Normalize zone name for PowerDNS API (add trailing dot if needed)
    my $normalized_zone = $self->_normalize_zone_name($zone);
    my $powerdns_zone = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}/zones/$normalized_zone");

    if (!$powerdns_zone || ref($powerdns_zone) ne "HASH") {
        return $self->_check_action("get zone $zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    my $cpanel_zone = $self->_powerdns_to_cpanel_zone($zone, $powerdns_zone);
    $self->output($cpanel_zone);

    return $self->_check_action("get zone $zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
}

# Create a method to get the contents of multiple zone files.
sub getzones {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    # Guard against undef keys to avoid "Use of uninitialized value in chomp" warnings
    chomp($dataref->{"zone"})  if defined $dataref->{"zone"};
    chomp($dataref->{"zones"}) if defined $dataref->{"zones"};

    my $zones_list = $dataref->{"zones"} || $dataref->{"zone"} || "";
    my @zones = split(/,/, $zones_list);

    require Cpanel::Gzip::ungzip;

    my $output = "";
    my $count = 0;

    foreach my $zone (@zones) {
        $zone =~ s/^\s+|\s+$//g;
        next if !$zone;

        $count++;
        # Normalize zone name for PowerDNS API (add trailing dot if needed)
        my $normalized_zone = $self->_normalize_zone_name($zone);
        
        # Clear any previous errors before making the request
        $self->{"publicapi"}->{"error"} = "";
        
        my $powerdns_zone = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}/zones/$normalized_zone");

        # If zone exists, add it to output
        # If zone doesn't exist (404), that's OK - just skip it (will be created during sync)
        if ($powerdns_zone && ref($powerdns_zone) eq "HASH") {
            my $cpanel_zone = $self->_powerdns_to_cpanel_zone($zone, $powerdns_zone);
            $output .= "cpdnszone-" . Cpanel::Encoder::URI::uri_encode_str($zone) . "=" . Cpanel::Encoder::URI::uri_encode_str($cpanel_zone) . "&";
        } elsif ($self->{"publicapi"}->{"error"} && $self->{"publicapi"}->{"error"} =~ /404/) {
            # Zone doesn't exist - this is OK, just clear the error and continue
            $self->{"publicapi"}->{"error"} = "";
        }
    }

    $self->output($output);
    # Only report error if we have a non-404 error and no zones were retrieved
    if ($self->{"publicapi"}->{"error"} && !$output) {
        return $self->_check_action("get zones " . join(",", @zones), $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }
    # Clear any remaining errors if we got at least some zones
    $self->{"publicapi"}->{"error"} = "" if $output;
    return ($Cpanel::NameServer::Constants::SUCCESS, "OK");
}

# Create a method to list all of the zones on the system.
sub getzonelist {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    my $zones = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}/zones");

    if (!$zones || ref($zones) ne "ARRAY") {
        return $self->_check_action("get zone list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    my @check_action_results = $self->_check_action("get the zone list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    return @check_action_results if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;

    my $output = "";
    foreach my $zone (@$zones) {
        if (ref($zone) eq "HASH" && $zone->{"name"}) {
            my $zone_name = $zone->{"name"};
            $zone_name =~ s/\.$//;
            $output .= $zone_name . "\n";
        }
    }

    $self->output($output);
    return ($Cpanel::NameServer::Constants::SUCCESS, "OK");
}

# Create a method to check whether a zone exists.
sub zoneexists {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"}) if defined $dataref->{"zone"};
    my $zone = $dataref->{"zone"} || return $self->_check_action("check if zone exists", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Normalize zone name for PowerDNS API (add trailing dot if needed)
    my $normalized_zone = $self->_normalize_zone_name($zone);
    my $powerdns_zone = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}/zones/$normalized_zone");

    my $exists = ($powerdns_zone && ref($powerdns_zone) eq "HASH") ? 1 : 0;
    $self->output($exists);

    return $self->_check_action("check if zone $zone exists", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
}

# Create a method to list the nameserver records' IP addresses.
sub getips {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    # Get server statistics to find IP addresses
    my $stats = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}/statistics");

    # For PowerDNS, we typically get IPs from the server configuration
    # This is a simplified implementation - may need adjustment
    my $output = "";
    if ($stats && ref($stats) eq "ARRAY") {
        # Extract IP addresses from statistics if available
        foreach my $stat (@$stats) {
            if (ref($stat) eq "HASH" && $stat->{"name"} && $stat->{"name"} =~ /ip/) {
                $output .= $stat->{"value"} . "\n" if $stat->{"value"};
            }
        }
    }

    # Fallback: try to get IPs from local PublicAPI
    if (!$output) {
        $output = $self->{"publicapi"}->getips_local($unique_dns_request_id) || "";
    }

    $self->output($output);
    return $self->_check_action("receive an ips list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
}

# Create a method that lists the nodes with which the current node is peered.
sub getpath {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    # For PowerDNS, return the server name as the path
    my $path = $self->{"host"} . "\n";
    $self->output($path);

    return $self->_check_action("getpath", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
}

# Create a method that gets a module's version number.
sub version {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    # Get PowerDNS server version
    my $server_info = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}");

    if ($server_info && ref($server_info) eq "HASH" && $server_info->{"version"}) {
        return $server_info->{"version"};
    }

    # Fallback to PublicAPI version
    my $version = $self->{"publicapi"}->version();
    # Error is already in publicapi->error, no need to copy
    return $version || "1.0";
}

# Create a method to quickly add a zone.
sub quickzoneadd {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"}) if defined $dataref->{"zone"};
    my $zone = $dataref->{"zone"} || return $self->_check_action("quick add zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Normalize zone name for PowerDNS API (add trailing dot if needed)
    my $normalized_zone = $self->_normalize_zone_name($zone);

    # Create zone in PowerDNS
    my $zone_data = {
        "name" => $normalized_zone,
        "kind" => "Native",
        "dnssec" => 0,
        "nameservers" => [],
    };

    my $result = $self->_powerdns_api_request("POST", "/servers/$self->{'server_name'}/zones", $zone_data);

    if (!$result) {
        return $self->_check_action("quick add zone $zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    return $self->_check_action("quick add zone $zone", $Cpanel::NameServer::Constants::QUEUE);
}

# Create a method to remove a zone.
sub removezone {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"}) if defined $dataref->{"zone"};
    my $zone = $dataref->{"zone"} || return $self->_check_action("remove zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Normalize zone name for PowerDNS API (add trailing dot if needed)
    my $normalized_zone = $self->_normalize_zone_name($zone);
    my $result = $self->_powerdns_api_request("DELETE", "/servers/$self->{'server_name'}/zones/$normalized_zone");

    if (!$result) {
        return $self->_check_action("remove zone $zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    return $self->_check_action("remove zone $zone", $Cpanel::NameServer::Constants::QUEUE);
}

# Create a method to remove multiple zones.
sub removezones {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zones"});
    my $zones_list = $dataref->{"zones"} || "";
    my @zones = split(/,/, $zones_list);

    my $success = 1;
    foreach my $zone (@zones) {
        $zone =~ s/^\s+|\s+$//g;
        next if !$zone;

        # Normalize zone name for PowerDNS API (add trailing dot if needed)
        my $normalized_zone = $self->_normalize_zone_name($zone);
        my $result = $self->_powerdns_api_request("DELETE", "/servers/$self->{'server_name'}/zones/$normalized_zone");
        $success = 0 if !$result;
    }

    if (!$success) {
        return $self->_check_action("remove zones " . join(",", @zones), $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    return $self->_check_action("remove zones " . join(",", @zones), $Cpanel::NameServer::Constants::QUEUE);
}

# Create a method to save a zone.
sub savezone {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"}) if defined $dataref->{"zone"};
    my $zone = $dataref->{"zone"} || return $self->_check_action("save zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Normalize zone name for PowerDNS API (add trailing dot if needed)
    my $normalized_zone = $self->_normalize_zone_name($zone);

    # Parse the zone data from rawdata
    # This is a simplified implementation - may need adjustment based on actual format
    my $zone_data = $dataref->{"zonedata"} || $rawdata || "";

    # Convert cPanel zone format to PowerDNS format
    my $records = $self->_cpanel_to_powerdns_zone($zone_data);

    # Update zone in PowerDNS
    my $update_data = {
        "rrsets" => $records,
    };

    my $result = $self->_powerdns_api_request("PATCH", "/servers/$self->{'server_name'}/zones/$normalized_zone", $update_data);

    if (!$result) {
        return $self->_check_action("save zone $zone", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    return $self->_check_action("save zone $zone", $Cpanel::NameServer::Constants::QUEUE);
}

# Create methods for BIND-specific operations (not needed for PowerDNS, but required by dnsadmin)
sub reloadbind {
    my ($self) = @_;
    $self->output("No reload needed on $self->{'name'}\n");
    return ($Cpanel::NameServer::Constants::SUCCESS, 'OK');
}

sub reloadzones {
    my ($self) = @_;
    $self->output("No reload needed on $self->{'name'}\n");
    return ($Cpanel::NameServer::Constants::SUCCESS, 'OK');
}

sub reconfigbind {
    my ($self) = @_;
    $self->output("No reconfig needed on $self->{'name'}\n");
    return ($Cpanel::NameServer::Constants::SUCCESS, 'OK');
}

# Create a method to synchronize zones.
# This implementation follows the same pattern as SoftLayer and VPSNET:
# 1. Parse rawdata containing cpdnszone- entries with zone data
# 2. For each zone: check if exists, create if needed, then save zone data
sub synczones {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    # Strip dnsuniqid from rawdata (inherited from parent class)
    $rawdata = $self->_strip_dnsuniqid($rawdata);

    # Parse rawdata into hash: cpdnszone-<encoded_zone> => <encoded_zone_data>
    my %CZONETABLE = map { ( split( /=/, $_, 2 ) )[ 0, 1 ] } split( /\&/, $rawdata );
    # Keep only cpdnszone- entries
    delete @CZONETABLE{ grep( !/^cpdnszone-/, keys %CZONETABLE ) };

    # Check if we have any zones to sync
    if (!scalar keys %CZONETABLE) {
        return $self->_check_action("sync zones", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);
    }

    # Allow longer timeout for bulk operations
    local $self->{'ua'}->{'timeout'} = (
        ( int( $self->{'local_timeout'} / 2 ) > $self->{'remote_timeout'} )
            ? int( $self->{'local_timeout'} / 2 )
            : $self->{'remote_timeout'}
    );

    my $zone;
    my $count = 0;
    my ($status, $statusmsg);

    # Process each zone
    foreach my $zonekey ( keys %CZONETABLE ) {
        $zone = $zonekey;
        $zone =~ s/^cpdnszone-//g;
        
        # Decode the zone name
        $zone = Cpanel::Encoder::URI::uri_decode_str($zone);
        
        # Normalize zone name for PowerDNS API (add trailing dot if needed)
        my $normalized_zone = $self->_normalize_zone_name($zone);
        
        # Check if zone exists in PowerDNS
        my $powerdns_zone = $self->_powerdns_api_request("GET", "/servers/$self->{'server_name'}/zones/$normalized_zone");
        
        # If zone doesn't exist, create it
        if (!$powerdns_zone || ref($powerdns_zone) ne "HASH") {
            ($status, $statusmsg) = $self->addzoneconf(
                $unique_dns_request_id . '_' . ++$count,
                { 'zone' => $zone }  # Use original zone name (addzoneconf will normalize)
            );
            
            # Return immediately if recoverable error (will retry later)
            # Only check if status is defined and not SUCCESS (SUCCESS is not an error type)
            if (defined $status && $status != $Cpanel::NameServer::Constants::SUCCESS) {
                # Use our overridden method which handles undefined values
                return ($status, $statusmsg) if $self->is_recoverable_error($status);
            }
        }

        # Decode zone data and save the zone
        my $decoded_zone_data = Cpanel::Encoder::URI::uri_decode_str($CZONETABLE{$zonekey});
        
        ($status, $statusmsg) = $self->savezone(
            $unique_dns_request_id . '_' . ++$count,
            {
                'zone' => $zone,
                'zonedata' => $decoded_zone_data
            }
        );

        # Return immediately if recoverable error (will retry later)
        # Only check if status is defined and not SUCCESS (SUCCESS is not an error type)
        if (defined $status && $status != $Cpanel::NameServer::Constants::SUCCESS) {
            # Use our overridden method which handles undefined values
            return ($status, $statusmsg) if $self->is_recoverable_error($status);
        }
    }

    return ($Cpanel::NameServer::Constants::SUCCESS, 'OK');
}

# Create a method that synchronizes DNSSEC keys in the DNS cluster.
sub synckeys {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"});
    my $zone = $dataref->{"zone"} || return $self->_check_action("sync keys", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Remove dnsuniqid from rawdata
    $rawdata =~ s/^dnsuniqid=[^&]+&//g;
    $rawdata =~ s/&dnsuniqid=[^&]+//g;

    # Sync DNSSEC keys via PublicAPI
    my $result = $self->{"publicapi"}->synckeys_local($rawdata, $unique_dns_request_id);
    $self->output($result);

    return $self->_check_action("sync keys: $zone", $Cpanel::NameServer::Constants::QUEUE);
}

# Create a method to deauthorize DNSSEC keys in the DNS cluster.
sub revokekeys {
    my ($self, $unique_dns_request_id, $dataref, $rawdata) = @_;

    chomp($dataref->{"zone"});
    my $zone = $dataref->{"zone"} || return $self->_check_action("revoke keys", $Cpanel::NameServer::Constants::DO_NOT_QUEUE);

    # Remove dnsuniqid from rawdata
    $rawdata =~ s/^dnsuniqid=[^&]+&//g;
    $rawdata =~ s/&dnsuniqid=[^&]+//g;

    # Revoke DNSSEC keys via PublicAPI
    my $result = $self->{"publicapi"}->revokekeys_local($rawdata, $unique_dns_request_id);
    $self->output($result);

    return $self->_check_action("revoke keys: $zone", $Cpanel::NameServer::Constants::QUEUE);
}

# Override determine_error_type for compatibility with cPanel versions
# whose parent class _check_action calls determine_error_type with 2 arguments
# (error_msg and action_desc), but the parent implementation only expects 1.
# This prevents "Too many arguments" fatal errors.
sub determine_error_type {
    my ($self, $error_msg, $action_desc) = @_;

    # Use the human-readable action description if provided, otherwise fall back
    # to the raw error string. The parent implementation will incorporate
    # $self->{'publicapi'}->{error} into its final message.
    my $msg = defined $action_desc && length $action_desc ? $action_desc : $error_msg;
    
    # Ensure we have a valid error message
    $msg = $self->{'publicapi'}->{'error'} || $error_msg || "Unknown error" if !$msg || !length $msg;

    # Call parent determine_error_type with error handling
    my ($error_type, $error_message, $is_recoverable_error);
    eval {
        ($error_type, $error_message, $is_recoverable_error) = $self->SUPER::determine_error_type($msg);
    };
    
    # If parent call failed or returned invalid values, use defaults
    # CRITICAL: We MUST always return a valid error_type to prevent undefined value warnings
    if ($@ || !defined $error_type) {
        $error_type = $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED;
        $error_message = "Unable to process error: " . ($@ || "Unknown error");
        $is_recoverable_error = 0;
    }
    
    # Ensure error_type is a valid numeric constant (not 0, not negative, not undefined)
    # ERROR_GENERIC_LOGGED should be a positive integer
    if (!defined $error_type || $error_type == 0 || $error_type !~ /^\d+$/ || $error_type < 0) {
        $error_type = $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED;
        $is_recoverable_error = 0;
    }
    
    # Ensure error_message is defined and not empty
    if (!defined $error_message || !length $error_message) {
        $error_message = "Unknown error occurred on remote server [$self->{'name'}]";
    }
    
    # Ensure is_recoverable_error is defined (should be 0 or 1)
    $is_recoverable_error = defined $is_recoverable_error ? ($is_recoverable_error ? 1 : 0) : 0;
    
    # FINAL CHECK: Double-check error_type is still valid before returning
    # This is a safety net to prevent any possibility of returning undefined
    if (!defined $error_type) {
        $error_type = $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED;
        $is_recoverable_error = 0;
        $error_message = "Error type was undefined - using generic error";
    }
    
    return ($error_type, $error_message, $is_recoverable_error);
}

# Override is_recoverable_error to handle undefined values gracefully
# This prevents "Use of uninitialized value" warnings when error_type is undefined
# When called as a method, Perl passes $self as first argument
# When called as a function, only the error_type is passed
sub is_recoverable_error {
    my ($self_or_error_type, $error_type) = @_;
    
    # If called as method ($self->is_recoverable_error($error_type)), 
    # $self_or_error_type is $self (a blessed reference) and $error_type is the actual error type
    # If called as function (is_recoverable_error($error_type)),
    # $self_or_error_type is the error type and $error_type is undef
    my $actual_error_type;
    if (ref($self_or_error_type) && ref($self_or_error_type) =~ /^Cpanel::NameServer::Remote/) {
        # Called as method: $self->is_recoverable_error($error_type)
        $actual_error_type = $error_type;
    } else {
        # Called as function: is_recoverable_error($error_type)
        $actual_error_type = $self_or_error_type;
    }
    
    # Return 0 (not recoverable) if error_type is undefined or 0
    return 0 if !defined $actual_error_type || $actual_error_type == 0;
    
    # Call parent function with defined value
    # Use eval and warning suppression to catch any issues from the parent function
    my $result = 0;
    eval {
        local $SIG{__WARN__} = sub {};  # Suppress warnings
        # Only call parent if we have a valid, defined error_type
        if (defined $actual_error_type && $actual_error_type =~ /^\d+$/ && $actual_error_type > 0) {
            $result = Cpanel::NameServer::Remote::is_recoverable_error($actual_error_type);
        }
    };
    
    # If eval failed or result is undefined, return 0 (not recoverable)
    return defined $result ? $result : 0;
}

1;

