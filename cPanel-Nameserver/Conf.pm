package Cpanel::NameServer::Conf;

# cpanel - Cpanel/NameServer/Conf.pm               Copyright 2023 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use cPstrict;

use Cpanel::LoadModule         ();
use Cpanel::Config::LoadCpConf ();

=head1 NAME

Cpanel::NameServer::Conf

=head1 DESCRIPTION

Module for abstracting away "what config module for installed nameserver"

=head1 SYNOPSIS

    # Returns Cpanel::NameServer::Conf::PowerDNS object
    my $ns_conf_obj = Cpanel::NameServer::Conf->new();

    # Returns Cpanel::NameServer::Conf::BIND object
    system("sed -i 's/local_nameserver_type=.*/local_nameserver_type=bind/' /var/cpanel/cpanel.config");
    $ns_conf_obj = Cpanel::NameServer::Conf->new();

=head1 SEE ALSO

Cpanel::NameServer::Conf::BIND -- If you want to know the interface to the returned object, read this, as every module returned uses this as a parent.

=head1 METHODS

=head2 new

Factory class/dispatcher for nameserver conf object.
Return an conf object corresponding to
/var/cpanel/cpanel.config value => Class in subdirectory.
PowerDNS is returned if value is bogus or falsey.

=cut

my %ns_map = (
    'powerdns' => 'PowerDNS',
    'bind'     => 'BIND',
    'disabled' => 'BIND',
);

sub new ($class) {

    # Go off the local nameserver setting in cpanel.conf
    my $cpconf_ref = Cpanel::Config::LoadCpConf::loadcpconf_not_copy();
    my $ns_ns      = 'PowerDNS';                                          # Default Nameserver Namespace
    if ( $cpconf_ref->{'local_nameserver_type'} && $ns_map{ $cpconf_ref->{'local_nameserver_type'} } ) {
        $ns_ns = $ns_map{ $cpconf_ref->{'local_nameserver_type'} };
    }
    my $mod2use = "${class}::${ns_ns}";
    Cpanel::LoadModule::load_perl_module($mod2use);
    return $mod2use->new();
}

1;
