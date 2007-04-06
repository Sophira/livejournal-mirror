#!/usr/bin/perl
#

require "$ENV{'FBHOME'}/etc/fbconfig.pl";

BML::set_config("CookieDomain" => $FB::COOKIE_DOMAIN || $FB::DOMAIN);
BML::set_config("CookiePath"   => $FB::COOKIE_PATH || "/");

BML::register_hook("ml_getter", \&FB::Lang::get_text);

1;
