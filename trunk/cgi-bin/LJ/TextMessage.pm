#!/usr/bin/perl
#
# LJ::TextMessage class
# See perldoc documentation at the end of this file.
#
# -------------------------------------------------------------------------
#
# This package is released under the LGPL (GNU Library General Public License)
#
# A copy of the license has been included with the software as LGPL.txt.  
# If not, the license is available at:
#      http://www.gnu.org/copyleft/library.txt
#
# -------------------------------------------------------------------------
#

package LJ::TextMessage;

use URI::Escape;
use LWP::UserAgent;
use MIME::Lite;

use strict;
use vars qw($VERSION $SENDMAIL %providers);

$VERSION = '1.5.0';

# default path to sendmail, if none other specified.  we should probably
# use something more perl-ish and less unix-specific, but whateva'

$SENDMAIL = "/usr/sbin/sendmail -t";   

%providers = (

    'email' => {
        'name'       => 'Other',
        'notes'      => 'If your provider isn\'t supported directly, enter the email address that sends you a text message in phone number field. To be safe, the entire message is sent in the body of the message, and the length limit is really short. We\'d prefer you give us information about your provider so we can support it directly.',
        'fromlimit'  => 15,
        'msglimit'   => 100,
        'totlimit'   => 100,
    },

    'airtouch' => {
        'name'       => 'Verizon Wireless (formerly Airtouch)',
        'notes'      => 'Enter your phone number. Messages are sent to number@airtouchpaging.com. This is ONLY for former AirTouch customers. Verizon Wireless customers should use Verizon Wireless instead.',
        'fromlimit'  => 20,
        'msglimit'   => 120,
        'totlimit'   => 120,
    },

    'alltel' => {
        'name'          => 'Alltel',
        'notes'         => 'Enter your phone number. Goes to number@message.alltel.com.',
        'fromlimit'     => 50,
        'msglimit'      => 116,
        'totlimit'      => 116,
    },

    'ameritech' => {
        'name'		=> 'Ameritech (ACSWireless)',
        'notes'		=> 'Enter your phone number. Goes to number@paging.acswireless.com',
        'fromlimit'	=> 120,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'arch' => {
        'name'		=> 'Arch Wireless',
        'notes'		=> 'Enter your phone number. Sent via http://www.arch.com/message/ (assumes blank PIN)',
        'fromlimit'	=> 15,
        'msglimit'	=> 240,
        'totlimit'	=> 240,
    },

    'att' => {
        'name'		=> 'AT&T Wireless',
        'notes'		=> 'Enter your phone number. Goes to number@mobile.att.net',
        'fromlimit'	=> 50,
        'msglimit'	=> 150,
        'totlimit'	=> 150,
    },

    'bellmobilityca' => {
        'name'		=> 'Bell Mobility Canada',
        'notes'		=> 'Enter your phone number, including the 1 prefix. Goes to number@txt.bellmobility.ca',
        'fromlimit'	=> 20,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'beemail' => {
        'name'		=> 'BeeLine GSM',
        'notes'		=> 'Enter your phone number. Goes to number@sms.beemail.ru',
        'fromlimit'	=> 50,
        'msglimit'	=> 255,
        'totlimit'	=> 255,
    },

    'bellsouthmobility' => {
        'name'		=> 'BellSouth Mobility',
        'notes'		=> 'Enter your phone number. Goes to number@blsdcs.net',
        'fromlimit'	=> 15,
        'msglimit'	=> 160,
        'totlimit'	=> 160,
    },

    'blueskyfrog' => {
        'name'		=> 'Blue Sky Frog',
        'notes'		=> 'Enter your phone number. Goes to number@blueskyfrog.com',
        'fromlimit'	=> 30,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },
    
    'cellularonedobson' => {
        'name'		=> 'CellularOne (Dobson)',
        'notes'		=> 'Enter your phone number. Goes to number@mobile.celloneusa.com',
        'fromlimit'	=> 20,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'centennial' => {
        'name'		=> 'Centennial Wireless',
        'notes'		=> 'Enter your phone number. Sent via http://www.centennialcom.com',
        'fromlimit'	=> 10,
        'msglimit'	=> 110,
        'totlimit'	=> 110,
    },

    'cingular' =>
    {
        'name'          => 'Cingular',
        'notes'         => 'Enter your phone number. Goes to number@mobile.mycingular.com',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'csouth1' => {
        'name'		=> 'Cellular South',
        'notes'		=> 'Enter your phone number. Messages are sent to number@csouth1.com',
        'fromlimit'	=> 50,
        'msglimit'	=> 155,
        'totlimit'	=> 155,	      
    },

    'dutchtone' => {
        'name'          => 'Dutchtone/Orange-NL',
        'notes'         => 'Enter your phone number. Messages are sent to number@sms.orange.nl',
        'fromlimit'     => 15,
        'msglimit'      => 150,
        'totlimit'      => 150,
    },
    
    'edgewireless' => {
        'name'          => 'Edge Wireless',
        'notes'         => 'Enter your phone number. Messages are sent to number@sms.edgewireless.com',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'emt' => {
        'name'          => 'Estonia Mobile Telefon',
        'notes'         => 'Enter your phone number. Messages are sent via web gateway.',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'fidoca' => {
        'name'		=> 'Fido Canada',
        'notes'		=> 'Enter your phone number. Goes to number@fido.ca.',
        'fromlimit'	=> 15,
        'msglimit'	=> 140,
        'totlimit'	=> 140,
    },

    'goldentelecom' => {
        'name'          => 'Golden Telecom',
        'notes'         => 'Enter your phone number or nickname. Messages are sent to number@sms.goldentele.com',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'ideacellular' => {
        'name'          => 'Idea Cellular',
        'notes'         => 'Enter your phone number. Messages are sent to number@ideacellular.net',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
	},

    'imcingular' => 
    {
        'name'		=> 'Cingular IM Plus/Bellsouth IPS',
        'notes'		=> 'Enter 8 digit PIN or user name. Goes to @imcingular.com',
        'fromlimit'	=> 100,
        'msglimit'	=> 16000,
        'totlimit'	=> 16000,
    },

    'imcingular-cell' => 
    {
        'name'		=> 'Cingular IM Plus/Bellsouth IPS Cellphones',
        'notes'		=> 'Enter phone number. Goes to @mobile.mycingular.com',
        'fromlimit'	=> 100,
        'msglimit'	=> 16000,
        'totlimit'	=> 16000,
    },

    'jphone' => {
        'name'          => 'J-Phone',
        'notes'         => 'Enter your phone number. Messages are sent to number@jp-t.ne.jp',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'kyivstar' => {
        'name'		=> 'Kyivstar',
        'notes'		=> 'Sent by addressing the message to number@sms.kyivstar.net',
        'fromlimit'	=> 30,
        'msglimit'	=> 160,
        'totlimit'	=> 160,
    },

    'lmt' => {
        'name'		=> 'LMT',
        'notes'		=> 'Sent by addressing the message to number@smsmail.lmt.lv',
        'fromlimit'	=> 30,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'meteor' => {
        'name'          => 'Meteor',
        'notes'         => 'Enter your phone number. Goes to number@sms.mymeteor.ie',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'metrocall' => {
        'name'		=> 'Metrocall Pager',
        'notes'		=> '10-digit phone number. Goes to number@page.metrocall.com',
        'fromlimit'	=> 120,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'movistar' => {
        'name'		=> 'Telefonica Movistar',
        'notes'		=> '10-digit phone number. Goes to number@movistar.net',
        'fromlimit'	=> 20,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'mtsmobility' => {
        'name'		=> 'Manitoba Telecom Systems',
        'notes'		=> '10-digit phone number. Goes to @text.mtsmobility.com',
        'fromlimit'	=> 20,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'mobilfone' => {
        'name'		=> 'Mobilfone',
        'notes'		=> 'Enter your phone number. Goes to number@page.mobilfone.com',
        'fromlimit'	=> 20,
        'msglimit'	=> 160,
        'totlimit'	=> 160,
    },

    'nbtel' => {
        'name'          => 'NBTel',
        'notes'         => 'Enter your phone number. Message is sent to number@wirefree.informe.ca',
        'fromlimit'     => 11,
        'msglimit'      => 140,
        'totlimit'      => 140,
    },
    
    'netcom' => {
        'name'		=> 'Netcom',
        'notes'		=> 'Enter your phone number. Goes to number@sms.netcom.no',
        'fromlimit'	=> 20,
        'msglimit'	=> 160,
        'totlimit'	=> 160,
    },

    'nextel' => {
        'name'		=> 'Nextel',
        'notes'		=> '10-digit phone number. Goes to 10digits@messaging.nextel.com. Note: do not use dashes in your phone number.',
        'fromlimit'	=> 50,
        'msglimit'	=> 126,
        'totlimit'	=> 126,
    },

    'nwgsm-megafon' => {
        'name'          => 'North-WestGSM Megafon',
        'notes'         => 'Enter your phone number. Sent via web gateway.',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'npiwireless' => {
        'name'		=> 'NPI Wireless',
        'notes'		=> 'Enter your phone number. Goes to number@npiwireless.com.',
        'fromlimit'	=> 20,
        'msglimit'	=> 160,
        'totlimit'	=> 160,
    },

    'ntelos' => {
        'name'		=> 'NTELOS',
        'notes'		=> '10-digit phone number. Goes to 10digits@pcs.ntelos.com.',
        'fromlimit'	=> 30,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'o2' => {
        'name'          => 'O2 (formerly BTCellnet)',
        'notes'         => 'Enter O2 username - must be enabled first at http://www.o2.co.uk. Goes to username@o2.co.uk.',
        'fromlimit'     => 20,
        'msglimit'      => 120,
        'totlimit'      => 120,
    },

    'o2mmail' => {
        'name'          => 'O2 M-mail (formerly BTCellnet)',
        'notes'         => 'Enter phone number, omitting intial zero - must be enabled first by sending an SMS saying "ON" to phone number "212". Goes to +44[number]@mmail.co.uk.',
        'fromlimit'     => 20,
        'msglimit'      => 120,
        'totlimit'      => 120,
    },

    'optus' => {
        'name'		=> 'Optus',
        'notes'		=> 'Enter your phone number. Goes to @optusmobile.com.au',
        'fromlimit'	=> 20,
        'msglimit'	=> 160,
        'totlimit'	=> 160,
    },

    'pacbell' => {
        'name'		=> 'Pacific Bell Cingular',
        'notes'		=> '10-digit phone number. Goes to @mobile.mycingular.com',
        'fromlimit'	=> 20,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'pagenet' => {
        'name'		=> 'Pagenet',
        'notes'		=> '10-digit phone number (or gateway and pager number separated by a period). Goes to number@pagenet.net.',
        'fromlimit'	=> 20,
        'msglimit'	=> 220,
        'totlimit'	=> 240,
    },

    'pcsrogers' => {
        'name'		=> 'PCS Rogers AT&T Wireless',
        'notes'		=> '10-digit phone number. Goes to number@pcs.rogers.com',
        'fromlimit'	=> 20,
        'msglimit'	=> 150,
        'totlimit'	=> 150,
    },

    'pscwireless' => {
        'name'		=> 'PSC Wireless',
        'notes'		=> 'Enter your phone number. Goes to number@sms.pscel.com',
        'fromlimit'	=> 20,
        'msglimit'	=> 140,
        'totlimit'	=> 140,
    },

    'ptel' => {
        'name'		=> 'Powertel',
        'notes'		=> '10-digit phone number. Goes to number@ptel.net',
        'fromlimit'	=> 20,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },

    'qualcomm' => {
        'name'          => 'Qualcomm',
        'notes'         => 'Enter your username. Goes to username@pager.qualcomm.com',
        'fromlimit'     => 20,
        'msglimit'      => 120,
        'totlimit'      => 120,
    },

    'qwest' => {
        'name'		=> 'Qwest',
        'notes'		=> '10-digit phone number. Goes to @qwestmp.com',
        'fromlimit'	=> 14,
        'msglimit'	=> 100,
        'totlimit'	=> 100,
    },

    'skytelalpha' => {
        'name'		=> 'Skytel - Alphanumeric',
        'notes'		=> 'Enter your 7-digit pin number as your number and your message will be mailed to pin@skytel.com',
        'fromlimit'	=> 15,
        'msglimit'	=> 240,
        'totlimit'	=> 240,
    },

    'smartsgsm' => {
        'name'          => 'Smarts GSM',
        'notes'         => 'Enter your phone number. Sent via http://www.samara-gsm.ru/scripts/smsgate.exe',
        'fromlimit'     => 11,
        'msglimit'      => 70,
        'totlimit'      => 70,
    },

    'sprintpcs' => {
        'name'		=> 'Sprint PCS',
        'notes'		=> 'Enter your 10-digit phone number. Goes to @messaging.sprintpcs.com',
        'fromlimit'	=> 15,
        'msglimit'	=> 160,
        'totlimit'	=> 160,
    },

    'sprintpcs-shortmail' => {
        'name'          => 'Sprint PCS - Short Mail',
        'notes'         => 'Enter your phone number. Goes to @messaging.sprintpcs.com',
        'fromlimit'     => 15,
        'msglimit'      => 1000,
        'totlimit'      => 1000,
    },

    'suncom' => {
        'name'          => 'SunCom',
        'notes'         => 'Enter your number. Email will be sent to number@tms.suncom.com.',
        'fromlimit'     => 18,
        'msglimit'      => 110,
        'totlimit'      => 110,
    },

    'surewest' => {
        'name'          => 'SureWest Communications',
        'notes'         => 'Enter your phone number. Message will be sent to number@mobile.surewest.com',
        'fromlimit'     => 20,
        'msglimit'      => 200,
        'totlimit'      => 200,
    },

    'telus' => {
        'name'		=> 'Telus Mobility',
        'notes'		=> '10-digit phone number. Goes to 10digits@msg.telus.com.',
        'fromlimit'	=> 30,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },
    

    'tmobileaustria' => {
        'name'       => 'T-Mobile Austria',
        'notes'      => 'Enter your number starting with 43676. Email will be sent to number@sms.t-mobile.at.',
        'fromlimit'  => 15,
        'msglimit'   => 160,
        'totlimit'   => 160,
    },

    'tmobilegermany' => {
        'name'       => 'T-Mobile Germany',
        'notes'      => 'Enter your number. Email will be sent to number@T-D1-SMS.de',
        'fromlimit'  => 15,
        'msglimit'   => 160,
        'totlimit'   => 160,
    },

    'tmobileholland' => {
        'name'       => 'T-Mobile Netherlands',
        'notes'      => 'Send "EMAIL ON" to 555 from your phone, then enter your number starting with 316. Email will be sent to number@gin.nl',
        'fromlimit'  => 15,
        'msglimit'   => 160,
        'totlimit'   => 160,
    },

    'tmobileusa' => {
        'name'		=> 'T-Mobile USA',
        'notes'		=> 'Messages are sent to number@tmomail.net',
        'fromlimit'	=> 30,
        'msglimit'	=> 160,
        'totlimit'	=> 160,	      
    },

    'uboot' => {
        'name'		=> 'uBoot',
        'notes'		=> 'Enter your username as the phone number. See http://www.uboot.com for more details',
        'fromlimit'	=> 146,
        'msglimit'	=> 146,
        'totlimit'	=> 146,
    },
    
    'umc' => {
        'name'		=> 'UMC',
        'notes'		=> 'Sent by addressing the message to number@sms.umc.com.ua',
        'fromlimit'	=> 10,
        'msglimit'	=> 120,
        'totlimit'	=> 120,
    },    

    'uscc' => {
        'name'		=> 'US Cellular',
        'notes'		=> 'Enter a 10 digit USCC Phone Number. Messages are sent via http://uscc.textmsg.com/scripts/send.idc and only contain the message field',
        'msglimit'	=> 150,
        'totlimit'	=> 150,	      
    },

    'vzw' => {
        'name'		=> 'Verizon Wireless',
        'notes'		=> 'Enter your 10-digit phone number. Messages are sent via email to number@vtext.com.',
        'fromlimit'	=> 34,
        'msglimit'	=> 140,
        'totlimit'	=> 140,	      
    },
    
    'vzw-myairmail' => {
        'name'          => 'Verizon Wireless (myairmail.com)',
        'notes'         => 'Enter your phone number. Messages are sent via to number@myairmail.com.',
        'fromlimit'     => 34,
        'msglimit'      => 140,
        'totlimit'      => 140,
    },
    
    'vessotel' => {
        'name'          => 'Vessotel',
        'notes'         => 'Enter your phone number. Messages are sent to roumer@pager.irkutsk.ru.',
        'fromlimit'     => 20,
        'msglimit'      => 800,
        'totlimit'      => 800,
    },

    'virginmobileuk' => {
        'name'          => 'Virgin Mobile UK',
        'notes'         => 'Enter your phone number. Messages are sent to number@vxtras.com.',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'virginmobileusa' => {
        'name'          => 'Virgin Mobile USA',
        'notes'         => 'Enter your phone number. Messages are sent to number@vmobl.com.',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'vodacom' => {
        'name'		=> 'Vodacom',
        'notes'		=> 'Enter your 10 digit phone number. Messages are sent via Vodacom\'s web gateway.',
        'fromlimit'	=> 15,
        'msglimit'	=> 140,
        'totlimit'	=> 140,
    },

    'voicestream' => {
        'name'		=> 'Voicestream',
        'notes'		=> 'Enter your 10-digit phone number. Message is sent via the email gateway, since they changed their web gateway and we have not gotten it working with the new one yet.',
        'fromlimit'	=> 15,
        'msglimit'	=> 140,
        'totlimit'	=> 140,
    },
    
    'weblinkwireless' => {
        'name'          => 'Weblink Wireless',
        'notes'         => 'Enter your phone number. Goes to @airmessage.net',
        'fromlimit'     => 20,
        'msglimit'      => 160,
        'totlimit'      => 160,
    },

    'wyndtell' => {
        'name'		=> 'WyndTell',
        'notes'		=> 'Enter username/phone number. Goes to @wyndtell.com',
        'fromlimit'	=> 20,
        'msglimit'	=> 480,
        'totlimit'	=> 500,
    },

);

sub providers
{
    return sort { lc($providers{$a}->{'name'}) cmp lc($providers{$b}->{'name'}) } keys %providers;    
}

sub provider_info
{
    my $provider = remap(shift);
    return { %{$providers{$provider}} };
}

sub remap {
    my $provider = shift;
    return "o2mmail" if $provider eq "btcellnet";
    return "voicestream" if $provider eq "voicestream2";
    return "tmobileusa" if $provider eq "tmomail";
    return "suncom" if $provider eq "tms-suncom";
    return "cingular" if $provider eq "cingular-acs";
    return "cingular" if $provider eq "cingular-texas";
    return $provider;
}

sub new {
    my ($class, $args) = @_;
    my $self = {};
    bless $self, ref $class || $class;
    
    $self->init($args);
    return $self;
}

sub init {
    my $self = shift;
    my $args = shift;
    $self->{'sendmail'} = $args->{'mailcommand'} || $SENDMAIL;
    $self->{'provider'} = remap($args->{'provider'});
    $self->{'number'} = $args->{'number'};
    $self->{'smtp'} = $args->{'smtp'};
}
 
sub send
{
    my $self = shift;
    my $msg = shift;      # hashref: 'from', 'message'
    my $errors = shift;   # arrayref
    my $provider = $self->{'provider'};

    unless ($provider) {
        push @$errors, "No provider specified in object constructor.";
        return;
    }
    
    unless ($msg) {
	push @$errors, "No message specified in object constructor.";
	return;
    }
    unless ($self) {
        push @$errors, "No self specified in object constructor.";
        return;
    }
    unless ($self->{'sendmail'}) {
        push @$errors, "No sendmail specified in object constructor.";
        return;
    }
    unless ($self->{'provider'}) {
        push @$errors, "No provider specified in object constructor.";
        return;
    }
    unless ($self->{'number'}) {
        push @$errors, "No number specified in object constructor.";
        return;
    }
    
    my $prov = $providers{$provider};

    ##
    ## truncate 'from' if it's too long for the given provider
    ##

    if (length($msg->{'from'}) > $prov->{'fromlimit'}) {
        $msg->{'from'} = substr($msg->{'from'}, 0, $prov->{'fromlimit'});
    }

    ##
    ## now send the message, based on the provider
    ##

    if ($provider eq "email") 
    {
        send_mail($self, {
            'to'	=> $self->{'number'},
            'from'	=> "LiveJournal",
            'body'	=> "(f:$msg->{'from'})$msg->{'message'}",
        },$errors);
    } 

    elsif ($provider eq "airtouch")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@sender.airtouchpaging.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "alltel")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@message.alltel.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "ameritech")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@paging.acswireless.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "arch")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@archwireless.net",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "att")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@mobile.att.net",
            'from'	=> "$msg->{'from'}",
            'body'	=> $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "beemail") 
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@sms.beemail.ru",
            'body'	=> "$msg->{'from'} - $msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "bellmobilityca")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@txt.bellmobility.ca",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "bellsouthmobility")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@blsdcs.net",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
            'subject'	=> "LJ",
        },$errors);
    }

   
    elsif ($provider eq "blueskyfrog") 
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@blueskyfrog.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    } 

    elsif ($provider eq "cellularonedobson")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@mobile.celloneusa.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "centennial")
    {
        post_webform("http://matrix.wysdom.com/cgi-bin/mim/newxmessage.cgi", {
            'ToNumber'	 => $self->{'number'},
            'Message'	 => $msg->{'message'},
	    'FromNumber' => $msg->{'from'},
        },$errors);
    }

    elsif ($provider eq "cingular")
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@mobile.mycingular.com",
            'from'	=> $msg->{'from'},
            'body'	=> $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "csouth1") {
        send_mail($self, {
            'to' => "$self->{'number'}\@csouth1.com",
            'from' => $msg->{'from'},
            'body' => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "dutchtone") 
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@sms.orange.nl",
            'body'      => "$msg->{'from'}\n$msg->{'message'}",
        },$errors);
    } 

    elsif ($provider eq "edgewireless") {
        send_mail($self, {
            'to' => "$self->{'number'}\@sms.edgewireless.com",
            'from' => $msg->{'from'},
            'body' => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "emt")
    {
        post_webform("http://www.emt.ee/wwwmain", {
            'phoneNo'   => $self->{'number'},
            'message'    => $msg->{'message'},
            'userEmail' => $msg->{'from'},
        },$errors);
    }

    elsif ($provider eq "fidoca" )
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@fido.ca",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "goldentelecom") {
        send_mail($self, {
            'to' => "$self->{'number'}\@sms.goldentele.com",
            'from' => $msg->{'from'},
            'body' => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "ideacellular") {
        send_mail($self, {
            'to' => "$self->{'number'}\@ideacellular.net",
            'from' => $msg->{'from'},
            'body' => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "imcingular")
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@imcingular.com",
            'from'	=> $msg->{'from'},
            'body'	=> $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "imcingular-cell")
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@mobile.mycingular.com",
            'from'	=> $msg->{'from'},
            'body'	=> $msg->{'message'},
        },$errors);
    }
    
    elsif ($provider eq "jphone") {
        send_mail($self, {
            'to' => "$self->{'number'}\@jp-t.ne.jp",
            'from' => $msg->{'from'},
            'body' => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "kyivstar") 
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@sms.kyivstar.net",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    } 

    elsif ($provider eq "lmt") 
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@smsmail.lmt.lv",

            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "meteor")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@sms.mymeteor.ie",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "metrocall")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@page.metrocall.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "mobilfone")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@page.mobilfone.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "movistar")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@correo.movistar.net",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "mtsmobility")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@text.mtsmobility.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "nbtel") 
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@wirefree.informe.ca",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    } 
    
    elsif ($provider eq "netcom")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@sms.netcom.no",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "nextel")  # Nextel
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@messaging.nextel.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
            'subject'	=> "LJ",
        },$errors);
    }

    elsif ($provider eq "nwgsm-megafon")
    {
        post_webform("http://www-old.nwgsm.ru:8101/sendsms.htm", {
            "tll"            => $self->{'number'},
            "txt"            => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "npiwireless")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@npiwireless.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "ntelos")  # NTELOS PCS
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@pcs.ntelos.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
            'subject'	=> "LJ",
        },$errors);
    }

    elsif ($provider eq "o2")
    {
        send_mail($self, {
            'to'        => $self->{'number'}."\@o2.co.uk",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "o2mmail")
    {
        send_mail($self, {
            'to'        => "+44".$self->{'number'}."\@mmail.co.uk",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "optus")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@optusmobile.com.au",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "pacbell")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@mobile.mycingular.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "pagenet")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@pagenet.net",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "pcsrogers")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@pcs.rogers.com",
            # 'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'from'}: $msg->{'message'}",
	    'subject'	=> "LJ",
        },$errors);
    }

    elsif ($provider eq "pscwireless")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@sms.pscel.com",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "ptel")
    {
        send_mail($self, { 
            'to'	=> "$self->{'number'}\@ptel.net",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }

   elsif ($provider eq "qualcomm")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@pager.qualcomm.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "qwest")
    {
        send_mail($self, {
            'to'        => "(f:$msg->{'from'})$self->{'number'}\@uswestdatamail.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
            'subject'	=> "LJ",
        },$errors);
    }

    elsif ($provider eq "skytelalpha")
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@skytel.com",
            'from'	=> $msg->{'from'},
            'body'	=> $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "smartsgsm")
    {
        post_webform("http://www.samara-gsm.ru/scripts/smsgate.exe/send", { 
            "phone"     => $self->{'number'},
            "sendtext"  => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "sprintpcs") # SprintPCS
    {
        send_mail($self, {
            'to'        => "(f:$msg->{'from'}) $self->{'number'}\@messaging.sprintpcs.com",
            'from'      => "$msg->{'from'}\@livejournal.com",
            'body'      => "$msg->{'message'}",
	    'subject'	=> "LJ",
        },$errors);
    }

    elsif ($provider eq "sprintpcs-shortmail")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@messaging.sprintpcs.com",
            'from'      => "$msg->{'from'}\@livejournal.com",
            'body'      => "$msg->{'message'}",
            'subject'   => "LJ",
        },$errors);
    }

    elsif ($provider eq "suncom") {
        send_mail($self, {
            'to'   => "$self->{'number'}\@tms.suncom.com",
            'from' => "$msg->{'from'}",
            'body' => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "surewest") {
        send_mail($self, {
            'to'   => "$self->{'number'}\@mobile.surewest.com",
            'body' => "(f:$msg->{'from'}) $msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "telus")  # Telus Mobility
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@msg.telus.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
            'subject'	=> "LJ",
        },$errors);
    }

    elsif ($provider eq "tmobileaustria")    
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@sms.t-mobile.at",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "tmobilegermany")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@T-D1-SMS.de",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "tmobileholland")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@gin.nl",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "tmobileusa") 
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@tmomail.net",
            'subject'   => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
            'from'      => "LJ",
        },$errors);
    }
    
    elsif ($provider eq "uboot")
    {
       	post_webform("http://www.uboot.com/cgi-bin/nickpage.fcgi", {
            "page"	=> "Sms",
            "action"	=> "send_sms",
            "nickname"	=> $self->{'number'},
            "text"	=> "LiveJournal($msg->{'from'}) $msg->{'message'}",
        },$errors);
    }
    
    elsif ($provider eq "uma") 
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@sms.umc.com.ua",
            'from'	=> "$msg->{'from'}",
            'body'	=> "$msg->{'message'}",
        },$errors);
    }    

    elsif ($provider eq "uscc")  # U.S Cellular
    {
        post_webform("http://66.77.16.246/index.php", { 
            "number"		=> $self->{'number'},
            "message"		=> $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "vzw")  # Verizon Wireless
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@vtext.com",
            'from'      => "$msg->{'from'}\@livejournal.com",
            'body'      => "$msg->{'message'}",
	    'subject'	=> "LJ",

            # is this necessary?  (--brad 1.4.10)
            # 'return-path'    => "$msg->{'from'}\@livejournal.com",
        },$errors);
    }

    elsif ($provider eq "vzw-myairmail")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@myairmail.com",
            'from'      => "$msg->{'from'}\@livejournal.com",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "vessotel" )
    {
        send_mail($self, {
            'to'        => "roumer\@pager.irkutsk.ru",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
	    'subject'   => "$self->{'number'}",
        },$errors);
    }

    elsif ($provider eq "virginmobileuk" )
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@vxtras.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "virginmobileusa" )
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@vmobl.com",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "vodacom" )
    {
        post_webform("http://websms.vodacom.net/send.php3", {
            "cellnum"         => $self->{'number'},
            "message"         => $msg->{'message'},
        },$errors);
    }

    elsif ($provider eq "voicestream" )
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@voicestream.net",
            'from'      => "$msg->{'from'}",
            'body'      => "$msg->{'message'}",
        },$errors);
    }

    elsif ($provider eq "weblinkwireless")
    {
        send_mail($self, {
            'to'        => "$self->{'number'}\@airmessage.net",
            'from'      => $msg->{'from'},
            'body'      => $msg->{'message'},
        },$errors);
    }
    
    elsif ($provider eq "wyndtell")
    {
        send_mail($self, {
            'to'	=> "$self->{'number'}\@wyndtell.com",
            'from'	=> $msg->{'from'},
            'body'	=> $msg->{'message'},
        },$errors);
    }

    else {
        push @$errors, "Tried to send a message to an unknown or unsupported provider.";
    }
}

