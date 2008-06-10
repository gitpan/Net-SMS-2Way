package Net::SMS::2Way;

use 5.0;
use strict;
use LWP::UserAgent;
use HTTP::Request;

require Exporter;

our @ISA = qw(Exporter);

our $VERSION = '0.04';

our $urls = {
	ZA => 'http://bulksms.2way.co.za:5567',
	UK => 'http://www.bulksms.co.uk:5567',
	ES => 'http://bulksms.com.es:5567',
	DE => 'http://bulksms.de:5567',
	US => 'http://usa.bulksms.com:5567',
	INT => 'http://bulksms.vsms.net:5567'
};

our $default_options = {
	country => 'ZA',
};

our @bulksms_send_options = qw(sender msg_class dca want_report routing_group source_id repliable strip_dup_recipients stop_dup_id send_time send_time_unixtime scheduling_description test_always_succeed test_always_fail allow_concat_text_sms oncat_text_sms_max_parts);

our $bulk_sms_send_defaults = {};

our @mandatory_options = qw(username password);

sub new {
	my $class = shift @_;
	my $ref = shift @_;
	my $error;
	
	$ref->{script} = $0;	# For logging purposes ?
	
	# Get settings from config file
	my $cfg_ref = _parse_config($ref->{config}) if $ref->{config};
	
	# Merge settings from config so that the config file settings are overwritten
	foreach my $key (keys(%$cfg_ref)) {
		if ($ref->{$key} eq '') {
			$ref->{$key} = $cfg_ref->{$key};
		}
	}
	
	# Add defaults
	foreach my $key (%$default_options) {
		if ($ref->{$key} eq '') {
			$ref->{$key} = $default_options->{$key};
		}
	}
	
	# Add BulkSMS defaults
	foreach my $key (%$bulk_sms_send_defaults) {
		if ($ref->{$key} eq '') {
			$ref->{$key} = $bulk_sms_send_defaults->{$key};
		}
	}
	
	#Check mandatory options
	foreach my $key (@mandatory_options) {
		if ($ref->{$key} eq '') {
			$error .= "Option '$key' does not have a value.\n";
		} 
	}
	
	# Is there a proxy ? 
	# TODO: Why am I setting the http_proxy evniroment variable ? - (pls fix this in v0.5)
	$ENV{http_proxy} = $ref->{http_proxy} if ($ref->{http_proxy} ne '');
	
	# Wich base URL to use ?
	$ref->{base_url} = $urls->{$ref->{country}};
	
	return 0 if $error;
	
	bless ($ref, $class);
}

sub send_sms {
	my $this = shift @_;
	my $message = shift @_;
	my @recipients = @_;
	
	#if (!$message) {
	#	$this->{error} = "Message is empty!\n";
	#	return 0;
	#}

	foreach my $number (@recipients) {
		$number =~ s/\D//g;			# strip all non-digits
		next if $number !~ /\d/;
		
		# TODO: This logic is incorrect. To be fixed in v0.5
		if ($this->{sa_numbers_only} > 0 && $number =~ /^(27|0[78])/) {
			# SA cell prefixes as per http://en.wikipedia.org/wiki/Telephone_numbers_in_South_Africa
			$number =~ s/^0(82|83|84|72|73|74|76|78|79)(\d+)/27$1$2/;
		} else {
			next;
		}
		
		if ($number eq '') {
			$this->{error} = "One of the recipient numbers is invalid: $number";
			return 0;
		}
		
	}
	
	my $args;
	
	# Extract all the BulkSMS options
	foreach my $option (@bulksms_send_options) {
		if (exists($this->{$option}) && $this->{$option} ne '') {
			$args->{$option} = $this->{$option};
		}
	}
	
	$args->{msisdn} = join(',', @recipients);
	$args->{message} = $message;
	
	my $url = $this->{base_url} . '/eapi/submission/send_sms/2/2.0';
	my @tmp = $this->http_post($url, $args) || ($this->send_to_log("WARN: Could not do http_post() for send_sms(): " . $this->{error}) && return 0);
	
	$this->send_to_log("Message sent to " . join(',', @recipients)) if $this->{verbose} > 0;
	
	#return pop(@tmp);
	return join("*", @tmp);
}

sub  get_credits {
	my $this = shift @_;
	
	my $url = $this->{base_url} . '/eapi/user/get_credits/1/1.1';
	my @tmp = $this->http_post($url);
	my ($status, $balance) = split /\|/, pop(@tmp) || ($this->send_to_log("WARN: Could not do http_post() for get_credits(): " . $this->{error}) && return -1);
	return $balance;
}

sub get_inbox {
	my $this = shift @_;
	my $last_retrieved_id = shift @_;
	
	my $url = $this->{base_url} . '/eapi/reception/get_inbox/1/1.0';
	my $args = {last_retrieved_id => $last_retrieved_id};
	my @tmp = $this->http_post($url, $args) || ($this->send_to_log("WARN: Could not do http_post() for get_inbox(): " . $this->{error}) && return 0);
	return @tmp;
}

