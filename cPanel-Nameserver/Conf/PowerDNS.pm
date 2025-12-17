package Cpanel::NameServer::Conf::PowerDNS;

# cpanel - Cpanel/NameServer/Conf/PowerDNS.pm      Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

=encoding utf-8

=head1 NAME

Cpanel::NameServer::Conf::PowerDNS

=head1 SYNOPSIS

    use Cpanel::NameServer::Conf::PowerDNS ();
    my $ns_obj = Cpanel::NameServer::Conf::PowerDNS->new();

    # Enable dnssec with defaults for $domain
    $ns_obj->secure_zone($ns_obj->algo_config_defaults(), $domain);
    # If set_nsec3 is not called right after secure_zone then
    # we need to rectify the zone.
    $ns_obj->rectify($domain);

    # Disable dnssec on $domain - removes all configured keys for $domain
    $ns_obj->unsecure_zone($domain);

=cut

use parent                                           qw( Cpanel::NameServer::Conf::BIND );
use Cpanel::Exception                                ();
use Cpanel::NameServer::Utils::PowerDNS              ();
use Cpanel::Rand::Get                                ();
use Cpanel::DnsUtils::Cluster                        ();
use Cpanel::NameServer::DNSSEC::SyncKeys             ();
use Cpanel::NameServer::DNSSEC::Cache                ();
use Cpanel::NameServer::Conf::PowerDNS::WebserverAPI ();
use Cpanel::Locale::Lazy 'lh';

our $wsapi;

=head1 Methods

=over 8

=item B<new()>

Constructor.

B<Input>: None.

B<Output>: Returns a C<Cpanel::NameServer::Conf::PowerDNS> object.

=cut

sub new {
    my ($class) = @_;
    my $self = $class->SUPER::new();

    bless $self, $class;
    return $self;
}

=item B<type()>

B<Input>: None.

B<Output>: Returns the string literal C<powerdns>.

=cut

sub type { return 'powerdns'; }

=item B<initialize()>

Intializes the object, and marks it as so for subsequent calls.

B<Input>: None.

B<Output>:

Returns 1 on successful initialization.
Returns undef if object was previous initialized.

=cut

sub initialize {
    my $self = shift;
    $self->SUPER::initialize();

    if ( exists $self->{ 'initialized_' . __PACKAGE__ } && $self->{ 'initialized_' . __PACKAGE__ } ) {
        return;
    }

    $self->{ 'initialized_' . __PACKAGE__ } = 1;
    return 1;
}

=item B<reconfig()>

This method is called whenever a zone is added or removed
via C<Cpanel::NameServer::Local::cPanel::reconfigurebind()>.

It triggers the C<rediscover> functionality via PowerDNS's
C<pdns_control> utility.

B<Input>: None.

B<Output>: Returns a hashref detailing the success or failure
of the command:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub reconfig {
    my $self = shift;

    return Cpanel::NameServer::Utils::PowerDNS::run_pdns_control( { 'args' => ['rediscover'] } );
}

=item B<reload()>

This triggers the C<reload> functionality via PowerDNS's
C<pdns_control> utility.

This does B<not> reload the zones in the foreground like BIND's reload.
If PowerDNS detects that the zone-file has been changed when processing a
query for the zone, then it reloads the zone data from the file.

B<Input>: None.

B<Output>: Returns a hashref detailing the success or failure
of the command:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub reload {
    my $self = shift;

    # The 'reload' tells the PowerDNS daemon to reload the zone data, if it
    # detects that the bind zone-file has been changed when processing a
    # query against that zone.
    #
    # We could alternatively, do a 'bind-reload-now' call here on each zone passed in,
    # however, that will require a call for each zone, but this would be a blocking
    # call, that forces the data refresh to happen *now* instead of when needed.
    return Cpanel::NameServer::Utils::PowerDNS::run_pdns_control( { 'args' => ['reload'] } );
}

=item B<savezone($zone)>

This triggers the C<bind-add-zone> functionality via PowerDNS's
C<pdns_control> utility.

This is called B<after> the zonefile is updated in the
C<savezone()>, and C<synczones()> methods of C<Cpanel::NameServer::Local::cPanel>.

B<Input>: The C<$zone> to add.

This assumes that the C<$zone> being added has a zonefile named appropriately
in the C<named>'s zonedir (normally, C</var/named/>)

B<Output>: Returns a hashref detailing the success or failure
of the command:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub savezone {
    my $self = shift;
    my $zone = shift;

    return Cpanel::NameServer::Utils::PowerDNS::run_pdns_control( { 'args' => [ 'bind-add-zone', '--', $zone, "$self->{'config'}->{'zonedir'}/$zone.db" ] } );
}