sub post_webform
{
    my ($url, $postvars, $errors) = @_;

    ### we're going to POST to provider's page
    my $ua = new LWP::UserAgent;
    $ua->agent("Mozilla/4.0 (compatible; MSIE 5.5; Windows NT 5.0)");
    $ua->timeout(5);

    my $req = new HTTP::Request POST => $url;
    $req->content_type('application/x-www-form-urlencoded');
    $req->content(request_string($postvars));

    # Pass request to the user agent and get a response back
    my $res = $ua->request($req);
    if ($res->is_success || $res->is_redirect) {
        return;
    } else {
        push @$errors, "There was some error contacting the user's text messaging service via its web gateway. The message was most likely not sent.";
        return;
    }
}

sub send_mail
{
    my $self = shift;
    my $opt = shift;
    my $errors = shift;
    my $status;
    unless ($opt->{'to'}) {
        push @$errors, "To not defined in provider description.";
        return;
    }
    unless ($opt->{'body'}) {
        push @$errors, "Data not defined in provider description.";
        return;
    }
    my $msg =  new MIME::Lite ('From' => $opt->{'from'},
                               'To' => $opt->{'to'},
                               'Subject' => $opt->{'subject'},
                               'Data' => $opt->{'body'});
    if ($self->{'smtp'}) {
        $status = $msg->send_by_smtp($self->{'smtp'}, Timeout => 10);
    } else {
	$status = $msg->send_by_sendmail($self->{'sendmail'});
    }
    unless ($status) {
	push @$errors, "There may have been a problem sending your message through the email gateway.";
    }
    return $status;
}

