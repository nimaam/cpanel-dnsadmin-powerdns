package Cpanel::NameServer::DNSSEC::SyncKeys;

# cpanel - Cpanel/NameServer/DNSSEC/SyncKeys.pm    Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Cpanel::DNSSEC::Available                        ();
use Cpanel::NameServer::Utils::PowerDNS              ();
use Cpanel::SafeDir::MK                              ();
use Cpanel::Debug                                    ();
use Cpanel::ServerTasks                              ();
use Cpanel::NameServer::Conf::PowerDNS::WebserverAPI ();

=head1 NAME

Cpanel::NameServer::DNSSEC::SyncKeys

=head1 DESCRIPTION

This modules purpose is to facilitate DNSSEC key clustering. It is meant to be used and consumed by DnsAdmin.

=head1 SYNOPSIS

    my $keysync = Cpanel::NameServer::DNSSEC::SyncKeys->new('example.test');
    $keysync->sync_active_keys();

=head1 METHODS

=over

=item new()

=over 2

=item Arguments:

=over 2

=item * C<$zone> : string - The zone we want to sync keys.

=item * C<$local> : bool - Optional, Default: False.
Tell DnsAdmin to perform the action on the local server in addition to the remote servers.

=back

=item Returns: Cpanel::NameServer::DNSSEC::SyncKeys object with attributes:

=over 2

=item * C<zone>: The zone we are using.

=item * C<keyinfo>: A hash ref of the current DNSSEC keys for the zone.

=item * C<tmpdir>: The temp directory used when importing keys.

Dies if clustering is not enabled, the current nameserver is not PowerDNS, or no zone is passed in.

=back

=back

=back

=cut

sub new {
    my ( $class, $zone, $local ) = @_;

    die 'The system lacks DNSSEC support.' if !Cpanel::DNSSEC::Available::dnssec_is_available();

    my $self = bless {}, $class;

    $self->{zone}    = $zone // die 'A zone is needed as an argument.';
    $self->{api}     = Cpanel::NameServer::Conf::PowerDNS::WebserverAPI->singleton();
    $self->{keyinfo} = $self->get_key_info();

    $self->{tmpdir} = '/var/cpanel/cluster';
    Cpanel::SafeDir::MK::safemkdir( $self->{tmpdir}, 0700 );

    # 0 means remote and local.
    # 2 means remote only.
    # These are defined by DnsAdmin
    $self->{local} = $local ? 0 : 2;

    return $self;
}

=over

=item get_key_info()

=over 2

=item Arguments:

none

=item Returns: hashref of the current keys for a zone.

=over 2

The hash keys are the keytags.

Values:

=over 2

=item * C<id>: array ref of ids

=item * C<type>: string of the key type

=item * C<active>: boolean of the activity of the key.

=back

This is called in the constructor and is avaliable as the keyinfo attribute.

=back

=back

=back

=cut

sub get_key_info {
    my ($self) = @_;

    my $api_output = $self->{api}->list_keys( $self->{zone} );
    return {} if !$api_output;

    my $all_keys = {};
    foreach my $key ( @{$api_output} ) {
        my $keytag = $key->{keytag};
        push( @{ $all_keys->{$keytag}{ids} }, $key->{id} );
        $all_keys->{$keytag}{type}       = uc( $key->{keytype} );
        $all_keys->{$keytag}{active}     = $all_keys->{$keytag}{active} ? 1 : $key->{active} ? 1 : 0;
        $all_keys->{$keytag}{privatekey} = $key->{privatekey};

    }

    return $all_keys;
}

=over

=item get_nsec3_config()

=over 2

=item * Arguments:

none

=item * Returns: string containing the nsec3 config or 0

The nsec3 config is gathered from the zones PowerDNS metadata.

=back

=back

=cut

sub get_nsec3_config {
    my ($self) = @_;

    my $meta = eval { $self->{api}->get_meta( $self->{zone} ) };
    return $meta->{NSEC3PARAM} ? $meta->{NSEC3PARAM} : 0;
}

=over

=item sync_active_keys()

=over 2

=item * Arguments:

=item * C<args>: hashref of additional optional arguments that can be the following

=over 2

=item * C<skip_verify>: If true, will skip the verification of the dnssec keys.

=back

=item * Returns: hashref of keys that is passed to DnsAdmin for consumption.