=item B<removezones(@zones)>

This triggers the C<bind-remove-zone> functionality via PowerDNS's
C<pdns_control> utility.

This removes ALL dnssec keys associated with the zones, and removing
the zones from PowerDNS's memory, B<before> removing
the entries from named.conf.

B<Input>: The C<@zones> to remove.

B<Output>: Returns list of zones removed.

=cut

sub removezones {
    my ( $self, @zones ) = @_;

    my %domains_with_dnssec = map { $_ => 1 } Cpanel::NameServer::DNSSEC::Cache::has_dnssec(@zones);

    foreach my $zone (@zones) {

        # Remove any dnssec keys if they exist
        $self->unsecure_zone($zone)
          if exists $domains_with_dnssec{$zone};

        # Clear zones from active pdns server
        my ( $status, $message ) = Cpanel::NameServer::Utils::PowerDNS::run_pdns_control( { 'args' => [ 'bind-remove-zone', '--', $zone ] } )->@{ 'success', 'error' };

        # This shouldn't fail, but if it does...
        if ( !$status ) {
            require Cpanel::Debug;
            Cpanel::Debug::log_warn("Unable to remove “$zone” from PowerDNS: $message");
        }
    }

    # Remove zones from named.conf
    return $self->remove_zone_config( \@zones );
}

=item B<remove_zone_config(\@zones)>

Removes the zones from the named.conf.

Calls the parent's C<removezones> method.

B<Input>: The C<@zones> to removes.

B<Output>: Returns list of zones removed.

=cut

sub remove_zone_config {
    my ( $self, $zones_ar ) = @_;
    return $self->SUPER::removezones( @{$zones_ar} );
}

=item B<secure_zone(\%algo_config, $domain)>

Secures the specified domain with DNSSEC using
the algorithm parameters specified in C<$algo_config>.

This triggers the C<add-zone-key> functionality via PowerDNS's
C<pdnsutil> utility.

Callers are expected to call C<rectify> on the zone after calling
this function if they do not call C<set_nsec3> following
this call.

B<Input>: The C<\%algo_config> must be a hashref that
is validated via the C<validate_algo_config> method.

The C<$domain> is the domain to secure.

B<Output>: Returns a hashref detailing the success or failure
of the C<add-zone-key> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub secure_zone {
    my ( $self, $algo_config, $domain ) = @_;

    #
    # This was previously calling get_zone which was
    # just appending a '.' to the $domain.  This appears
    # to no longer be needed with the switch to the webserver api
    #
    #since we fiddle with the ref in _addkey
    my %cloned_config = %$algo_config;
    my $run           = _addkey( \%cloned_config, $domain, 'ksk' );
    my $type          = 'ksk';
    my $generic_error = { error => lh()->maketext( "Failed to create [asis,DNSSEC] key of type “[_1]” for zone “[_2]”.", $type, $domain ) };
    return $generic_error if ref($run) ne 'HASH' || !$run->{'id'};

    if ( $algo_config->{'key_setup'} && $algo_config->{'key_setup'} eq 'classic' ) {
        my $run = _addkey( $algo_config, $domain, 'zsk' );
        if ( ref($run) ne 'HASH' || !$run->{'id'} ) {
            $self->unsecure_zone($domain);
            my $type = 'zsk';
            return $generic_error;
        }
    }

    Cpanel::NameServer::DNSSEC::Cache::enable($domain);

    # PowerDNS docs recommend running this after securing a zone,
    # as it fixes the 'ordername' and 'auth' fields.
    #
    # This is not strictly required on newly secured zones, but since
    # it becomes a noop if no changes are needed, its safe to do.
    # We no longer do a rectify and rely on the caller to do this if needed
    return $run;
}

sub _addkey {
    my ( $algo_config, $domain, $type ) = @_;

    my $other_type = $type eq 'zsk' ? 'ksk' : 'zsk';
    $algo_config->{bits} = delete $algo_config->{"$type\_size"};
    delete $algo_config->{"$other_type\_size"} if $algo_config->{"$other_type\_size"};
    $algo_config->{algorithm} = delete $algo_config->{tag};
    $algo_config->{keytype}   = $type;
    delete $algo_config->{'key_setup'};

    my $result = wsapi()->secure_zone( $domain, $algo_config );

    if ( $result->{id} && $result->{id} =~ /^[0-9]+$/ ) {
        _sync_key( 'sync', $domain, $result->{id} );
    }

    return $result;
}