sub request_string
{
    my ($vars) = shift;
    my $req = "";
    foreach (sort keys %{$vars})
    {
        my $val = uri_escape($vars->{$_},"\+\=\&");
        $val =~ s/ /+/g;
        $req .= "&" if $req;
        $req .= "$_=$val";
    }
    return $req;
}

1;
__END__
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

LJ::TextMessage - text message phones/pages using a variety of methods/services

=head1 SYNOPSIS

  use LJ::TextMessage;

  @providers = LJ::TextMessage::providers();
  foreach my $p (@providers) {
      my $info = LJ::TextMessage::provider_info($p);
      print "Name: $info->{'name'}\n";
      print "Notes: $info->{'notes'}\n";
      print "Limits: \n";
      foreach my $limit (qw(from msg tot)) {
	  print "  $limit: ", $info->{"${limit}limit"}, "\n";
      }
  }

  my $phone = new LJ::TextMessage { 
      'provider' => 'voicestream',
      'number' => '2045551212',
      'mailcommand' => '/usr/local/sbin/sendmail -t',
  };

  my @errors;
  $phone->send({ 'from' => 'Bob', 
		 'message' => "Hello!  This is my message!" },
	       \@errors);
  if (@errors) {
      ...
  } else {
      print "Message sent!\n";
  }

