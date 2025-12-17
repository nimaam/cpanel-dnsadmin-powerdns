package Cpanel::NameServer::Conf::PowerDNS::WebserverAPI;

# cpanel - Cpanel/NameServer/Conf/PowerDNS/WebserverAPI.pm
#                                                  Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use cPstrict;

use Cpanel::JSON               ();
use Cpanel::Exception          ();
use Cpanel::HTTP::Client       ();
use Cpanel::Config::LoadConfig ();
use Cpanel::Encoder::URI       ();

our ( $config, $secure_zones );

use constant conf_file      => '/etc/pdns/pdns.conf';
use constant prefix         => '/api/v1/servers/localhost/';
use constant host           => 'http://127.0.0.1';
use constant retry_attempts => 3;

=head1 NAME

C<Cpanel::NameServer::Conf::PowerDNS::WebserverAPI>

=head1 DESCRIPTION

This module allows consumers to access the PowerDNS Webserver API methods to help manage DNSSEC.

=head1 SYNOPSIS

    my $api = Cpanel::NameServer::Conf::PowerDNS::WebserverAPI->singleton();
    my $zone_info = $api->get_zone($zone);

=head1 METHODS

=over

=item new()

=over 2

=item Arguments: none

=item Returns: Cpanel::NameServer::Conf::PowerDNS::WebserverAPI object with attributes:

=over 2

=item * C<config>: the configuration directives in /etc/pdns/pdns.conf

=item * C<url>: The base url of the webserver api entry.

=item * C<http>: The Cpanel::HTTP::Client object used to query the api.

=item * C<headers>: The HTTP headers to be included with each request.

Dies if certain configuration options are not found in /etc/pdns/pdns.conf

=back

=back

=back

=cut

sub new ($class) {

    my $self = bless {}, $class;
    $self->{config} = $config // _load_config();

    my @errors;
    if ( ( !$self->{config}{api} || $self->{config}{api} ne 'yes' ) && ( !$self->{config}{webserver} || $self->{config}{webserver} ne 'yes' ) ) {
        @errors = ( 'api', 'webserver' );
    }

    if ( !$self->{config}{'webserver-port'} || $self->{config}{'webserver-port'} !~ /^[0-9]+$/ ) {
        push( @errors, 'webserver-port' );
    }

    if ( !$self->{config}{'api-key'} ) {
        push( @errors, 'api-key' );
    }

    if (@errors) {
        require Cpanel::Locale;
        my $locale = Cpanel::Locale->get_handle();
        die $locale->maketext( "The following [asis,PowerDNS Webserver API] configuration options are missing or invalid: [list_and_quoted,_1]", \@errors );
    }

    $self->{url}     = host . ':' . $self->{config}{'webserver-port'} . prefix;
    $self->{http}    = Cpanel::HTTP::Client->new( timeout => 10 )->return_on_http_error();
    $self->{headers} = { 'X-API-Key' => $self->{config}{'api-key'}, 'Content-Type' => 'application/json' };

    $self->_test_connection();

    return $self;
}

my $_singleton;

=over

=item singleton()

This is a wrapper around new() that creates a singleton that can
be called by multiple callers to avoid the overhead of creating the
object in many places which currently results in multiple connection
tests.

=back

=cut

sub singleton ($class) {
    return $_singleton //= $class->new();
}

sub _load_config {
    $config = Cpanel::Config::LoadConfig::loadConfig( conf_file, undef, '=', undef, undef, undef, { 'nocache' => 1 } );
    return $config;
}

=over

=item list_secure_zones()

=over 2

=item Arguments: none

=item Returns: arrayref of zones that have DNSSEC enabled.

=back

=back

=cut

sub list_secure_zones ($self) {
    $secure_zones //= $self->run("list-secure-zones");
    return $secure_zones;
}

=over

=item list_keys()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to get the DNSSEC keys for.

=back

=item * Returns: arrayref of hashrefs with each hash containing a PowerDNS Cryptokey object with the following keys:

=over 2

