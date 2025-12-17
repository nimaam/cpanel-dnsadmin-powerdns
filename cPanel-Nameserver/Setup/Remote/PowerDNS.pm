package Cpanel::NameServer::Setup::Remote::PowerDNS;

use strict;
use Cpanel::FileUtils::Copy ();
use Cpanel::JSON ();
use Whostmgr::ACLS ();

## no critic (RequireUseWarnings) -- requires auditing for potential warnings

Whostmgr::ACLS::init_acls();

sub setup {
    my ($self, %OPTS) = @_;

    if (!Whostmgr::ACLS::checkacl("clustering")) {
        return (0, "User does not have the clustering ACL enabled.");
    }

    return (0, "No user given") if !defined $OPTS{"user"};
    return (0, "No API key given") if !defined $OPTS{"apikey"};
    return (0, "No API URL given") if !defined $OPTS{"api_url"};

    my $user    = $OPTS{"user"};
    my $apikey  = $OPTS{"apikey"};
    my $api_url = $OPTS{"api_url"};

    # Validate debug parameter
    my $debug = $OPTS{"debug"} ? 1 : 0;

    # Validate and sanitize parameters
    $user =~ tr/\r\n\f\0//d;
    return (0, "Invalid user given") if !$user;

    $apikey =~ tr/\r\n\f\0//d;
    return (0, "Invalid API key given") if !$apikey;

    $api_url =~ tr/\r\n\f\0//d;
    return (0, "Invalid API URL given") if !$api_url;

    # Validate and normalize URL
    $api_url =~ s/\/+$//;  # Remove trailing slashes
    if ($api_url !~ /^https?:\/\//) {
        return (0, "API URL must start with http:// or https://");
    }

    # Parse API URL to get base URL
    my $base_url = $api_url;
    if ($base_url !~ /\/api\/v1$/) {
        $base_url =~ s/\/+$//;
        $base_url .= "/api/v1";
    }

    # Test API connection before saving configuration
    # Try to use Cpanel::HTTP::Client, but fall back to curl if it fails
    my $connection_test_passed = 0;
    my $connection_error       = "";

    eval {
        require Cpanel::HTTP::Client;
        my $test_url = "$base_url/servers/localhost";
        my $ua = Cpanel::HTTP::Client->new(
            timeout    => 10,
            keep_alive => 1,
        );

        my $resp = $ua->get(
            $test_url,
            {
                headers => {
                    "X-API-Key"     => $apikey,
                    "Content-Type"  => "application/json",
                    "Accept"        => "application/json",
                }
            }
        );

        if ($resp->{"success"}) {
            $connection_test_passed = 1;
        }
        else {
            $connection_error = "Failed to connect to PowerDNS API: " . ($resp->{"status"} || "unknown") . " - " . ($resp->{"reason"} || "connection failed");
            if ($resp->{"content"}) {
                eval {
                    my $error_data = Cpanel::JSON::Load($resp->{"content"});
                    if (ref($error_data) eq "HASH" && $error_data->{"error"}) {
                        $connection_error .= " - " . $error_data->{"error"};
                    }
                };
            }
        }
    };

    # If HTTP::Client failed to load or test failed, try curl as fallback
    if (!$connection_test_passed && ($@ || $connection_error)) {
        my $test_url = "$base_url/servers/localhost";
        my $curl_cmd = "curl -s -w '\\nHTTP_CODE:%{http_code}' --max-time 10 -H 'X-API-Key: $apikey' -H 'Content-Type: application/json' '$test_url' 2>&1";
        my $curl_output = `$curl_cmd`;
        my $http_code = "";
        if ($curl_output =~ /HTTP_CODE:(\d+)/) {
            $http_code = $1;
        }

        if ($http_code eq "200") {
            $connection_test_passed = 1;
        }
        else {
            $connection_error = "Failed to connect to PowerDNS API (HTTP $http_code). Please verify API URL and key are correct.";
        }
    }

    if (!$connection_test_passed) {
        return (0, $connection_error || "Failed to test PowerDNS API connection. Please verify API URL and key are correct.");
    }

    # Create config directories
    my $safe_remote_user = $ENV{"REMOTE_USER"} || $user;
    $safe_remote_user =~ s/\///g;
    mkdir "/var/cpanel/cluster", 0700 if !-e "/var/cpanel/cluster";
    mkdir "/var/cpanel/cluster/$safe_remote_user", 0700 if !-e "/var/cpanel/cluster/$safe_remote_user";
    mkdir "/var/cpanel/cluster/$safe_remote_user/config", 0700 if !-e "/var/cpanel/cluster/$safe_remote_user/config";

    # Write configuration file
    my $config_file = "/var/cpanel/cluster/$safe_remote_user/config/powerdns";
    if (open(my $config_fh, ">", $config_file)) {
        chmod 0600, $config_file
          or warn "Failed to secure permissions on cluster configuration: $!";
        print {$config_fh} "#version 2.0\n";
        print {$config_fh} "user=$user\n";
        print {$config_fh} "api_url=$api_url\n";
        print {$config_fh} "apikey=$apikey\n";
        print {$config_fh} "pass=$apikey\n";  # Keep for backward compatibility
        print {$config_fh} "module=PowerDNS\n";
        print {$config_fh} "debug=$debug\n";
        close($config_fh);
    }
    else {
        warn "Could not write DNS trust configuration file: $!";
        return (0, "The trust relationship could not be established, please examine /usr/local/cpanel/logs/error_log for more information.");
    }

    # Copy to root config if user is root and root config doesn't exist
    if (!-e "/var/cpanel/cluster/root/config/powerdns" && Whostmgr::ACLS::hasroot()) {
        Cpanel::FileUtils::Copy::safecopy(
            "/var/cpanel/cluster/$safe_remote_user/config/powerdns",
            "/var/cpanel/cluster/root/config/powerdns"
        );
    }

    return (1, "The trust relationship with PowerDNS has been established.", "", "powerdns");
}

sub get_config {
    my %config = (
        "name" => "PowerDNS",
        "options" => [
            {
                "name"        => "api_url",
                "type"        => "text",
                "locale_text" => "PowerDNS API URL",
                "required"    => 1,
                "help"        => "Full URL to PowerDNS API (e.g., https://powerdns.example.com:8081/api/v1 or https://powerdns.example.com/api/v1)",
            },
            {
                "name"        => "apikey",
                "type"        => "text",
                "locale_text" => "PowerDNS API Token",
                "required"    => 1,
                "help"        => "Your PowerDNS API key/token for authentication",
            },
            {
                "name"        => "debug",
                "type"        => "binary",
                "locale_text" => "Enable Debug Mode",
                "default"     => 0,
            },
        ],
    );
    return wantarray ? %config : \%config;
}

1;