=head1 DESCRIPTION

The synopsis pretty much shows all the functionality that's available,
but details would be nice here.

=head1 BUGS

This library is highly volatile, as cellphone and pager providers can 
change the details of their web or email gateways at any time. In 
practice I haven't had to update this library much, but providers have 
no responsibility to tell me when they change their form field names
on their website, or change URLs*.

This documentation sucks rancid goats**.


*  - This will, of course, change once LJ has conquered the world.
** - No, not Frank.

=head1 AUTHOR

Written by:
  - Nicholas Tang (ntang) - <ntang@livejournal.com>
  - Aaron B. Russell (idigital) - <idigital@livejournal.com>
  - Eric Carr (iicarrii) - <iicarrii@aol.com>
  - Steven Kreuzer (22dip) - <skreuzer@mac.com>

Based on (mostly still, actually) code by:
  - Brad Fitzpatrick (bradfitz) - <bradfitz@bradfitz.com>

Additional code provided by:
  - Larry Gilbert (l2g) - <l2g@livejournal.com>
  - delphy
  - rory
  - Tony Sutton (tsutton) - <tsutton@livejournal.com>
  - Chris Bartow (christowang) - <chris@sysice.com>
  - Gavin Mogan (halkeye) - <halkeye@livejournal.com>
(if you've been forgotten, please give a holler!)

Information about text messaging gateways from many.

=cut