=item B<ds_records($domain)>

Parses the output from PowerDNS's C<WebserverAPI> C<get-zone>
and C<get-key> commands, and returns information about the DNSSEC keys
currently configured for the C<$domain>, including the
delegation signing (DS) records associated with any KSK/CSK.

B<Input>: The C<$domain> is the domain to fetch information about.

B<Output>: Returns a hashref detailing the keys associated with the domain:

    {
        'nsec_details' => {
            'nsec_version' => 'NSEC'
        },
        'keys' => {
            '52309' => {
                'algo_desc' => 'RSA/SHA-256',
                'algo_num' => '8',
                'active' => 1,
                'key_id' => '1392',
                'key_tag' => '52309',
                'key_type' => 'CSK',
                'digests' => [
                    {
                        'algo_num' => '1',
                        'digest' => 'e46cc26e322f805e16af15b8520a61acea5070fb',
                        'algo_desc' => 'SHA-1'
                    },
                    {
                        'algo_desc' => 'SHA-256',
                        'algo_num' => '2',
                        'digest' => '0f64d41bc4d831991483b0072ff424f8e2c60c148b4bab00a4d2ea359d8e049c'
                    },
                    {
                        'algo_num' => '4',
                        'digest' => 'd256aca04695cf7ded61d60eb4423284c9da85c426a4e4a414418f59efe7300aa35d2df5b4d8c001206299c694e96787',
                        'algo_desc' => 'SHA-384'
                    }
                ],
                'flags' => '257',
                'algo_tag' => 'RSASHA256',
                'bits' => '2048'
            }
        }
    };

=cut

sub ds_records {
    my ( $self, $domain ) = @_;

    my $records = {};
    my $zone    = wsapi()->get_zone($domain);
    return $records if !$zone || ref $zone ne 'HASH';

    if ( $zone->{nsec3param} ) {
        $records->{nsec_details}{nsec_version} = 'NSEC3';
        $records->{nsec_details}{nsec3_narrow} = $zone->{'nsec3narrow'} ? 1 : 0;
        my @nsec_conf = split( /\s/, $zone->{nsec3param} );
        $records->{'nsec_details'}{'nsec3_hash_algo_desc'} = _supported_digests()->{ $nsec_conf[0] };
        @{ $records->{nsec_details} }{qw{nsec3_hash_algo_num nsec3_opt_out nsec3_iterations nsec3_salt}} = @nsec_conf;
    }

    my $keys = $self->list_keys($domain);

    $records->{keys} = $keys if scalar keys %$keys;

    return $records;
}

=item B<list_keys($domain)>

Parses the output from PowerDNS's C<WebserverAPI>  C<get-key> commands,
and returns information about the DNSSEC keys
currently configured for the C<$domain>, including the
delegation signing (DS) records associated with any KSK/CSK.

This function returns actually the same output as the 'keys'
field in ds_records

B<Input>: The C<$domain> is the domain to fetch information about.

B<Output>: Returns a hashref detailing the keys associated with the domain:

    {
          '52309' => {
              'algo_desc' => 'RSA/SHA-256',
              'algo_num' => '8',
              'active' => 1,
              'key_id' => '1392',
              'key_tag' => '52309',
              'key_type' => 'CSK',
              'digests' => [
                  {
                      'algo_num' => '1',
                      'digest' => 'e46cc26e322f805e16af15b8520a61acea5070fb',
                      'algo_desc' => 'SHA-1'
                  },
                  {
                      'algo_desc' => 'SHA-256',
                      'algo_num' => '2',
                      'digest' => '0f64d41bc4d831991483b0072ff424f8e2c60c148b4bab00a4d2ea359d8e049c'
                  },
                  {
                      'algo_num' => '4',
                      'digest' => 'd256aca04695cf7ded61d60eb4423284c9da85c426a4e4a414418f59efe7300aa35d2df5b4d8c001206299c694e96787',
                      'algo_desc' => 'SHA-384'
                  }
              ],
              'flags' => '257',
              'algo_tag' => 'RSASHA256',
              'bits' => '2048'
          }
    };

=cut

