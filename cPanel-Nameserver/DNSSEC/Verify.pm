package Cpanel::NameServer::DNSSEC::Verify;

# cpanel - Cpanel/NameServer/DNSSEC/Verify.pm      Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Net::DNS::Resolver          ();
use Net::DNS::Resolver::Recurse ();
use Cpanel::Locale              ();

=head1 NAME

C<Cpanel::NameServer::DNSSEC::Verify>

=head1 DESCRIPTION

This module can query a single nameserver for a zone and check if DNSSEC
records are served and if its DS record is valid.

 $verify = Cpanel::NameServer::DNSSEC::Verify->new( nameserver => '1.2.3.4' );
 $results = $verify->check_dnssec($zone);
 $problems = $verify->get_problems($zone);

 $verify->nameserver('4.3.2.1');
 $results = $verify->check_dnssec($zone);
 $problems = $verify->get_problems($zone);

=cut

my %resolver_opts = ( retry => 2, dnssec => 1, tcp_timeout => 5, udp_timeout => 5, adflag => 1 );

sub new {
    my ( $class, %opts ) = @_;

    die 'Specify a nameserver to query.' if !$opts{nameserver};

    my $self = {};
    $self->{resolver} = Net::DNS::Resolver->new(%resolver_opts);
    $self->{resolver}->recurse(0);
    $self->{resolver}->nameservers( $opts{nameserver} );
    $self->{locale}   = Cpanel::Locale->get_handle();
    $self->{problems} = [];
    return bless $self, $class;
}

=head1 METHODS

=over

=item check_dnssec()

Performs a DNS query for the specified zone to check if DNSSEC is setup.

It first looks for a DNSKEY record. Checks that the returned record is part of a
RRSIG and grabs the keytag of the key used to create the record.

The DS record is then obtained and verified against the DNSKEY.

NSEC and NSEC3 records are also requested to check if they are setup.

=over 2

=item * Arguments:

=over 2

=item * C<$zone>: string - The zone to be checked.

=back

=item * Returns:

A hash ref is returned with the following keys:

=over 2

=item * C<dnskey>: The dnskey record or 0.

=item * C<rrsig>: The rrsig record or 0.

=item * C<keytag>: The keytag of the rrsig record or 0.

=item * C<nsec>: The nsec record or 0.

=item * C<nsec3>: The nsec3 record or 0.

=back

=back

=back

=cut

sub check_dnssec {
    my ( $self, $zone ) = @_;

    my $results = {};

    my $dnskey_packet = $self->send_query( $zone, 'DNSKEY' );
    $results->{dnskey} = _get_record( $dnskey_packet, 'DNSKEY' );
    $results->{rrsig}  = _get_record( $dnskey_packet, 'RRSIG' );
    $results->{keytag} = _get_keytag($dnskey_packet);

    my $nsec_packet = $self->send_query( $zone, 'NSEC' );
    $results->{nsec} = _get_record( $nsec_packet, 'NSEC' );

    my $nsec3_packet = $self->send_query( $zone, 'NSEC3' );
    $results->{nsec3} = _get_record( $nsec3_packet, 'NSEC3' );

    return $results;
}

=over

=item get_problems()

Returns any problems found when remotely checking dnssec for a zone.

=over 2

=item * Arguments:

=over 2

=item * C<$zone>: string - The zone to be checked.

=back

=item * Returns:

An array ref containing any problems found.

=back

=cut

sub get_problems {
    my ( $self, $zone ) = @_;

    my $results = $self->check_dnssec($zone);

    my @problems = @{ $self->{problems} };
    $self->{problems} = [];    # Clear problems out once we consume them.

    push( @problems, ( map { $self->{locale}->maketext( "The system failed to find a “[_1]” record for “[_2]”.", $_, $zone ) } grep { !$results->{$_} } grep { !m/(nsec|verified|failure)/ } keys %$results ) );

    return \@problems;

}

=item verify_ds()

Verifies the DS record against the DNSKEY record.

