#!/bin/bash

# Direct test of the setup method to see what's happening

echo "=== Testing PowerDNS Setup Module Directly ==="
echo ""

# Test if we can load the module
echo "1. Testing module loading..."
/usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e '
use Cpanel::NameServer::Setup::Remote::PowerDNS;
my $module = Cpanel::NameServer::Setup::Remote::PowerDNS->new();
my $config = $module->get_config();
print "Config name: " . ($config->{"name"} || "N/A") . "\n";
print "Options count: " . scalar(@{$config->{"options"}}) . "\n";
foreach my $opt (@{$config->{"options"}}) {
    print "  - " . ($opt->{"name"} || "N/A") . " (" . ($opt->{"type"} || "N/A") . ")\n";
}
' 2>&1

echo ""
echo "2. Testing setup method with sample data..."
/usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e '
use Cpanel::NameServer::Setup::Remote::PowerDNS;
my $module = Cpanel::NameServer::Setup::Remote::PowerDNS->new();
my ($success, $msg, $extra1, $extra2) = $module->setup(
    "user" => "root",
    "api_url" => "http://ns0.ultaservers.com:8081/api/v1",
    "apikey" => "gPJJ4FdWvz4ngNvx",
    "debug" => 0
);
if ($success) {
    print "✅ Setup successful: $msg\n";
    print "Extra1: " . ($extra1 || "N/A") . "\n";
    print "Extra2: " . ($extra2 || "N/A") . "\n";
} else {
    print "❌ Setup failed: $msg\n";
}
' 2>&1

echo ""
echo "3. Checking config file creation..."
if [ -f "/var/cpanel/cluster/root/config/powerdns" ]; then
    echo "✅ Config file exists:"
    cat /var/cpanel/cluster/root/config/powerdns | sed 's/apikey=.*/apikey=***HIDDEN***/' | sed 's/pass=.*/pass=***HIDDEN***/'
else
    echo "❌ Config file NOT found"
fi

echo ""
echo "=== Done ==="