sub list_keys {
    my ( $self, $domain ) = @_;

    my $keys     = {};
    my $all_keys = wsapi()->list_keys($domain);
    return $keys if !$all_keys || ref $all_keys ne 'ARRAY';

    my $algo_info = _supported_algorithms();

    foreach my $key ( @{$all_keys} ) {
        my $tag     = $key->{keytag};
        my $keyinfo = {};
        $keyinfo->{active}   = $key->{active} ? 1 : 0;
        $keyinfo->{key_tag}  = $tag;
        $keyinfo->{key_id}   = $key->{id};
        $keyinfo->{key_type} = uc( $key->{keytype} );
        $keyinfo->{algo_tag} = $key->{algorithm};
        $keyinfo->{bits}     = $key->{bits};
        $keyinfo->{flags}    = $key->{flags};
        my ($algo_num) = grep { $algo_info->{$_}->{tag} eq $key->{algorithm} } keys %$algo_info;
        $keyinfo->{algo_num}   = $algo_num;
        $keyinfo->{algo_desc}  = $algo_info->{$algo_num}{desc};
        $keyinfo->{created}    = $key->{created};
        $keyinfo->{privatekey} = $key->{privatekey};

        foreach my $ds_record ( @{ $key->{ds} } ) {
            my @ds_parts = split( /\s/, $ds_record );
            my $ds       = {};
            $ds->{algo_num}  = $ds_parts[2];
            $ds->{algo_desc} = _supported_digests()->{ $ds_parts[2] };
            $ds->{digest}    = $ds_parts[3];
            push( @{ $keyinfo->{digests} }, $ds );
        }

        $keys->{$tag} = $keyinfo;
    }

    return $keys;
}

=item B<unsecure_zone($domain)>

Unsecures the specified domain by removing any and all DNSSEC
keys associated with the specified C<$domain>.

This triggers the C<disable-dnssec> functionality via PowerDNS's
C<pdnsutil> utility.

B<Input>: The C<$domain> is the domain to unsecure.

B<Output>: Returns a hashref detailing the success or failure
of the C<disable-dnssec> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub unsecure_zone {
    my ( $self, $domain ) = @_;

    if ( Cpanel::DnsUtils::Cluster::is_clustering_enabled() ) {
        my $cluster = Cpanel::NameServer::DNSSEC::SyncKeys->new($domain);
        $cluster->revoke_keys( $cluster->get_active_keytags() );
    }

    my $ret = wsapi()->unsecure_zone($domain);
    Cpanel::NameServer::DNSSEC::Cache::disable($domain) if $ret;
    return $ret;
}

=item B<set_nsec3($domain, \%config)>

Updates the NSEC3 semantics configured for the specified C<$domain>.

This triggers the C<set-nsec3> functionality via PowerDNS's
C<Webserver API> utility.

B<Input>: The C<\%config> must be a hashref that
is validated via the C<validate_nsec3_config> method.

The C<$domain> is the domain to modify.

B<Output>: Returns a hashref detailing the success or failure
of the C<set-nsec3> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1 }

=cut