=over 2

=item * Arguments:

=over 2

=item * C<$zone>: string - The zone to be checked.

=item * C<$dnskey>: Net::DNS::RR::DNSKEY object - optional

=item * C<$ds>: Net::DNS::RR::DS object - optional

=back

=item * Returns:

True or false if the record was verified.

=back

=cut

sub verify_ds {
    my ( $self, $zone, $dnskey, $ds ) = @_;

    return 0 if !$zone;

    $ds     //= $self->get_ds_packet($zone);
    $dnskey //= $self->send_query( $zone, 'DNSKEY' );

    return 0 if !$ds || !$dnskey;

    foreach my $answer ( $dnskey->answer() ) {
        if ( $answer->type() eq 'DNSKEY' ) {
            $ds->verify($answer) ? return 1 : next;
        }
    }

    return 0;
}

=item get_ds_records()

Gets the DS records from a DS packet.

=over 2

=item * Arguments:

=over 2

=item * C<$zone>: string - The zone to be checked.

=back

=item * Returns:

Array of DS records as strings.

=back

=cut

sub get_ds_records {
    my ( $self, $zone ) = @_;

    my $ds = $self->get_ds_packet($zone) || return ();
    return ( map { $_->string() } grep { $_->type() eq 'DS' } $ds->answer() );
}

=item get_ds_packet()

Obtains the requested DS packet if it exists.

=over 2

=item * Arguments:

=over 2

=item * C<$zone>: string - The zone to be checked.

=back

=item * Returns:

A Net::DNS::RR::DS object, or 0.

Dies if the query times out.

=back

=cut

sub get_ds_packet {
    my ( $self, $zone ) = @_;

    return 0 if !$zone;

    # obtaining the DS record needs to be a recursive
    # query. We can't directly query the cluster member
    # for it.

    $self->{recursor} //= Net::DNS::Resolver::Recurse->new(%resolver_opts);
    my $ds = $self->{recursor}->send( $zone, 'DS' );
    if ( $self->{recursor}->errorstring && $self->{recursor}->errorstring !~ /NOERROR/ ) {
        push( @{ $self->{problems} }, $self->{locale}->maketext( "An error occurred when the system requested the “DS” record for “[_1]”: “[_2]”.", $zone, $self->{recursor}->errorstring ) );
        return 0;
    }
    return $ds if $ds && grep { $_->type() eq 'DS' } $ds->answer();
    return 0;
}

=item send_query()

Request a DNS record from the nameserver.

=over 2

=item * Arguments:

=over 2

=item * C<$zone>: string - The zone to query.

=item * C<$record> : string - The desired DNS record.

=back

=item * Returns:

A Net::DNS packet object corresponding to the requested record, or zero on failure.

Dies if the Net::DNS::Resolver errorstring is set.

=back

=back

=cut

sub send_query {
    my ( $self, $zone, $record ) = @_;
    my $answer = $self->{resolver}->send( $zone, $record );
    if ( $self->{resolver}->errorstring && $self->{resolver}->errorstring !~ /NOERROR/ ) {
        push( @{ $self->{problems} }, $self->{locale}->maketext( "An error occurred when the system requested the “[_1]” record for “[_2]”: “[_3]”.", $record, $zone, $self->{resolver}->errorstring ) );
        return 0;
    }
    return $answer ? $answer : 0;

}

sub _get_record {
    my ( $dns_packet, $record ) = @_;

    return 0 if !$dns_packet || !$record;

    $record = uc($record);

    foreach my $answer ( $dns_packet->answer(), $dns_packet->authority() ) {
        if ( $answer->type() eq $record ) {
            return $answer->string();
        }
    }
    return 0;
}

sub _get_keytag {
    my ($dns_packet) = @_;

    return 0 if !$dns_packet;

    foreach my $answer ( $dns_packet->answer() ) {
        if ( $answer->type() eq 'RRSIG' ) {
            return $answer->keytag();
        }
    }
    return 0;
}

1;