Sync's all active keys for a zone.

=back

=back

=cut

sub sync_active_keys {
    my ( $self, $args ) = @_;
    return $self->sync_keys( $self->get_active_keytags(), $args );
}

=over

=item get_active_keydata()

=over 2

=item * Arguments:

 none

=item * Returns a hashref of keydata for the currently active keys in a zone.

=back

=back

=cut

sub get_active_keydata {
    my ($self) = @_;
    return { map { $_ => $self->get_keydata($_) } @{ $self->get_active_keytags() } };
}

=over

=item get_active_keytags()

=over 2

=item * Arguments:

 none

=item * Returns an arrayref of the currently active keytags for a zone.

=back

=back

=cut

sub get_active_keytags {
    my ($self) = @_;
    return [ grep { $self->{keyinfo}->{$_}{active} } keys %{ $self->{keyinfo} } ];
}

=over

=item get_keydata()

=over 2

=item * Arguments:

 tag - The keytag of the private key that we want.

=item * Returns the private key as a string or zero if pdnsutil fails or the tag does not exist.

 The key is prefixed with a comment to specifiy the type of key ( KSK, ZSK, CSK ).

=back

=back

=cut

sub get_keydata {
    my ( $self, $tag ) = @_;

    return 0 unless $self->{keyinfo}->{$tag} && $self->{keyinfo}->{$tag}{type} && $self->{keyinfo}->{$tag}{privatekey};
    return ";$self->{keyinfo}->{$tag}{type}\n" . $self->{keyinfo}->{$tag}{privatekey};
}

=over

=item sync_keys()

=over 2

=item * Arguments:

=over 2

=item * C<keytags>: arrayref of DNSSEC keytags.

=item * C<args>: hashref of additional optional arguments that can be the following

=over 2

=item * C<skip_verify>: If true, will skip the verification of the dnssec keys.

=back

=back

=item * Returns a boolean value based on if dnsadmin was able to process the data. Returns 0 if there was no action to take.

=back

=back

=cut

sub sync_keys {
    my ( $self, $keytags, $args ) = @_;

    $args //= {};
    my $data = {};

    foreach my $tag ( @{$keytags} ) {
        if ( !$self->{keyinfo}->{$tag} ) {
            Cpanel::Debug::log_warn("Requested keytag $tag does not exist for zone $self->{zone}!");
            next;
        }
        $data->{$tag} = $self->get_keydata($tag);
    }

    return 0 if !keys %$data;

    $data->{zone} = $self->{zone};
    $data->{nsec} = $self->get_nsec3_config();

    if ( !$args->{skip_verify} ) {
        require Cpanel::DNSSEC::VerifyQueue::Adder;
        Cpanel::DNSSEC::VerifyQueue::Adder->add( $self->{zone} );
        Cpanel::ServerTasks::schedule_task( ['DNSTasks'], 900, "verify_dnssec_sync" );
    }

    return $self->_send_to_dnsadmin( 'SYNCKEYS', $data );
}

=over

=item revoke_keys()

=over 2

=item * Arguments:

=over 2

=item * C<keytags>: arrayref of DNSSEC keytags

=back

=item * Returns a boolean value based on if dnsadmin was able to process the data.

=back

=back

=cut

sub revoke_keys {
    my ( $self, $keytags ) = @_;

    my $data = {};
    %$data = map { $_ => 1 } @$keytags;
    $data->{zone} = $self->{zone};

    return $self->_send_to_dnsadmin( 'REVOKEKEYS', $data );

}

=over

=item set_meta()

=over 2

=item * Arguments:

=over 2

=item * C<meta>: hashref to be converted into key=>value PowerDNS metadata.

=back

=item * Returns 0 if no metadata is passed in, or at least one pdnsutil run failed. Returns 1 on success.

=back

=back

=cut

sub set_meta {
    my ( $self, $meta ) = @_;

    return 0 if ref $meta ne 'HASH' || !keys(%$meta);

    my $failed = 0;

    foreach my $key ( keys %$meta ) {
        my $ret = Cpanel::NameServer::Utils::PowerDNS::run_pdnsutil( { 'args' => [ 'set-meta', '--', $self->{zone}, $key, $meta->{$key} ] } );
        $failed = 1 if !$ret->{success};
    }

    return $failed ? 0 : 1;

}