sub set_nsec3 {
    my ( $self, $domain, $config ) = @_;

    # String detailing the 'HASH-ALGORITHM FLAGS ITERATIONS SALT':
    #
    # HASH-ALGORITHM must be 1 (SHA-1).
    #
    # FLAGS => 1 enables NSEC3 opt-out operation.
    #         It's going to be very rarely used. As you only want this set if you have a huge number of delegations.
    #
    # ITERATIONS => please consult RFC 5155, section 10.3. And be aware that a high number might overload validating resolvers.
    #
    # The SALT is a hexadecimal string encoding the bits for the salt.
    $config->{do_nsec3} //= 1;
    my $params = join " ", ( 1, ( $config->{'nsec3_opt_out'} // 0 ), ( $config->{'nsec3_iterations'} // 7 ), ( $config->{'nsec3_salt'} // 'ab' ) );

    # Setting narrow will make the responses contain "white lies" about the next secure record.
    # Instead of looking it up in the database, it will send out the hash + 1 as the next secure record.
    # This prevents zone-walking, and also allows for slightly faster responses.
    my ( $nsec_ret, $return );
    eval { $nsec_ret = wsapi()->set_nsec3( $domain, $params, $config->{do_nsec3} ) };
    if ($nsec_ret) {

        $return->{success} = 1;

        # Need to rectify the zone after changes are made to the NSEC settings
        # it becomes a noop if no changes are needed, its safe to do.
        $self->rectify($domain);

        # Clears the packetcache that makes the changes visible more readily
        Cpanel::NameServer::Utils::PowerDNS::run_pdns_control( { 'args' => [ 'purge', '--', $domain ] } );
    }
    else {
        $return->{success} = 0;
        $return->{error}   = lh()->maketext( "Failed to set [asis,NSEC3] configuration for zone “[_1]”.", $domain );
    }

    return $return;
}

=item B<unset_nsec3($domain)>

Switch the specified C<$domain> back to using NSEC semantics.

This triggers the C<unset-nsec3> functionality via PowerDNS's
C<pdnsutil> utility.

B<Input>: The C<$domain> is the domain to modify.

B<Output>: Returns a hashref detailing the success or failure
of the C<unset-nsec3> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub unset_nsec3 {
    my ( $self, $domain ) = @_;
    return $self->set_nsec3( $domain, { do_nsec3 => 0 } );
}

=item B<fetch_domains_with_dnssec()>

This triggers the C<list-secure-zones> functionality via PowerDNS's
C<WebserverAPI> utility. B<WARNING:> This is an expensive call on servers
with many zones, please consider using C<Cpanel::NameServer::DNSSEC::Cache>

B<Input>: None.

B<Output>: Returns an arrayref containing the list of domains with
DNSSEC keys configured.

    []
    [
        'cptest.tld',
        'foo.bar',
        'bar.baz'
    ]

=cut

sub fetch_domains_with_dnssec {
    my $self = shift;
    return wsapi()->list_secure_zones();
}

=item B<activate_zone_key($domain, $key_id)>

Activates the DNSSEC key with the specified C<$key_id>,
for the specified C<$domain>.

This triggers the C<activate-zone-key> functionality via PowerDNS's
C<Webserver API> utility.

B<Input>: The C<$domain> is the domain to modify.
The C<$key_id> is the ID of the key to activate.

B<Output>: Returns a hashref detailing the success or failure
of the C<activate-zone-key> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1 };

=cut

sub activate_zone_key {
    my ( $self, $domain, $key_id ) = @_;

    _sync_key( 'sync', $domain, $key_id );

    my $ret;
    eval { $ret = wsapi()->activate_zone_key( $domain, $key_id ) };
    return { 'success' => 1 } if $ret;
    return { 'success' => 0, 'error' => lh()->maketext( "Failed to activate [asis,DNSSEC] key “[_1]” for zone “[_2]”.", $key_id, $domain ) };
}

=item B<deactivate_zone_key($domain, $key_id)>

Deactivates the DNSSEC key with the specified C<$key_id>,
for the specified C<$domain>.

This triggers the C<deactivate-zone-key> functionality via PowerDNS's
C<Webserver API> utility.

B<Input>: The C<$domain> is the domain to modify.
The C<$key_id> is the ID of the key to deactivate.

B<Output>: Returns a hashref detailing the success or failure
of the C<deactivate-zone-key> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1 };

=cut

sub deactivate_zone_key {
    my ( $self, $domain, $key_id ) = @_;

    _sync_key( 'revoke', $domain, $key_id );

    my $ret;
    eval { $ret = wsapi()->deactivate_zone_key( $domain, $key_id ) };
    return { 'success' => 1 } if $ret;
    return { 'success' => 0, 'error' => lh()->maketext( "Failed to deactivate [asis,DNSSEC] key “[_1]” for zone “[_2]”.", $key_id, $domain ) };
}

=item B<add_zone_key($domain, \%key_config)>

Adds a new DNSSEC key for the specified C<$domain>, using the
configuration specified in C<\%key_config>.

This triggers the C<add-zone-key> functionality via PowerDNS's
C<pdnsutil> utility.

B<Input>: The C<$domain> is the domain to modify.
The C<\%key_config> must be a hashref that
is generated via the C<generate_key_config_based_on_algo_num_and_key_type> method.

B<Output>: Returns a hashref detailing the success or failure
of the C<add-zone-key> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub add_zone_key {
    my ( $self, $domain, $key_config ) = @_;
    #
    # This was previously calling get_zone which was
    # just appending a '.' to the $domain.  This appears
    # to no longer be needed with the switch to the webserver api
    #

    Cpanel::NameServer::DNSSEC::Cache::enable($domain);

    if ( lc( $key_config->{'key_type'} ) eq 'ksk' ) {
        return _addkey( $key_config, $domain, 'ksk' );
    }

    return _addkey( $key_config, $domain, 'zsk' );
}

=item B<remove_zone_key($domain, $key_id)>

Removes the DNSSEC key with the specified C<$key_id>,
for the specified C<$domain>.

This triggers the C<remove-zone-key> functionality via PowerDNS's
C<Webserver API> utility.

B<Input>: The C<$domain> is the domain to modify.
The C<$key_id> is the ID of the key to remove.

B<Output>: Returns a hashref detailing the success or failure
of the C<remove-zone-key> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1 };

=cut

