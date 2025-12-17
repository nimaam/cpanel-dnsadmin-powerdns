package Cpanel::NameServer::Local;

# cpanel - Cpanel/NameServer/Local.pm              Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

sub output {
    return $_[0]->{'output_callback'}->( @_[ 1 .. $#_ ] );
}

sub cleanup { }

1;
