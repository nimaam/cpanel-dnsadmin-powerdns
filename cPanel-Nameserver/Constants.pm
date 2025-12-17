package Cpanel::NameServer::Constants;

# cpanel - Cpanel/NameServer/Constants.pm          Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

our $ERROR_UNKNOWN = -7;

our $ERROR_NO_PERMISSION           = -6;    # case 47900: FIXME: no module currently implements this, and dnsadmin does not react to it
                                            # The provider did not have permission to modify the dns zone or update the record
                                            # Currently  Softlayer.pm gets a 500 internal error if you do not have permission to edit a domain
                                            # this is no way to determine that is the proble however due the to limitations of their api
our $ERROR_INVALID_RESPONSE_LOGGED = -5;    # AKA could not understand the response from the providere
our $ERROR_AUTH_FAILED_LOGGED      = -4;    # AKA bad password
our $ERROR_GENERIC                 = -3;
our $ERROR_TIMEOUT                 = -2;
our $ERROR_GENERIC_LOGGED          = -1;
our $ERROR_TIMEOUT_LOGGED          = 0;
our $SUCCESS                       = 1;
our $QUEUE                         = 1;
our $DO_NOT_QUEUE                  = 0;

our $CHECK_ACTION_POSITION_STATUS               = 0;
our $CHECK_ACTION_POSITION_STATUS_MESSAGE       = 1;
our $CHECK_ACTION_POSITION_IS_RECOVERABLE_ERROR = 2;

1;
