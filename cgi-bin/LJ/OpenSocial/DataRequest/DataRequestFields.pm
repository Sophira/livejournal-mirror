# LJ/OpenSocial/DataRequest/DataRequestFields.pm - jop

package LJ::OpenSocial::DataRequest::DataRequestFields;
use LJ::OpenSocial::Util::FieldBase;
our @ISA = ( LJ::OpenSocial::Util::FieldBase );
*AUTOLOAD = \&LJ::OpenSocial::Util::FieldBase::AUTOLOAD;

our @m_fields = qw( 
                    ESCAPE_TYPE
                  );

#####

1;

# End of file.
