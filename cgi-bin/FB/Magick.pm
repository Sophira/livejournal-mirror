#!/usr/bin/perl
#
# FB::Magick - FotoBilder interface to Image::Magick
#  -- uses FotoBilder-style error reporting
#  -- local methods (not passing through to Image::Magick)
#     are named with lowercase by convention (e.g. 'deanimate')

package FB::Magick;

use strict;
use vars qw($AUTOLOAD);
use fields qw(image lock);
use Carp;

use Image::Magick;

# create skeleton structure
# arguments:
#    optional: Image::Magick object or scalarref to image blob
#    optional: arguments to pass to Image::Magick constructor (if you didn't pass one already)
sub new {
    my FB::Magick $self = shift;

    my $arg;  # some ref arg, or not present
    $arg = shift if ref $_[0];

    my @ctor_args = @_;

    $self = fields::new($self)
        unless ref $self;

    # first, did the caller give us an image object to use?
    $self->{image} = $arg
        if ref $arg eq 'Image::Magick';

    # otherwise, create a new Image::Magick object
    $self->{image} ||= Image::Magick->new(@ctor_args)
        or return FB::error("unable to instantiate new Image::Magick object");

    # verify that we have a valid Image::Magick object
    # -- either created or supplied
    return FB::error("invalid Image::Magick object: $self->{image}")
        unless ref $self->{image} eq 'Image::Magick';

    # if the argument was a scalar ref, read it into our image
    if (ref $arg eq 'SCALAR') {
        my $rv = $self->{image}->BlobToImage($$arg);
        return FB::error("error instantiating image from scalarref: $rv") if "$rv";
    }

    # set $self->{lock} to be a DDlockd object (if enabled).  the lock will be
    # held in this FB::Magick object until it goes out of scope, which triggers
    # the release of the lock from ddlockd
    $self->{lock} = _get_scaling_lock()
        or return FB::error("unable to obtain scaling lock");

    return $self;
}

sub DESTROY {
    my FB::Magick $self = shift;

    undef $self->{lock};
    undef $self->{image};
    return 1;
}

sub can {
    my FB::Magick $self = shift;
    my $method = shift;

    return  
        $method =~ /^(can|dataref|new)$/ || 
        grep { exists $_->{$method} } values %FB::Magick::METH_RET;
}

sub dataref {
    my FB::Magick $self = shift;

    return \$self->{image}->ImageToBlob
        or FB::error("Error retrieving data from Image::Magick object");
}

###############################################################################
# Internal FB::Magick-specific helper functions (_* naming)
#

sub _get_scaling_lock {
    my $max_locks = $FB::MAX_SCALING_LOCKS;
    return 1 unless $max_locks;
    my $max_tries = $FB::MAX_SCALING_TRIES || 50;

    # make up to $max_tries attempts to find a free lock,
    # pausing between each iteration
    my $ct = 0;
    while ($ct++ < $max_tries) {
        select(undef, undef, undef, .1);

        # try all available locks and return if we got one
        foreach my $i (1..$max_locks) {
            my $lock = FB::locker()->trylock("scaling_${FB::SERVER_NAME}_${i}");
            return $lock if $lock;
        }
    }
    
    return undef; # failed to get a lock
}

###############################################################################
# Local image modification methods (note lowercase naming)
#

sub deanimate {
    my FB::Magick $self = shift;

    $self->{image} = $self->{image}->[0];
    return 1;
}


###############################################################################
# Image::Magick methods that we allow to pass through via AUTOLOAD
#

sub AUTOLOAD {
    my $method = $AUTOLOAD;
    $method =~ s/^.*:://;

    my FB::Magick $self = shift;

    # paranoia: revalidate our ImageMagick object
    return FB::error("invalid Image::Magick object: $self->{image}")
        unless ref $self->{image} eq 'Image::Magick';

    # there are 4 categories of Image::Magick methods and return values:

    # 1) methods which return an array 
    #    * Get(), ImageToBlob(), ...
    if ($FB::Magick::METH_RET{array}->{$method}) {
        return $self->{image}->$method(@_);
    }

    # 2) methods which operate on an image 
    #    * Resize(), Crop(), ...
    if ($FB::Magick::METH_RET{bool}->{$method}) {
        my $rv = $self->{image}->$method(@_);
        return FB::error("Error in Image::Magick->$method: $rv") if "$rv";
        return 1;
    }

    # 3) methods which return images 
    #    * Average(), Montage(), Clone(), ...
    if ($FB::Magick::METH_RET{image}->{$method}) {
        my $rv = $self->{image}->$method(@_);
        return FB::error("Error in Image::Magick->$method: did not return image: $rv")
            unless ref $rv eq 'Image::Magick';
        return $rv;
    }

    # 4) methods which return a number 
    #    * Read(), Write(), ...
    if ($FB::Magick::METH_RET{int}->{$method}) {
        my $rv = $self->{image}->$method(@_);
        return FB::error("Error in Image::Magick->$method: $rv") if "$rv";
        return $rv+0;
    }
    
    # if they try to call an invalid method, die more loudly
    # ... this isn't a runtime error but misuse of the module

    croak "Image::Magick->$method unsupported by FB::Magick"
        if $self->{image}->can($method);
    croak "Invalid method: Image::Magick->$method";

    return undef;
}


###############################################################################
# Supported methods and their return value types
#

%FB::Magick::METH_RET = 
    (
     # returns an array
     array => {
         map { $_ => 1 } 
         qw(
            Get
            ImageToBlob
            MagickToMime
            Ping
            QueryColorname
            QueryFont
            QueryFontMetrics
            QueryFormat
            )
         },

     # returns an Image::Magick object
     image => {
         map { $_ => 1 } 
         qw(
            Append
            Average
            Clone
            Fx
            Montage
            Morph
            Preview
            Transform
            )
         },

     # returns string undef on success
     bool => {
         map { $_ => 1 } 
         qw(
            AdaptiveThreshold
            AddNoise
            AffineTransform
            Annotate
            BlackThreshold
            Blur
            Border
            Charcoal
            Chop
            Clip
            Coalesce
            ColorFloodfill
            Colorize
            Comment
            Compare
            Composite
            Contrast
            Convolve
            Crop
            CycleColormap
            Deconstruct
            Describe
            Despeckle
            Draw
            Edge
            Emboss
            Enhance
            Equalize
            Evaluate
            Flatten
            Flip
            Flop
            Frame
            Gamma
            GaussianBlur
            GetPixels
            Implode
            Label
            Level
            Magnify
            Map
            MatteFloodfill
            MedianFilter
            Minify
            Modulate
            Mogrify
            MogrifyRegion
            MotionBlur
            Negate
            Normalize
            OilPaint
            Opaque
            Posterize
            Profile
            Quantize
            RadialBlur
            Raise
            ReduceNoise
            Resample
            Resize
            Roll
            Rotate
            Sample
            Scale
            Segment
            Separate
            Set
            Shade
            Sharpen
            Shave
            Shear
            Signature
            Solarize
            Splice
            Spread
            Stegano
            Stereo
            Strip
            Swirl
            Texture
            Thumbnail
            Threshold
            Tint
            Transparent
            Trim
            UnsharpMask
            Wave
            WhiteThreshold
            )
         },

     # returns an int
     int => { 
         map { $_ => 1 } 
         qw(
            BlobToImage
            Read
            Write
            Display
            Animate
            )
         },

     );

1;
