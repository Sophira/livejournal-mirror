# LJ/OpenSocial/Enum/Gender.pm - jop

package LJ::OpenSocial::Enum::Gender;

use strict;

our $FEMALE = 0;
our $MALE = 1;

our @EXPORT_OK = qw ( $FEMALE $MALE );

#####

sub lookup {
  my $p_tag = shift;
  return "FEMALE" if $p_tag == $FEMALE;
  return "MALE" if $p_tag == $MALE;
  return "UNDEFINED";
}

#####

1;

# End of file.