=over

=item activate_keys()

=over 2

=item * Arguments:

=over 2

=item * C<keydata>: hashref of keydata obtained from DnsAdmin.

=back

=item * Returns 1 if no errors are encountered when adding keys, otherwise 0.

This is specifically used by DnsAdmin to activate keys it receives in SYNCKEYS actions.

=back

=back

=cut

sub activate_keys {
    my ( $self, $keydata ) = @_;

    return 0 if ref $keydata ne 'HASH' || !keys(%$keydata);

    my $keys_activated = 0;

  ACTIVATE: foreach my $key ( keys %$keydata ) {
        next if $key =~ tr{0-9}{}c;

        foreach my $existing ( keys %{ $self->{keyinfo} } ) {
            if ( $key == $existing ) {
                if ( !$self->{keyinfo}{$existing}{active} ) {
                    my $ret = eval { $self->{api}->activate_zone_key( $self->{zone}, @{ $self->{keyinfo}{$existing}{ids} }[0] ) };
                    $ret ? $keys_activated = 1 : return 0;
                }
                next ACTIVATE;
            }
        }

        my $type = $keydata->{$key}{type} =~ /[CK]SK/ ? 'ksk' : 'zsk';

        {
            local $@;
            my $key_added = eval { $self->{api}->import_key( $self->{zone}, lc($type), $keydata->{$key}{data} ); };
            return 0 if $@ || ( $key_added->{keytag} && $key_added->{keytag} != $key );
            $keys_activated = 1;
        }
    }

    if ($keys_activated) {

        require Cpanel::NameServer::DNSSEC::Cache;
        Cpanel::NameServer::DNSSEC::Cache::enable( $self->{zone} );

        my $meta = eval { $self->{api}->get_meta( $self->{zone} ) };
        if ( $keydata->{nsec} ) {
            if ( !$meta->{NSEC3PARAM} || ( $meta->{NSEC3PARAM} ne $keydata->{nsec} ) ) {
                local $@;
                eval { $self->{api}->set_nsec3( $self->{zone}, $keydata->{nsec} ) };
                return 0 if $@;
            }
        }
        elsif ( !$meta->{NSEC3PARAM} ) {
            require Cpanel::NameServer::Conf::PowerDNS;
            my $defaults  = Cpanel::NameServer::Conf::PowerDNS::nsec_config_defaults();
            my $nsec_conf = "$defaults->{use_nsec3} $defaults->{nsec3_opt_out} $defaults->{nsec3_iterations} $defaults->{nsec3_salt}";
            local $@;
            eval { $self->{api}->set_nsec3( $self->{zone}, $nsec_conf ) };
            return 0 if $@;
        }

        $self->{api}->rectify_zone( $self->{zone} );
        Cpanel::NameServer::Utils::PowerDNS::run_pdns_control( { 'args' => [ 'purge', '--', $self->{zone} ] } );

    }

    return 1;
}

=over

=item delete_keys()

=over 2

=item * Arguments:

=over 2

=item * C<keys>: hashref of keytags to be deleted.

=back

=item * Returns 0 if nothing is passed in, otherwise 1.

This is specifically used by DnsAdmin to delete keys it receives in REVOKEKEYS actions.

=back

=back

=cut

sub delete_keys {
    my ( $self, $keys ) = @_;

    return 0 if ref $keys ne 'HASH' || !keys(%$keys);

    foreach my $tag ( keys %{$keys} ) {
        eval { $self->{api}->remove_zone_key( $self->{zone}, $_ ) foreach @{ $self->{keyinfo}->{$tag}{ids} } };
    }

    return 1;
}

sub _send_to_dnsadmin {
    my ( $self, $action, $dataref ) = @_;
    require Cpanel::DnsUtils::AskDnsAdmin;
    return 0 unless Cpanel::DnsUtils::AskDnsAdmin->can('askdnsadmin');
    {
        local $@;
        eval { Cpanel::DnsUtils::AskDnsAdmin::askdnsadmin( $action, $self->{local}, '', '', '', $dataref ) };
        if ($@) {
            Cpanel::Debug::log_warn("DnsAdmin failed to $action for $self->{zone}: $@");
            return 0;
        }
    }

    return 1;
}

1;