sub remove_zone_key {
    my ( $self, $domain, $key_id ) = @_;

    _sync_key( 'revoke', $domain, $key_id );

    my $return;
    eval { $return = wsapi()->remove_zone_key( $domain, $key_id ) };

    return { 'success' => 1 } if $return;
    return { 'success' => 0, 'error' => lh()->maketext( "Failed to remove [asis,DNSSEC] key “[_1]” for zone “[_2]”.", $key_id, $domain ) };
}

=item B<import_zone_key($domain, $key_data, $key_type)>

Imports the DNSSEC key in C<$key_data>, as the
specified C<$key_type>, for the specified C<$domain>.

This triggers the C<import-zone-key> functionality via PowerDNS's
C<WebserverAPI> utility.

B<Input>: The C<$domain> is the domain to modify.
The C<$key_data> is a string containing the DNSSEC key in the ICS format that PowerDNS recognizes.
The C<$key_type> is the key type (KSK or ZSK) to use when importing.

B<Output>: Returns a hashref detailing the success or failure
of the C<import-zone-key> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub import_zone_key {
    my ( $self, $domain, $key_data, $key_type ) = @_;

    my $key_imported;
    {
        $key_imported = wsapi()->import_key( $domain, $key_type, $key_data );
        if ( $key_imported->{error} ) {
            return { 'success' => 0, 'error' => lh()->maketext( "Failed to import [asis,DNSSEC] key for “[_1]”: [_2]", $domain, $key_imported->{error} ) };
        }
    }
    if ( $key_imported->{id} ) {
        _sync_key( 'sync', $domain, $key_imported->{id} );
    }

    Cpanel::NameServer::DNSSEC::Cache::enable($domain);

    return {
        'success'    => 1,
        'new_key_id' => $key_imported->{id},
        'output'     => lh()->maketext( "Imported [asis,DNSSEC] key for “[_1]” with id “[_2]”.", $domain, $key_imported->{id} ),
    };
}

=item B<export_zone_key($domain, $key_id)>

Exports the DNSSEC key with the specified C<$key_id>,
for the specified C<$domain>.

This triggers the C<get_key> functionality via PowerDNS's
C<WebserverAPI> utility.

B<Input>: The C<$domain> is the domain to modify.
The C<$key_id> is the ID of the key to remove.

B<Output>: Returns a hashref detailing the success or failure
of the C<get_key> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'output' => $output };

=cut

sub export_zone_key {
    my ( $self, $domain, $key_id ) = @_;

    my $key = wsapi()->get_key_by_id( $domain, $key_id );
    if ( $key->{id} && $key->{id} == $key_id ) {
        return { 'success' => 1, 'output' => $key->{privatekey} };
    }
    return { 'success' => 0, 'error' => lh()->maketext( "Failed to obtain [asis,DNSSEC] key “[_1]” for zone “[_2]”.", $key_id, $domain ) };
}

=item B<export_zone_dnskey($domain, $key_id)>

Exports the public DNSKEY with the specified C<$key_id>,
for the specified C<$domain>.

B<Input>: The C<$domain> is the domain from which to retrieve information.
The C<$key_id> is the ID of the key to retrieve.

B<Output>: Returns a hashref detailing the success or failure
of the C<export-zone-dnskey> operations:

    { 'success' => 0, 'error' => $output };
    { 'success' => 1, 'dnskey' => $output };

=cut

sub export_zone_dnskey {
    my ( $self, $domain, $key_id ) = @_;

    my $key = wsapi()->get_key_by_id( $domain, $key_id );
    if ( $key->{id} && $key->{id} == $key_id && length $key->{'dnskey'} ) {
        return { 'success' => 1, 'dnskey' => ( split /\s/, $key->{'dnskey'} )[-1] };
    }
    return { 'success' => 0, 'error' => lh()->maketext( "Failed to obtain [asis,DNSSEC] key “[_1]” for zone “[_2]”.", $key_id, $domain ) };
}