sub get_report {
	my $this = shift @_;
	my $batch_id = shift @_;
  	my @report;
  	my $marker = 0;
  	
	if (!$batch_id) {
		$this->{error} = "batch_id was not specified\n";
		return 0;
	}
	
	my $url = $this->{base_url} .= '/eapi/status_reports/get_report/2/2.0?';
	
  	my $args = {batch_id => $batch_id, optional_fields => 'body,completed_time,created_time,credits,origin_address,source_id'};
  	
  	my @tmp = $this->http_post($url, $args) || ($this->send_to_log("WARN: Could not do http_post() for get_report(): " . $this->{error}) && return 0);
  	
  	foreach my $row (@tmp) {
  		if (/(\d+)\|([\w\s\d]+)$/) {
  			if ($1 != 0) {
  				$this->{error} = "$1: $2";
  				return 0;
  			} else {
  				$marker = 1;
  			}
  		}
  		
  		if ($marker) {
  			push (@report, $row);
  		}
  	}
  	
	return @report;
}

sub http_post {
	my $this = shift @_;
	my $url = shift @_;
	my $args = shift @_;
	
	my $timeout = $this->{timeout} || 30;
	
	my $uagent = LWP::UserAgent->new(timeout => $timeout);
  	my $request = HTTP::Request->new(POST => $url);
  	$request->content_type('application/x-www-form-urlencoded');
  	
  	my $content = 'username=' . $this->{username} . '&password=' . $this->{password};
  	
  	foreach my $arg (keys(%$args)) {
  		$content .= '&' . $arg . '=' . $args->{$arg};
  	}
  	
  	$request->content($content);
  	
	$this->send_to_log("INFO: URL=$url content=$content") if $this->{verbose} > 0;
	
  	my $response = $uagent->request($request);
	
	if ($response->is_success) {
		my @tmp = split /\n/, $response->as_string;
		return @tmp;
	} elsif ($response->is_error) {
		$this->{error} = $response->code . ':' . $response->message . "\n";
		return 0;
	} else {
		$this->{error} = $response->code . ':' . $response->message . ':' . $response->content . "\n";
		return 0;
	}
}

sub send_to_log {
	my $this = shift @_;
	my $message = shift @_;
	
	chomp($message);
	
	if ($this->{logfile} == -1) {
		return 1;
	}
	
	if ($this->{logfile} eq '') {
		$this->{logfile} = "$0.log";
	}
	
	open (LGFH, ">>".$this->{logfile}) || die "ERROR: Could not open " . $this->{logfile} . ": $!\n";
	
	print LGFH scalar(localtime()) . " - $message - $0\n";
	
	close (LGFH);
}

sub _parse_config {
	my $file = shift @_;
	my $cfg_ref;
	
	open (CFG, $file) || die "ERROR: Could not open $file: $!\n";
	
	while (<CFG>) {
		chomp;
		
		next if /^\s+$/;	# Ignore lines with just whitespace...
		next if /^$/;		# blank lines...
		next if /^#/;		# and lines that start with a comment.
		
		s/#.*//;			# Strip away all comments
		
		s/^\s+//;			# Remove leading...
		s/\s+$//;			# ...and trailing whitespace
		
		s/\s*=\s*/=/;		
		
		my ($var, $val) = split /=/;
		$cfg_ref->{$var} = $val;
	}
	
	close (CFG);
	
	return $cfg_ref;	
}

1;

__END__

=head1 NAME

Net::SMS::2Way - BulkSMS API

=head1 SYNOPSIS

  use Net::SMS::2Way;
  
  my $sms = Net::SMS::2Way->new({username => 'JBloggs', password => 's3kR3t'});
  
  my $sms = Net::SMS::2Way->new('config' => '/etc/SMS_Options.cfg');
  
  $sms->send_sms('Hello World!', '27821234567');
  
  $sms->send_sms('Hello World!', ['27821234567','27831234567','27841234567']);
  
  $sms->send_sms('Hello World!', @recipients);
  
  
=head1 DESCRIPTION
 
 This module allows you to send SMS text messages using the HTTP API that is available from BulkSMS 
 in South Africa (http://bulksms.2way.co.za) but can be configured to work with all the BulkSMS sites. 
 You can find a list of them at http://www.bulksms.com/selectwebsite.htm

=head2 The BulkSMS API

 This module implements only the HTTP API. You can read the HTTP API documentation at http://bulksms.2way.co.za/docs/eapi/
 
 Here is a list of the methods that have been implemented:
 
 send_sms
 get_inbox
 get_report
 get_credits
 
 Methods yet to be implemented:
 
 send_batch
 quote_sms
 public_add_member 
 public_remove_member

=head1 REQUIREMENTS

 1.) You need to register at one of the BulkSMS sites (http://www.bulksms.com/selectwebsite.htm) and have some credits available.

 2.) You will need the LWP modules installed. This module was tested with version 5.75
 
 3.) An internet connection.

