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

    # Parse API URL to get base URL and extract hostname
    my $base_url = $api_url;
    if ($base_url !~ /\/api\/v1$/) {
        $base_url =~ s/\/+$//;
        $base_url .= "/api/v1";
    }
    
    # Extract hostname from API URL (for display purposes)
    # If API URL uses IP, we'll try to resolve it later, but store what we can get
    my $hostname = "";
    if ($api_url =~ /https?:\/\/([^:\/]+)/) {
        $hostname = $1;
        # If it's an IP, we'll leave it as is (getpath will try to resolve it)
        # If it's a hostname, use it
    }

    # Test API connection before saving configuration
    # Try multiple endpoints to ensure connection works
    my $connection_test_passed = 0;
    my $connection_error       = "";
    my @test_endpoints = (
        "$base_url/servers/localhost",
        "$base_url/servers",
    );

    foreach my $test_url (@test_endpoints) {
        last if $connection_test_passed;
        
        eval {
            require Cpanel::HTTP::Client;
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

            if ($resp && $resp->{"success"}) {
                $connection_test_passed = 1;
                $connection_error = "";
                last;
            }
            elsif ($resp) {
                my $status = $resp->{"status"} || "unknown";
                # 401/403 are auth errors, but 404 might mean wrong endpoint - try next
                if ($status == 401 || $status == 403) {
                    $connection_error = "Authentication failed (HTTP $status). Please verify your API key is correct.";
                }
                elsif ($status == 404 && !$connection_error) {
                    # 404 might mean wrong endpoint, try next endpoint
                    next;
                }
                elsif (!$connection_error) {
                    my $reason = $resp->{"reason"} || "connection failed";
                    $connection_error = "Failed to connect to PowerDNS API: HTTP $status - $reason";
                    
                    if ($resp->{"content"}) {
                        eval {
                            my $error_data = Cpanel::JSON::Load($resp->{"content"});
                            if (ref($error_data) eq "HASH" && $error_data->{"error"}) {
                                $connection_error .= " - " . $error_data->{"error"};
                            }
                        };
                    }
                }
            }
            else {
                $connection_error = "Failed to get response from PowerDNS API" if !$connection_error;
            }
        };

        # If HTTP::Client failed, try curl as fallback for this endpoint
        if (!$connection_test_passed && $@) {
            eval {
                my $curl_cmd = "curl -s -w '\\nHTTP_CODE:%{http_code}' --max-time 10 -H 'X-API-Key: $apikey' -H 'Content-Type: application/json' -H 'Accept: application/json' '$test_url' 2>&1";
                my $curl_output = `$curl_cmd`;
                my $http_code = "";
                if ($curl_output =~ /HTTP_CODE:(\d+)/) {
                    $http_code = $1;
                }

                if ($http_code eq "200") {
                    $connection_test_passed = 1;
                    $connection_error = "";
                    last;
                }
                elsif ($http_code eq "401" || $http_code eq "403") {
                    $connection_error = "Authentication failed (HTTP $http_code). Please verify your API key is correct.";
                }
                elsif ($http_code eq "404" && !$connection_error) {
                    # Try next endpoint
                    next;
                }
                elsif ($http_code && !$connection_error) {
                    $connection_error = "Failed to connect to PowerDNS API (HTTP $http_code). Please verify API URL and key are correct.";
                }
            };
        }
    }

    if (!$connection_test_passed) {
        # If we got a specific error message, use it; otherwise provide a generic one
        my $error_msg = $connection_error || "Failed to test PowerDNS API connection. Please verify API URL and key are correct.";
        # Log the error for debugging
        warn "PowerDNS setup connection test failed: $error_msg";
        return (0, $error_msg);
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
        # Store hostname for display (extracted from API URL)
        # This helps cPanel identify the node correctly
        if ($hostname) {
            print {$config_fh} "host=$hostname\n";
        }
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