sub validate_algo_config {
    my ( $self, $algo_config ) = @_;

    my $validated_config = {};
    if ( my $def_algo = _supported_algorithms()->{ $algo_config->{'algo_num'} } ) {
        $validated_config->{'algo_num'} = $algo_config->{'algo_num'};
        $validated_config->{'tag'}      = $def_algo->{'tag'};

        foreach my $valid_key (qw(key_setup ksk_size zsk_size active)) {
            if ( $algo_config->{$valid_key} eq 'auto' ) {
                $validated_config->{$valid_key} = $def_algo->{$valid_key};
            }
            else {
                $validated_config->{$valid_key} = $algo_config->{$valid_key};
            }
        }

        for my $key (qw{ksk_size zsk_size}) {
            die Cpanel::Exception::create( 'InvalidParameter', '“[_1]” must be a positive integer.', [$key] )
              if !_is_postive_int( $validated_config->{$key} );
        }

        if ( !( $validated_config->{'key_setup'} eq 'simple' || $validated_config->{'key_setup'} eq 'classic' ) ) {
            die Cpanel::Exception::create( 'InvalidParameter', 'The “[_1]” parameter must be one of the following: [join,~, ,_2]', [ 'key_setup', [ 'simple', 'classic' ] ] );
        }

        if ( $validated_config->{'key_setup'} eq 'simple' && $validated_config->{'algo_num'} < 13 ) {
            die Cpanel::Exception::create( 'InvalidParameter', 'Simple key setup is not supported with the specified algorithm.' );
        }

        return $validated_config;
    }

    die Cpanel::Exception::create( 'InvalidParameter', '“[_1]” is not a supported algorithm.', [ $algo_config->{'algo_num'} ] );
}

sub validate_nsec3_config {
    my ( $self, $nsec3_config ) = @_;

    my $nsec_params = {
        'nsec3_opt_out' => sub {
            die Cpanel::Exception::create( 'InvalidParameter', 'The “[_1]” parameter must be one of the following: [join,~, ,_2]', [ 'nsec3_opt_out', [ 0, 1 ] ] )
              if $_[0] !~ m/\A[01]\z/;
            return 1;
        },
        'nsec3_iterations' => sub {
            die Cpanel::Exception::create( 'InvalidParameter', '“[_1]” must be a positive integer less than or equal to [_2].', [ 'nsec3_iterations', '2500' ] )
              if !( _is_postive_int( $_[0] ) && $_[0] <= 2500 );
            return 1;
        },
        'nsec3_narrow' => sub {
            die Cpanel::Exception::create( 'InvalidParameter', 'The “[_1]” parameter must be one of the following: [join,~, ,_2]', [ 'nsec3_narrow', [ 0, 1 ] ] )
              if $_[0] !~ m/\A[01]\z/;
            return 1;
        },
        'nsec3_salt' => sub {
            die Cpanel::Exception::create( 'InvalidParameter', 'The “[_1]” parameter must be a string of length less than or equal to [_2] and containing only valid hexadecimal characters: [join,~, ,_3]', [ 'nsec3_salt', 255, [ 'a-f', '0-9' ] ] )
              if !( $_[0] =~ m/\A[0-9a-f]+\z/i && length( $_[0] ) <= 255 );
            return 1;
        },
    };

    foreach my $required_param ( keys %{$nsec_params} ) {
        $nsec_params->{$required_param}->( $nsec3_config->{$required_param} );
    }

    return $nsec3_config;
}

sub algo_config_defaults {
    my ( $self, $algo_config ) = @_;
    my $new_algo_config = {
        algo_num  => $algo_config->{algo_num}  // 8,
        key_setup => $algo_config->{key_setup} // 'auto',
        ksk_size  => $algo_config->{ksk_size}  // 'auto',
        zsk_size  => $algo_config->{zsk_size}  // 'auto',
        active    => $algo_config->{active}    // 1,
    };
    return $new_algo_config;
}

sub nsec_config_defaults {
    my ( $self, $nsec_config ) = @_;
    my $new_nsec_config = {
        use_nsec3        => $nsec_config->{use_nsec3}        // 1,
        nsec3_opt_out    => $nsec_config->{nsec3_opt_out}    // 0,
        nsec3_iterations => $nsec_config->{nsec3_iterations} // 7,
        nsec3_narrow     => $nsec_config->{nsec3_narrow}     // 1,
        nsec3_salt       => $nsec_config->{nsec3_salt}       // Cpanel::Rand::Get::getranddata( 16, [ 0 .. 9, 'a' .. 'f' ] ),
    };
    return $new_nsec_config;
}

