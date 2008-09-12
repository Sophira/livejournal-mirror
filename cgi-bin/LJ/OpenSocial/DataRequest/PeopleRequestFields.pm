# LJ/OpenSocial/DataRequest/PeopleRequestFields.pm - jop

package LJ::OpenSocial::DataRequest::PeopleRequestFields;
use LJ::OpenSocial::Util::FieldBase;
our @ISA = ( LJ::OpenSocial::Util::FieldBase );
*AUTOLOAD = \&LJ::OpenSocial::Util::FieldBase::AUTOLOAD;

use strict;

our @m_fields = qw { 
                     FILTER
                     FILTER_OPTIONS
                     FIRST
                     MAX
                     PROFILE_DETAILS
                     SORT_ORDER
                   };

#####

1;

# End of file.
