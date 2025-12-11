#!/bin/bash

# Simple test to check if get_config works (doesn't require HTTP::Client)

echo "=== Testing get_config method ==="
echo ""

/usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e '
use Cpanel::NameServer::Setup::Remote::PowerDNS;
# get_config is a class method, not instance method
my $config = Cpanel::NameServer::Setup::Remote::PowerDNS->get_config();
print "Config name: " . ($config->{"name"} || "N/A") . "\n";
print "Options count: " . scalar(@{$config->{"options"}}) . "\n\n";
print "Options:\n";
foreach my $opt (@{$config->{"options"}}) {
    print "  Field name: " . ($opt->{"name"} || "N/A") . "\n";
    print "  Field type: " . ($opt->{"type"} || "N/A") . "\n";
    print "  Field label: " . ($opt->{"locale_text"} || "N/A") . "\n";
    print "  Required: " . ($opt->{"required"} ? "Yes" : "No") . "\n";
    print "\n";
}
' 2>&1 | head -30

echo ""
echo "=== If you see the fields above, get_config is working ==="
echo "The HTTP::Client errors are expected when testing directly"
echo "cPanel will load it correctly in its web interface"

