# LJ/OpenSocial/Activity/Field.pm - jop

package LJ::OpenSocial::Activity::Field;
use LJ::OpenSocial::Util::FieldBase;
our @ISA = ( LJ::OpenSocial::Util::FieldBase );
*AUTOLOAD = \&LJ::OpenSocial::Util::FieldBase::AUTOLOAD;

our @m_fields = qw( APP_ID
                    BODY
                    BODY_ID
                    EXTERNAL_ID
                    ID
                    MEDIA_ITEMS
                    POSTED_TIME
                    PRIORITY
                    STREAM_FAVICON_URL
                    STREAM_SOURCE_URL
                    STREAM_TITLE
                    STREAM_URL
                    TEMPLATE_PARAMS
                    TITLE
                    TITLE_ID
                    URL
                    USER_ID
                  );

#####

1;

# End of file.
