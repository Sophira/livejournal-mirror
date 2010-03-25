package LJ::Widget::ExamplePostWidget;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

#sub need_res { qw( stc/widgets/examplepostwidget.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $ret;
    $ret .= "This widget does a normal POST.<br />";
    $ret .= "Render it with: <code>LJ::Widget::ExamplePostWidget->render;</code><br />";
    $ret .= 'Put this at the part of the page where you want the POST to be handled: <code>LJ::Widget->handle_post(\%POST, qw( ExamplePostWidget ));</code><br />';

    $ret .= $class->start_form;
    $ret .= "<p>Type in a word: " . $class->html_text( name => "text", size => 10 ) . " ";
    $ret .= $class->html_submit( button => "Click me!" ) . "</p>";
    $ret .= $class->end_form;

    return $ret;
}

sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    if ($post->{text}) {
        warn "You entered: $post->{text}\n";
    }

    return;
}

1;
