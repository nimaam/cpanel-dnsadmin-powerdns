package Cpanel::NameServer::Remote;

# cpanel - Cpanel/NameServer/Remote.pm             Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use cPstrict;

use Cpanel::NameServer::Constants ();

=encoding utf-8

=head1 NAME

Cpanel::NameServer::Remote - Parent Class to implement a Remote

=head1 SYNOPSIS

    use MyNameServer::Remote;

    use parent 'Cpanel::NameServer::Remote';

    ...


=head1 DESCRIPTION

This class should be used to implement some NameServer::Remote providers
and used as a base class.

=head1 FUNCTIONS

=cut

sub _check_action ( $self, $action, $should_queue = undef ) {

    my $calling_package = ( caller() )[0];

    if ( length $self->{'publicapi'}->{'error'} ) {
        my ( $error_type, $error_message, $is_recoverable_error ) = $self->determine_error_type( $self->{'publicapi'}->{'error'}, "$action on the remote server" );
        $self->queue_request($error_type)                                                 if ( $should_queue && $is_recoverable_error );
        return ( $error_type, "$calling_package: $error_message", $is_recoverable_error ) if $error_type != $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED;

        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "$calling_package: Unable to $action on the remote server [$self->{'name'}] ($self->{'publicapi'}->{'error'})", $is_recoverable_error );
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, "$calling_package: OK", 0 );
}

=head2 $self->output()

Returns the output from the 'output_callback' function.

=cut

sub output ( $self, @args ) {
    return $self->{'output_callback'}->(@args);
}

sub queue_request ( $self, $error_type ) {
    return $self->{'queue_callback'}->( $self->{'host'}, $error_type );
}

sub istimeout ( $self, $req ) {
    return ( $req =~ /Could not connect/ || $req =~ /No route to host/ || $req =~ /Network is unreachable/ || $req =~ /Unable to connect/ || $req =~ /Unable to resolve/ || $req =~ /Timed/i || $req =~ /Timeout/i || $req =~ /connection refused/i || $req =~ /NET OR SSL ERROR/ || $req =~ /Access Denied/ || ( $req =~ /Server Error/ && $req =~ m/HTTP\S+\s+5/ ) ) ? 1 : 0;
}

sub isaccessdenied ( $self, $req ) {
    if ( exists $self->{'publicapi'}->{'httpheader'} ) {
        return $self->{'publicapi'}->{'httpheader'} =~ m/HTTP\S+\s+40[1235]/ ? 1 : 0;
    }

    return ( $req =~ /Server Error/ && $req =~ m/HTTP\S+\s+40[1235]/ ) ? 1 : 0;
}

sub isinvalidresponse ( $self, $req ) {

    if ( exists $self->{'publicapi'}->{'httpheader'} ) {
        return ( $self->{'publicapi'}->{'httpheader'} =~ m/HTTP\S+\s+4/ && $self->{'publicapi'}->{'httpheader'} !~ m/HTTP\S+\s+40[12356]/ ) ? 1 : 0;
    }

    return ( $req =~ /Server Error/ && $req =~ m/HTTP\S+\s+4/ && $req !~ m/HTTP\S+\s+40[12356]/ ) ? 1 : 0;
}

=head2 $self->determine_error_type( $error_msg )

    Parse an error message and return a pre formated format and a boolean to indicate if the error is recoverable or not.

        my ( $error_type, $error_msg, $is_recoverable_error ) = $self->determine_error_type( $error_msg );

    error_type: The type of error as defined in Cpanel::NameServer::Constants
    error_msg : The error message
    is_recoverable_error: 1 or 0  (as defined by is_recoverable_error)

=cut

sub determine_error_type ( $self, $error_msg ) {

    if ( $self->istimeout($error_msg) ) {
        return ( $Cpanel::NameServer::Constants::ERROR_TIMEOUT_LOGGED, "Unable to $error_msg [$self->{'name'}] (Timeout while connecting: $self->{'publicapi'}->{error})", 1 );
    }
    elsif ( $self->isaccessdenied($error_msg) ) {
        return ( $Cpanel::NameServer::Constants::ERROR_AUTH_FAILED_LOGGED, "Unable to $error_msg [$self->{'name'}] (Authentication failure: $self->{'publicapi'}->{error})", 1 );
    }
    elsif ( $self->isinvalidresponse($error_msg) ) {
        return ( $Cpanel::NameServer::Constants::ERROR_INVALID_RESPONSE_LOGGED, "Unable to $error_msg [$self->{'name'}] (Authentication failure: $self->{'publicapi'}->{error})", 1 );
    }
    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Unable to $error_msg [$self->{'name'}] (Generic Error: $self->{'publicapi'}->{error})", 0 );
}

sub is_recoverable_error ($error_type) {

    return
         $error_type == $Cpanel::NameServer::Constants::ERROR_TIMEOUT_LOGGED
      || $error_type == $Cpanel::NameServer::Constants::ERROR_AUTH_FAILED_LOGGED
      || $error_type == $Cpanel::NameServer::Constants::ERROR_INVALID_RESPONSE_LOGGED
      || $error_type == $Cpanel::NameServer::Constants::ERROR_TIMEOUT ? 1 : 0;
}

=head2 $self->_strip_dnsuniqid( $data )

Returns a string where the dnsuniqid is removed.

Note: This uses a lot less memory then the previous version

=cut

sub _strip_dnsuniqid ( $self, $str ) {
    return $str =~ s/(?:^dnsuniqid=[^\&]+\&|\&dnsuniqid=[^\&]+)//gr;
}

sub cleanup {
    return;
}

1;
