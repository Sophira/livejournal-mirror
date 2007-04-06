package FB::ThumbFormat;
use strict;

sub new {
    my $class = shift;
    my $fmtstring = shift;
    my $self = {
        'fmtstring' => $fmtstring,
    };
    return bless $self;
}

sub valid {
    my $self = shift;
    my ($w, $h) = $self->{fmtstring} =~ /^(\w\w)(\w\w)/;
    return 0 unless $w && $h;
    $w = hex($w);
    $h = hex($h);
    $self->{width} = $w;
    $self->{height} = $h;
    return 0 unless $w && $h && $w <= 200 && $h <= 200;
    return 1;
}

sub width {
    my $self = shift;
    $self->valid or return undef;
    return $self->{'width'};
}

sub height {
    my $self = shift;
    $self->valid or return undef;
    return $self->{'height'};
}

sub string {
    my $self = shift;
    return $self->{fmtstring};
}

sub cropped {
    my $self = shift;
    return $self->{fmtstring} =~ /c/;
}

sub stretched {
    my $self = shift;
    return $self->{fmtstring} =~ /h/;
}

sub zoomed {
    my $self = shift;
    return $self->{fmtstring} =~ /z/;
}

sub gray {
    my $self = shift;
    return $self->{fmtstring} =~ /g/;
}

1;
