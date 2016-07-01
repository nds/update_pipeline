package IRODS::Common;

# ABSTRACT: Common irods functionality

use Moose;


has 'bin_directory' => (isa => 'Str', is => 'rw', default => '');

__PACKAGE__->meta->make_immutable;

no Moose;

1;
