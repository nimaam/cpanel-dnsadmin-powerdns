package Cpanel::NameServer::Setup::Remote::PowerDNS;

use strict;
use warnings;

use Cpanel::NameServer::Setup::Remote ();
our @ISA = qw(Cpanel::NameServer::Setup::Remote);

# Create a method that returns the configuration form.
sub get_config {
    my %config = (
        "name" => "PowerDNS",
        "options" => [
            {
                "name" => "api_url",
                "type" => "text",
                "locale_text" => "PowerDNS API URL",
                "required" => 1,
                "help" => "Full URL to PowerDNS API (e.g., https://powerdns.example.com:8081/api/v1 or https://powerdns.example.com/api/v1)",
            },
            {
                "name" => "pass",
                "type" => "password",
                "locale_text" => "PowerDNS API Token",
                "required" => 1,
                "help" => "Your PowerDNS API key/token for authentication",
            },
            {
                "name" => "debug",
                "type" => "binary",
                "locale_text" => "Enable Debug Mode",
                "default" => 0,
            },
        ],
    );
    return wantarray ? %config : \%config;
}

# Create a method that processes the configuration form data.
sub setup {
    my ($self, %OPTS) = @_;

    # Validate required fields
    my $api_url = $OPTS{"api_url"} || return (0, "API URL is required.");
    my $api_key = $OPTS{"pass"} || return (0, "API Token is required.");
    my $debug = $OPTS{"debug"} ? 1 : 0;
    my $user = $OPTS{"user"} || return (0, "User is required.");

    # Validate and normalize URL
    $api_url =~ s/\/+$//;  # Remove trailing slashes
    if ($api_url !~ /^https?:\/\//) {
        return (0, "API URL must start with http:// or https://");
    }

    # Create the config directory if it doesn't exist
    my $config_dir = "/var/cpanel/cluster/$user/config";
    if (!-d $config_dir) {
        require Cpanel::FileUtils::TouchFile;
        Cpanel::FileUtils::TouchFile::touchfile($config_dir);
        chmod(0755, $config_dir);
    }

    # Create the node configuration file
    my $config_file = "$config_dir/powerdns";
    my $fh;
    if (!open($fh, ">", $config_file)) {
        return (0, "Failed to create config file: $!");
    }

    # Write configuration file with version 2.0 header
    print $fh "#version 2.0\n";
    print $fh "user=$user\n";
    print $fh "api_url=$api_url\n";
    print $fh "pass=$api_key\n";
    print $fh "module=PowerDNS\n";
    print $fh "debug=" . ($debug ? "on" : "off") . "\n";

    close($fh);
    chmod(0600, $config_file);

    return (1, "PowerDNS node configuration created successfully.");
}

1;

