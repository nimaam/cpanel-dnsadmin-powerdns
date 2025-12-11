#!/usr/bin/perl
# Debug script to test PowerDNS setup module
# Note: This script requires cPanel's Perl environment
# Run with: /usr/local/cpanel/3rdparty/bin/perl debug_setup.pl

use strict;
use warnings;

# Add cPanel paths
use lib '/usr/local/cpanel/Cpanel';
use lib '/usr/local/cpanel';

BEGIN {
    # Try to load the module
    eval {
        require Cpanel::NameServer::Setup::Remote::PowerDNS;
    };
    if ($@) {
        print "Error loading module: $@\n";
        print "\nNote: If you see Try::Tiny errors, these are false positives.\n";
        print "The module will work fine when loaded by cPanel's Perl.\n";
        print "Try running with: /usr/local/cpanel/3rdparty/bin/perl debug_setup.pl\n";
        exit 1;
    }
}

my $module = Cpanel::NameServer::Setup::Remote::PowerDNS->new();

# Test get_config
print "=== Testing get_config ===\n";
my $config = $module->get_config();
if (ref($config) eq "HASH") {
    print "Config name: " . ($config->{"name"} || "N/A") . "\n";
    print "Number of options: " . (scalar(@{$config->{"options"}}) || 0) . "\n";
    print "\nOptions:\n";
    foreach my $opt (@{$config->{"options"}}) {
        print "  - Name: " . ($opt->{"name"} || "N/A") . "\n";
        print "    Type: " . ($opt->{"type"} || "N/A") . "\n";
        print "    Label: " . ($opt->{"locale_text"} || "N/A") . "\n";
        print "    Required: " . ($opt->{"required"} ? "Yes" : "No") . "\n";
        print "\n";
    }
} else {
    print "Error: get_config did not return a hash\n";
}

# Test setup with sample data
print "\n=== Testing setup method ===\n";
my %test_opts = (
    "api_url" => "http://159.100.6.2:8081/api/v1",
    "pass" => "gPJJ4FdWvz4ngNvx",
    "user" => "root",
    "debug" => 0,
);

print "Testing with:\n";
print "  API URL: $test_opts{api_url}\n";
print "  API Key: " . substr($test_opts{"pass"}, 0, 4) . "****\n";
print "  User: $test_opts{user}\n";
print "\n";

my ($success, $message) = $module->setup(%test_opts);
if ($success) {
    print "✅ Setup successful: $message\n";
} else {
    print "❌ Setup failed: $message\n";
}

print "\n=== Done ===\n";