sub generate_key_config_based_on_algo_num_and_key_type {
    my ( $self, $config ) = @_;

    foreach my $required_key (qw(algo_num key_type)) {
        die Cpanel::Exception::create( 'MissingParameter', 'Provide the “[_1]” argument.', [$required_key] )
          if !length $config->{$required_key};
    }
    die Cpanel::Exception::create( 'InvalidParameter', 'The “[_1]” parameter must be one of the following: [join,~, ,_2]', [ 'key_type', [ 'ksk', 'zsk' ] ] )
      if !( lc( $config->{'key_type'} ) eq 'ksk' || lc( $config->{'key_type'} ) eq 'zsk' );
    die Cpanel::Exception::create( 'InvalidParameter', '“[_1]” must be a positive integer.', ['key_size'] )
      if defined $config->{'key_size'} && !_is_postive_int( $config->{'key_size'} );

    if ( my $def_algo = _supported_algorithms()->{ $config->{'algo_num'} } ) {
        return {
            'tag'      => $def_algo->{'tag'},
            'algo_num' => $config->{'algo_num'},
            'key_type' => $config->{'key_type'},
            (
                lc( $config->{'key_type'} ) eq 'ksk'
                ? ( 'ksk_size' => $config->{'key_size'} // $def_algo->{'ksk_size'} )
                : ( 'zsk_size' => $config->{'key_size'} // $def_algo->{'zsk_size'} )
            ),
            'active' => defined $config->{'active'} ? $config->{'active'} : $def_algo->{'active'},
        };
    }

    die Cpanel::Exception::create( 'InvalidParameter', '“[_1]” is not a supported algorithm.', [ $config->{'algo_num'} ] );
}

sub _is_postive_int {
    return $_[0] =~ /\A[1-9][0-9]*\z/;
}

sub _supported_digests {
    return {
        '1' => 'SHA-1',
        '2' => 'SHA-256',
        '3' => 'GOST R 34.11-94',
        '4' => 'SHA-384',
    };
}

sub _supported_algorithms {
    return {
        '5' => {
            'desc'      => 'RSA/SHA-1',
            'tag'       => 'RSASHA1',
            'ksk_size'  => 2048,
            'zsk_size'  => 1024,
            'key_setup' => 'classic',
            'active'    => 1,
        },
        '6' => {
            'desc'      => 'DSA-NSEC3-SHA1',
            'tag'       => 'DSA-NSEC3-SHA1',
            'ksk_size'  => 2048,
            'zsk_size'  => 1024,
            'key_setup' => 'classic',
            'active'    => 1,
        },
        '7' => {
            'desc'      => 'RSASHA1-NSEC3-SHA1',
            'tag'       => 'RSASHA1-NSEC3-SHA1',
            'ksk_size'  => 2048,
            'zsk_size'  => 1024,
            'key_setup' => 'classic',
            'active'    => 1,
        },
        '8' => {
            'desc'      => 'RSA/SHA-256',
            'tag'       => 'RSASHA256',
            'ksk_size'  => 2048,
            'zsk_size'  => 1024,
            'key_setup' => 'classic',
            'active'    => 1,
        },
        '10' => {
            'desc'      => 'RSA/SHA-512',
            'tag'       => 'RSASHA512',
            'ksk_size'  => 2048,
            'zsk_size'  => 1024,
            'key_setup' => 'classic',
            'active'    => 1,
        },
        '13' => {
            'desc'      => 'ECDSA Curve P-256 with SHA-256',
            'tag'       => 'ECDSAP256SHA256',
            'ksk_size'  => 256,
            'zsk_size'  => 256,
            'key_setup' => 'simple',
            'active'    => 1,
        },
        '14' => {
            'desc'      => 'ECDSA Curve P-384 with SHA-384',
            'tag'       => 'ECDSAP384SHA384',
            'ksk_size'  => 384,
            'zsk_size'  => 384,
            'key_setup' => 'simple',
            'active'    => 1,
        }
    };
}

sub wsapi {
    return Cpanel::NameServer::Conf::PowerDNS::WebserverAPI->singleton();
}

sub _sync_key {
    my ( $action, $domain, $id ) = @_;

    return if !Cpanel::DnsUtils::Cluster::is_clustering_enabled();
    return if !$action || !$domain || !$id;

    my $key = wsapi()->get_key_by_id( $domain, $id );
    return if !$key->{keytag};

    require Cpanel::ServerTasks;
    require Cpanel::NameServer::DNSSEC::SyncKeys::Adder;
    require Cpanel::Rand::Get;
    Cpanel::NameServer::DNSSEC::SyncKeys::Adder->add( Cpanel::Rand::Get::getranddata(16), { 'domain' => $domain, 'action' => $action, 'keytag' => $key->{keytag} } );
    return Cpanel::ServerTasks::schedule_task( ['DNSAdminTasks'], 30, "synckeys" );
}

=back

=cut

sub rectify {
    my ( $self, $domain ) = @_;
    #
    # This was previously calling get_zone which was
    # just appending a '.' to the $domain.  This appears
    # to no longer be needed with the switch to the webserver api
    #
    my $recti_res = wsapi()->rectify_zone($domain);
    warn "Could not rectify zone for '$domain'!" unless ref($recti_res) eq 'HASH' && exists $recti_res->{result} && $recti_res->{result} eq 'Rectified';
    return $recti_res;
}

1;
