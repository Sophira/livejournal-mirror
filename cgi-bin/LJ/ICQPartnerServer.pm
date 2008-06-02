package LJ::ICQPartnerServer;

use strict;

use LWP::UserAgent;
use HTTP::Request;
use HTTP::Headers;

sub alert {
    my $class = shift;

    my %params = (
        common_url => $LJ::ICQ_COMMON_URL,
        common_width => $LJ::ICQ_COMMON_WIDTH,
        common_height => $LJ::ICQ_COMMON_HEIGHT,
        common_title => $LJ::ICQ_COMMON_TITLE,
        common_extra_url => $LJ::ICQ_COMMON_EXTRA_URL,
        icq51_width => $LJ::ICQ_ICQ51_WIDTH,
        icq51_height => $LJ::ICQ_ICQ51_HEIGHT,
        icq51_free_data => $LJ::ICQ_ICQ51_FREE_DATA,
        icq6_display_name => $LJ::ICQ_ICQ6_DISPLAY_NAME,
        icq6_toaster_title => $LJ::ICQ_ICQ6_TOASTER_TITLE,
        icq6_image_url => $LJ::ICQ_ICQ6_IMAGE_URL,
        icq6_action_text => $LJ::ICQ_ICQ6_ACTION_TEXT,
        icq6_extra_title => $LJ::ICQ_ICQ6_EXTRA_TITLE,
        icq6_width => $LJ::ICQ_ICQ6_WIDTH,
        icq6_height => $LJ::ICQ_ICQ6_HEIGHT,
        @_
    );

    my $envelop = soap_envelop(
        webmessage(%params),
        uins($params{'to'})
    ) ;
    
    call($envelop);    
}

sub call {
    my $content = shift or die 'invalid content';
    my $url = (shift or $LJ::ICQ_PS_URL);
    
    # warn "Calling:\n$content";
    my $ua = LWP::UserAgent->new;
    my $request = HTTP::Request->new(
        POST => $url, 
        HTTP::Headers->new(
            Content_Type => 'text/xml; charset=utf-8',
        ),
        $content
    );
    
    my $response = $ua->request($request);
    
    if ($response->is_success) {
        return 1;
    }
    else {
        die $response->status_line . $response->content;
    }    
}

sub webmessage {
    my %params = @_;
    my $template = 
    '<webmsg xsi:type="m:WebMsgObject">
        <type xsi:type="xsd:integer">1</type> 
        <url xsi:type="xsd:string">%%common_url%%</url> 
        <width xsi:type="xsd:integer">%%common_width%%</width> 
        <height xsi:type="xsd:integer">%%common_height%%</height> 
        <title xsi:type="xsd:string">%%common_title%%</title> 
        <icid xsi:type="xsd:string">ICQID</icid> 
        <plugin_id xsi:type="xsd:string"></plugin_id>
        <extra_url xsi:type="xsd:string">%%common_extra_url%%</extra_url> 
        <icq6 xsi:type="m:WebMsg6Object">
            <displayname xsi:type="xsd:string">%%icq6_display_name%%</displayname> 
            <toastertitle xsi:type="xsd:string">%%icq6_toaster_title%%</toastertitle> 
            <text xsi:type="xsd:string">%%icq6_text%%</text> 
            <image_url xsi:type="xsd:string">%%icq6_image_url%%</image_url> 
            <action_text xsi:type="xsd:string">%%icq6_action_text%%</action_text> 
            <extratitle xsi:type="xsd:string">%%icq6_extra_title%%</extratitle> 
            <extrawidth xsi:type="xsd:string">%%icq6_width%%</extrawidth> 
            <extraheight xsi:type="xsd:string">%%icq6_height%%</extraheight> 
        </icq6>
        <icq51 xsi:type="m:WebMsg51Object">
            <width xsi:type="xsd:integer">%%icq51_width%%</width> 
            <height xsi:type="xsd:integer">%%icq51_height%%</height> 
            <text xsi:type="xsd:string">%%icq51_text%%</text> 
            <free_data xsi:type="xsd:string">%%icq51_free_data%%</free_data> 
            <headline xsi:type="xsd:string">%%icq51_toaster_title%%</headline> 
            <plugin_id xsi:type="xsd:string"></plugin_id>
            <icid xsi:type="xsd:string">ICQ5 Notification</icid> 
            <toaster_id xsi:type="xsd:string">Xicq_toasterX</toaster_id> 
        </icq51>
    </webmsg>';
    $template =~ s/%%([^%]+)%%/$params{$1}/g;
    return $template;
}

sub uins {
    return 
        '<uins xsi:type="m:UINSObject">' .
        join('', map { '<uin xsi:type="xsd:string">' . $_ . '</uin>' }  @_) . 
        '</uins>';
}

sub soap_envelop {    
    return sprintf '%s%s%s',
'<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:SOAP-ENC="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
<SOAP-ENV:Body>
<m:icqAlert xmlns:m="urn:ICQServer" SOAP-ENV:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<params xsi:type="m:AlertObject">',
        join('', @_),
'</params>
</m:icqAlert>
</SOAP-ENV:Body>
</SOAP-ENV:Envelope>';
}

1;