=item * C<type>: string - The object type, always set to "Cryptokey"

=item * C<id>: int - The internal indentifier used by PowerDNS.

=item * C<keytype>: string - The type of key ( KSK, ZSK, CSK ).

=item * C<active>: boolean - Is the key currently active or not.

=item * C<dnskey>: string - The DNSKEY record for this key.

=item * C<ds>: string - An arrayref of DS records for this key.

=item * C<algorithm>: string - The name of the algorithm of the key, should be a mnemonic.

=item * C<bits>: int - The size of the key.

=item * C<keytag>: int - The keytag of the key.

=item * C<created>: int - The unix time of the creation of the key.

=back

=back

=back

=cut

sub list_keys ( $self, $zone ) {
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    my $keys = $self->run("zones/$zone/cryptokeys");

    # Turn the JSON booleans into something more perl friendly.
    map { $_->{active} = $_->{active} ? 1 : 0 } @{$keys} if ref $keys eq 'ARRAY';

    return $keys;
}

=over

=item get_zone()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to get information about.

=back

=item * Returns: hashref containing a PowerDNS Zone object.

See L<https://doc.powerdns.com/authoritative/http-api/zone.html#objects> for the avaliable data in this object.

=back

=back

=cut

sub get_zone ( $self, $zone ) {
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    return $self->run("zones/$zone");
}

=over

=item rectify_zone($zone)

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone to rectify

=back

=item * Returns: String describing operation status

See L<https://doc.powerdns.com/authoritative/http-api/zone.html#put--servers-server_id-zones-zone_id-rectify>.

=back

=back

=cut

sub rectify_zone ( $self, $zone ) {
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    return $self->run_nonfatal( "zones/$zone/rectify", 'PUT' );
}

=over

=item secure_zone( $zone )

=over 2

=item * Arguments

=over 2

=item * C<zone>: string - Zone to add key for

=back

=item * Returns: DNSSEC key object

See L<https://doc.powerdns.com/authoritative/http-api/cryptokey.html#post--servers-server_id-zones-zone_id-cryptokeys>

=back

=back

=cut

sub secure_zone ( $self, $zone, $key_params ) {
    $key_params->{active} = $key_params->{active} ? Cpanel::JSON::true() : Cpanel::JSON::false();

    # The api depends on this value being an integer.
    $key_params->{keytype} = lc( $key_params->{keytype} ) if $key_params->{keytype};
    $key_params->{bits}    = $key_params->{bits} + 0      if $key_params->{bits};
    $zone                  = Cpanel::Encoder::URI::uri_encode_str($zone);
    my $content = Cpanel::JSON::Dump($key_params);
    return $self->run_nonfatal( "zones/$zone/cryptokeys", "POST", $content );
}

=over

=item unsecure_zone( $zone )

=over 2

=item * Arguments

=over 2

=item * C<zone>: string - Zone to unsecure

=back

=item * Returns: dies on failure, 1 on success

=back

=back

=cut

sub unsecure_zone ( $self, $zone ) {
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    my $params  = { dnssec => Cpanel::JSON::false() };
    my $content = Cpanel::JSON::Dump($params);
    return $self->run( "zones/$zone", "PUT", $content );
}

=over

=item get_key_by_id()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to get keys for.

=item * C<id>: int - The PowerDNS ID of the DNSSEC key.

=back

=item * Returns: hashref containing a PowerDNS Cryptokey Object.

Has the same properties of the keys returned by list_keys() but has one additional value.

=over 2

=item * C<privatekey>: The private key data of the requested DNSSEC key.

=back

=back

=back

=cut

sub get_key_by_id ( $self, $zone, $id ) {
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    $id   = Cpanel::Encoder::URI::uri_encode_str($id);
    return $self->run("zones/$zone/cryptokeys/$id");
}

=over

=item import_key()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to get keys for.

=item * C<type>: string - The type of key ( KSK, ZSK, CSK ).

=item * C<key>: string - The plaintext private key.

