#!/usr/bin/perl
#

BML::register_block("SITEROOT", "S", FB::siteroot());
BML::register_block("REMOTE_ROOT", "S", FB::remote_root());
1;
