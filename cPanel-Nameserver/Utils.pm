package Cpanel::NameServer::Utils;

# cpanel - Cpanel/NameServer/Utils.pm              Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use cPstrict;

=encoding utf-8

=head1 NAME

Cpanel::NameServer::Utils

=head1 SYNOPSIS

    my $serial = Cpanel::NameServer::Utils::getserialnum( $zone_text );

… or, if your zone text is URI-encoded:

    my $serial = Cpanel::NameServer::Utils::get_encoded_serialnum( $uri_zone_text );

For getting a zone’s cPanel update time:

    my $mtime = Cpanel::NameServer::Utils::getupdatetime($zone_text);

    my $mtime = Cpanel::NameServer::Utils::get_encoded_updatetime( $uri_zone_text );

=head1 DESCRIPTION

This module implements some basic tooling for dnsadmin to parse
relevant information from DNS zones.

=cut

#----------------------------------------------------------------------

=head1 FUNCTIONS

=head2 $serial = getserialnum( $ZONE_TEXT )

Returns the serial number from the SOA record in $ZONE_TEXT.
If no such record is found, a warning is thrown, and (for legacy reasons)
0 is returned.

If $ZONE_TEXT is invalid as a zone file, an exception is thrown.

=cut

sub getserialnum {
    my ( $zone_text, $quiet ) = @_;

    local ( $@, $! );
    require Cpanel::ZoneFile::Query;

    # The zone file could be quite large. Let’s look in just the first
    # 1 KiB first since it’s likely that that’ll have our SOA record.
    # Note that we may get a parse error this first time since we’re
    # not taking care to break the zone file at a proper boundary,
    # but we don’t really care about that error since we’ll just repeat
    # with the whole file.

    my $soa_rr;

    eval {
        $soa_rr = Cpanel::ZoneFile::Query::first_of_type(
            substr( $zone_text, 0, 1024 ),
            '.', 'SOA',
        );
    };

    eval { $soa_rr ||= Cpanel::ZoneFile::Query::first_of_type( $zone_text, '.', 'SOA' ); };

    if ( !$soa_rr ) {
        warn "No SOA record found in zone:\n$zone_text\n" unless $quiet;

        # Preserve legacy behavior:
        return 0;
    }

    return _get_serial_from_soa_rr($soa_rr);
}

=head2 $serial = get_encoded_serialnum( $URI_ZONE_TEXT )

Like C<getserialnum()> but takes a URI-encoded zone file.

=cut

sub get_encoded_serialnum {    ## no critic qw(Unpack)
    local ( $@, $! );
    require Cpanel::Encoder::URI;
    require Cpanel::ZoneFile::Query;

    # We try the same optimization as with getserialnum(): first parse
    # just the first piece, then the whole file.
    my $decoded = Cpanel::Encoder::URI::uri_decode_str(
        substr( $_[0], 0, 1024 ),
    );

    my $soa_rr;

    eval { $soa_rr = Cpanel::ZoneFile::Query::first_of_type( $decoded, '.', 'SOA' ); };

    if ( !$soa_rr ) {
        $decoded = Cpanel::Encoder::URI::uri_decode_str( $_[0] );
        eval { $soa_rr = Cpanel::ZoneFile::Query::first_of_type( $decoded, '.', 'SOA' ); };
    }

    if ( !$soa_rr ) {
        warn "No SOA record found in zone:\n$_[0]\n";

        # Preserve legacy behavior:
        return 0;
    }

    return _get_serial_from_soa_rr($soa_rr);
}

=head2 $mtime = getupdatetime( $ZONE_TEXT )

Retrieves the cPanel update time from $ZONE_TEXT, or 0 if no such
update time exists.

See L<Cpanel::ZoneFile::Versioning> for more about this convention.

=cut

sub getupdatetime {
    return ( $_[0] =~ /\(update_time\):([0-9]+)/ ? $1 : 0 );    #update time
}

=head2 $mtime = get_encoded_updatetime( $URI_ZONE_TEXT )

Like C<getupdatetime()> but takes a URI-encoded zone file.

=cut

sub get_encoded_updatetime {
    return ( $_[0] =~ /%20%28update_time%29%3[Aa]([0-9]+)/ ? $1 : 0 );    #update time
}

sub _get_serial_from_soa_rr ($rr) {

    # The serial # is the 3rd piece of rdata in an SOA record:
    return $rr->rdata(2)->to_string();
}

1;