=item * C<active>: bool - Should this key be activated on import or not. Default: true.

=back

=item * Returns: hashref containing a PowerDNS Cryptokey Object of the key that was added.

Has the same properties of the keys returned by list_keys() but has one additional value.

=over 2

=item * C<privatekey>: The private key data of the imported DNSSEC key.

=back

=back

=back

=cut

sub import_key ( $self, $zone, $type, $key, $active = 1 ) {
    $type = 'csk' if $type !~ /[ckz]sk/i;
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    my $content = {
        keytype    => lc($type),                                                # The api only accepts lowercase key types.
        privatekey => $key,
        active     => $active ? Cpanel::JSON::true() : Cpanel::JSON::false(),
    };
    return $self->run_nonfatal( "zones/$zone/cryptokeys", 'POST', Cpanel::JSON::Dump($content) );

}

=over

=item get_meta()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to get metadata for.

=back

=item * Returns: hashref containing the metadata for the zone.

=back

=back

=cut

sub get_meta ( $self, $zone ) {
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    my $raw_meta = $self->run("zones/$zone/metadata");
    my %metadata = map { $_->{kind} => $_->{metadata}[0] } @$raw_meta;
    return \%metadata;
}

=over

=item set_nsec3()

Also use this to unset nsec 3 by passing proper parameters

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to get metadata for.

=item * C<config>: string - The nsec3 config string.

=item * C<set>: boolean - Set to 0 when you want to unset nsec3

=back

=item * Returns: 1 on success, dies on failure.

=back

=back

=cut

sub set_nsec3 ( $self, $zone, $config, $set = 1 ) {
    $zone = Cpanel::Encoder::URI::uri_encode_str($zone);
    my $content = {
        'nsec3param'  => $set ? $config              : '',                      # the empty string here will unset NSEC3 and revert the zone to NSEC.
        'nsec3narrow' => $set ? Cpanel::JSON::true() : Cpanel::JSON::false(),
    };
    return $self->run( "zones/$zone", 'PUT', Cpanel::JSON::Dump($content) );
}

=over

=item remove_zone_key()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to remove from.

=item * C<keyid>: string - The PowerDNS id of the key.

=back

=item * Returns: 1 on success, dies on failure.

=back

=back

=cut

sub remove_zone_key ( $self, $zone, $keyid ) {
    $zone  = Cpanel::Encoder::URI::uri_encode_str($zone);
    $keyid = Cpanel::Encoder::URI::uri_encode_str($keyid);
    return $self->run( "zones/$zone/cryptokeys/$keyid", 'DELETE' );
}

=over

=item activate_zone_key()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to activate on.

=item * C<keyid>: string - The PowerDNS id of the key.

=back

=item * Returns: 1 on success, dies on failure.

=back

=back

=cut

sub activate_zone_key ( $self, $zone, $keyid ) {
    return $self->_call_zone_key( $zone, $keyid, 1 );
}

=over

=item deactivate_zone_key()

=over 2

=item * Arguments:

=over 2

=item * C<zone>: string - The zone we want to deactivate on.

=item * C<keyid>: string - The PowerDNS id of the key.

=back

=item * Returns: 1 on success, dies on failure.

=back

=back

=cut

sub deactivate_zone_key ( $self, $zone, $keyid ) {
    return $self->_call_zone_key( $zone, $keyid, 0 );
}

sub _call_zone_key ( $self, $zone, $keyid, $active ) {
    $zone  = Cpanel::Encoder::URI::uri_encode_str($zone);
    $keyid = Cpanel::Encoder::URI::uri_encode_str($keyid);
    my $content = { active => $active ? Cpanel::JSON::true() : Cpanel::JSON::false() };
    return $self->run( "zones/$zone/cryptokeys/$keyid", 'PUT', Cpanel::JSON::Dump($content) );
}

=over

=item run()

=over 2

=item * Arguments:

=over 2

=item * C<path>: string - The path to the desired api endpoint.

=item * C<method>: string - The HTTP method to use. Default: GET

