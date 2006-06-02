package LJ::CProd::TodoMaxItems;
use base 'LJ::CProd';

sub applicable {
    my ($class, $u) = @_;

    my $paid = 1 << LJ::class_bit('paid');
    return 0 unless LJ::get_cap($u, 'todomax') < LJ::get_cap($paid, 'todomax');
    return 1;
}

sub render {
    my ($class, $u, $version) = @_;
    my $user = LJ::ljuser($u);
    my $link = $class->clickthru_link('cprod.todomaxitems.link', $version);

    return "<p>" . BML::ml($class->get_ml($version), { "user" => $user, "link" => $link }) . "</p>";

}

sub ml { 'cprod.todomaxitems.text' }
sub link { "$LJ::SITEROOT/manage/payments/modify.bml" }
sub button_text { "Upgrade" }

1;
