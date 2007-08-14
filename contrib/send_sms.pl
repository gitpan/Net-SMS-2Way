#!/usr/bin/perl

use Net::SMS::2Way;

my $sms = Net::SMS::2Way->new({config => '/usr/local/sms/sms.config'});

my $number = shift @ARGV;
my $message = shift @ARGV;

print "Number: $number\nMessage: $message\n";

my $retval = $sms->send_sms($message,$number);

print "Return: $retval\n";