=item * C<content>: string - The data to be passed as the body content. This must be JSON encoded. Default is an empty string.

=back

=item * Returns: hashref of the returned api request. returns 1 if there is no content.

=back

=back

=cut

sub run ( $self, $path, $method = 'GET', $content = '' ) {
    local $@;
    my $resp_obj;

    # Note: we do not use die_on_http_error here since we can potentially have lots
    # of errors and we don't want the overhead of exceptions since it was ~40% of the execution time > 100s
    # with this test:
    #
    # perl -e 'open(my $fh,"<","/etc/remotedomains"); system("whmapi1","--nytprof","set_nsec3_for_domains","nsec3_salt=1","nsec3_narrow=1","nsec3_iterations=1","nsec3_opt_out=0",map { chomp; "domain=$_" } <$fh>);'
    #
    for ( 1 .. retry_attempts ) {
        $resp_obj = eval { $self->{http}->request( $method, $self->{url} . $path, { 'headers' => $self->{headers}, 'content' => $content } ) };
        my $err = $@;
        if ( $err && ref $err && $err->isa('Cpanel::Exception::HTTP::Network') ) {
            next;    # retry on network error
        }

        my $code = $resp_obj->status();
        if ( $code == 505 || ( $code >= 400 && $code < 500 ) ) {

            #Fail right away on 4XX and 505 codes as these will never
            #get better on a retry
            _throw_http_error($resp_obj);
        }
        elsif ( $code < 400 ) {
            if ( $resp_obj->content() ) {
                return Cpanel::JSON::Load( $resp_obj->content() );
            }
            elsif ( $resp_obj->success() ) {
                return 1;
            }
        }
    }

    # We failed, die with the last error.
    # die without $@ will rethrow
    die if $@;

    return _throw_http_error( $resp_obj, $method );
}

sub _throw_http_error {
    my ( $resp_obj, $method ) = @_;
    my $suppress = Cpanel::Exception::get_stack_trace_suppressor();
    die Cpanel::Exception::create(
        'HTTP::Server',
        [
            method       => $method,
            content_type => scalar( $resp_obj->header('Content-Type') ),
            ( map { ( $_ => $resp_obj->$_() ) } qw( content status reason url headers redirects ) ),
        ],
    );
}

sub run_nonfatal ( $self, $path, $method = "GET", $content = '' ) {
    my ( $return, $code, $last_exception );
    for ( 1 .. retry_attempts ) {
        local $@;

        # we can still get internal error 599 on socket error so we have to trap here
        # See Cpanel::HTTP::Client::request (this is ok to retry)
        $return         = eval { $self->{http}->request( $method, $self->{url} . $path, { 'headers' => $self->{headers}, 'content' => $content } ) };
        $last_exception = $@;
        if ( $last_exception && ref $last_exception && $last_exception->isa('Cpanel::Exception::HTTP::Network') ) {
            next;    # retry on network error
        }

        $code = $return->status();

        #Re-try on all errors except those we know will never ever work, like 4XX codes and 505
        last if $code < 500 || $code == 505;
    }
    if ( !$return ) {
        return { http_return_code => 599, error => Cpanel::Exception::get_string($last_exception) };
    }
    elsif ( $return->success() ) {
        local $@;
        my $ret = eval { Cpanel::JSON::Load( $return->content() ) };
        if ($@) {    # invalid json
            return { http_return_code => $code, error => Cpanel::Exception::get_string($@) };
        }
        $ret->{http_return_code} = $code;
        return $ret;
    }
    return { error => join( " ", $return->reason() // '', $return->content() // '' ), http_return_code => $code };
}

sub _test_connection ($self) {

    local $@;
    for ( 1 .. retry_attempts ) {
        eval { $self->{http}->get( host . ":$self->{config}{'webserver-port'}/api/v1/servers", { 'headers' => $self->{headers} } ) };
        return 1 if !$@;
    }
    die "Failed to contact the PowerDNS Webserver API: $@";
}

1;