=head1 METHODS

=head2 Constructor

 new() - The new() method is the constructor method.
 
 my $object = SMS->new($options)

 $options is a reference to a hash where the following keys can be used:

 config_file: The path to config file
 verbose: Write debug information to logfile
 logfile: The path to the logfile. Default is $0.log (To turn off logging (override verbose) set this option to -1)
 username: The username you registered with at http://bulksms.2way.co.za (or one of the other sites).
 password: The password you registered.
 http_proxy: Which web-proxy to use e.g. http://10.0.0.1:8080
 sa_numbers_only: Set this to 1 if you only want to send to South African mobile numbers.
 country: Which base url to use, derived from which regional BulkSMS site you want to use. 
 Can be one of ZA, UK, ES, DE, US, INT. default is ZA.

	ZA => South Africa (API Base URL: http://bulksms.2way.co.za:5567)
	UK => United Kingdom (API Base URL: http://www.bulksms.co.uk:5567)
	ES => Spain (API Base URL: http://bulksms.com.es:5567)
	DE => Germany (API Base URL: http://bulksms.de:5567)
	US => United States (API Base URL: http://usa.bulksms.com:5567)
	INT => International (API Base URL http://bulksms.vsms.net:5567)

 See the bulkSMS API for the meaning of the options below (http://bulksms.2way.co.za/docs/eapi/submission/send_sms/):

 sender 
 msg_class 
 dca 
 want_report 
 routing_group 
 source_id 
 repliable 
 strip_dup_recipients 
 stop_dup_id 
 send_time 
 send_time_unixtime 
 scheduling_description 
 test_always_succeed 
 test_always_fail 
 allow_concat_text_sms 
 oncat_text_sms_max_parts

 You can also put any of these (except for config_file) into a file with the format of:

 option = value

 The can make comments by using the # character.

 Once you've created the file you can create your object like this:

 my $object = SMS->new({config => '/etc/sms.cfg'});

 Example of the config file:

  # My config
  verbose = 1
  country = UK
  logfile = /usr/local/sms/sms.log
  sender = 27841234567
  username = johnny
  password = S3kR3t
  want_report = 1

 By default a log file will be created and failures or serious errors will be logged, no matter what the verbose option is set to. 
 If you do not want any logs at all, you must set logfile to -1

=head2 PROXY SUPPORT

 This module does support proxies. You can enable it 2 ways:
 
 1.) Populate the http_proxy enviroment variable e.g. 

  [user@server01 ~] $ export http_proxy=http://10.0.0.1:8080

 2.) Use the http_proxt attribute when creating the object e.g.
 
  $sms = SMS->new({http_proxy => 'http://10.0.0.1:8080'});
 
=head2 send_sms()
 
 send_sms(STRING, LIST) - The send_sms() method will connect and send a text message to the list of mobile numbers in the LIST.
 
 The second parametre can also be a single scalar i.e. a single number as a string.
 
 Return Values: 
 
  Returns 10 on success and 0 on failure with the reason for the failure in the error attribute. Eg.
 
  $retval = $sms->send_sms("This is a test", '0821234567');
  
  if (!$retval) {
  	print "There was an error!!!\n";
  	print "Error Message: " . $sms->{error} . "\n";
  }
  
  Return values that are neither 0 or 10, should be considered as signs of failure. See http://bulksms.2way.co.za/docs/eapi/submission/send_sms/ for a list of possible return values.
  
=head2 get_credits()
  
  get_credits() - Takes no arguments and will return the amounts of credits available.
  
  Return Values: A positive decimal number can be expected. This number is the number of credits available with the provider.
  
  On failure, a return value of -1 can be expected with the reason in $sms->{error}
  
=head2 get_report()

 get_report(INTEGER) - Takes 1 argument which is batch_id i.e. the id returned by a successful submission to send_sms(). It's fully explained at http://bulksms.2way.co.za/docs/eapi/status_reports/get_report/.
 
 Return Values: 0 on failure with the error message in $sms->{error}
 
 Returns an array on success. Each element has a string which has the format of:
 
 msisdn|status_code|body|completed_time|created_time|credits|origin_address|source_id

=head2 get_report_hash_ref()

 TODO: Finish documentation ASAP!!!

=head2 get_inbox()

 TODO: Finish documentation ASAP!!!
 
=head1 SUPPORT

 Bugs: You can email the author directly at lee@kode.co.za

 Commercial support is available.
 
=head1 THANKS

 Many thanks to the guys at BulkSMS for their helpful feedback and comments.
 
=head1 AUTHOR

 Lee Engel, lee@kode.co.za

 http://www.learnperl.org/

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007, 2008 by Lee S. Engel

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.
