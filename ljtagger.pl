#!/usr/bin/perl -w
#
# LJ Tagger by th1rtyf0ur (c) 2005
# Searches an offline XML backup of your journal entries for a specified
# pattern, and if matched, prompts you whether to add the specified tag to
# that entry.  Useful for tagging lots of entries based on keywords.
#
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation; either version 2 of the License, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 51
# Franklin St, Fifth Floor, Boston, MA  02110-1301  USA, or visit
# http://www.gnu.org/licenses/


# load required libs (yeah, there's a lot)
use strict;
#use encoding 'utf8';
use Data::Dumper;
use Date::Parse;
use Digest::MD5 qw(md5_hex);
use Getopt::Mixed "nextOption";
use HTTP::Cookies;
use HTTP::Headers;
use Term::ANSIColor ':constants';
use Term::ReadKey;
use XML::Simple;
use XMLRPC::Lite;

my $USER = undef;
my $updated = 0;
my $format = undef;
$USER->{'configfile'} = "$ENV{'HOME'}/.ljtagger";
$USER->{'cookiefile'} = "$ENV{'HOME'}/.ljtagger_cookies";
my $LJ_DOMAIN = '.livejournal.com';
$| = 1;	# autoflush output after every 'print'

# get command-line options
my $opt = Getopt::Mixed::init(
	"u=s username>u user>u "
	. "p=s password>p pw>p "
	. "e=s expression>e egrep>e pattern>e "
	. "t=s tag>t "
	. "c=s configfile>c "
	. "k=s cookiefile>k "
	. "i ignorecase>i "
	. "v verbose>v "
	. "d debug>d "
	. "w whole_words>w "
	. "x expire_session>x "
	. "h help>h "
);
$Getopt::Mixed::badOption = \&usage;
while (my ($option, $value) = nextOption()) {
	if		($option eq 'i') { $USER->{'ignorecase'}	= 1; }
	elsif	($option eq 'v') { $USER->{'VERBOSE'}		= 1; }
	elsif	($option eq 'd') { $USER->{'DEBUG'}		= 1; }
	elsif	($option eq 'w') { $USER->{'whole_words'}	= 1; }
	elsif	($option eq 'c') { $USER->{'configfile'}	= $value; }
	elsif	($option eq 'k') { $USER->{'cookiefile'}	= $value; }
	elsif	($option eq 'u') { $USER->{'username'}		= $value; }
	elsif	($option eq 'p') { $USER->{'password'}		= $value; }
	elsif	($option eq 'e') { $USER->{'egrep'}			= $value; }
	elsif	($option eq 't') { $USER->{'tag'}			= $value; }
	elsif	($option eq 'x') { $USER->{'expire_session'}	= 1; }
	elsif	($option eq 'h') { &usage; }
}
Getopt::Mixed::cleanup();

# read config file
if (-f $USER->{'configfile'}) {
	print "Reading conf file $USER->{'configfile'}\n" if ($USER->{'VERBOSE'});
	open(CONF, $USER->{'configfile'});
	LINE:
	while (<CONF>) {
		chomp;
		next if $_ =~ /^\s*#/;
		if ($_ =~ m/([\w-]+)\s+(?:[=:]\s*)?(\S+)/) {
			my ($a, $b) = ($1, $2);
			# Assign the user vars from the config file, unless already set via cmd line args
			if ($a =~ /^(?:username|password|ignorecase|verbose|debug|whole_words|cookiefile)$/) {
				if (!defined($USER->{$a})) {
					$USER->{$a} = "$b";
				}
			} else {
				print "Ignoring illegal config line $_\n";
			}
		}
	}
	close CONF;
}

# setup transport
my $cookie_jar = HTTP::Cookies->new(
		file => $USER->{'cookiefile'},
		autosave => 1,);
my $headers = HTTP::Headers->new('X-LJ-Auth' => 'cookie');
my $xmlrpc = new XMLRPC::Lite;
$xmlrpc->proxy("http://www.livejournal.com/interface/xmlrpc", 
	cookie_jar		=> $cookie_jar,
	default_headers	=> $headers,
	agent			=> "LJ Tagger (SOAP::Lite/Perl/$SOAP::Lite::VERSION)",
);

# check for required options
if ($USER->{'expire_session'}) {
	&expire_session;
}
unless (defined($USER->{'username'}) && defined($USER->{'password'})) {
	print "You must specify a username and password.\n\n";
	&usage;
}
unless (defined($USER->{'egrep'}) && defined($USER->{'tag'})) {
	print "You must specify a regexp pattern and a tag.\n\n";
	&usage;
}
if ($#ARGV < 0) {
	print "You must specify 1 or more archive files to search.\n\n";
	&usage;
}
(my @files) = @ARGV;
$USER->{'egrep'} =~ s/\((?!\?)/(?:/g;
if (defined($USER->{'whole_words'})) {
	$USER->{'egrep'} =~ s/.+/\\b$&\\b/;
}
if (defined($USER->{'ignorecase'})) {
	$USER->{'egrep'} =~ s/.+/(?i:$&)/;
}

# see if there's already a session cookie
if ($cookie_jar->as_string =~ /ljsession=.+?expires="(.+?)"/m) {
	my $expires = $1;
	if (str2time($expires) > time()) {
		$USER->{'logged_in'} = 1; 
		print "Already logged in via cookie file\n" if $USER->{'VERBOSE'};
		print "Cookie expires $expires\n" if $USER->{'VERBOSE'};
	}
}

# loop through input files
foreach my $file (@files) {
	print "Reading file $file...\n" if ($USER->{'VERBOSE'});
	my $contents = undef;
	open FILE, $file;
	while (<FILE>) { $contents .= $_; }
	close FILE;
	my $data = XMLin($contents, 'ForceArray' => ['entry','day']);
	if ($data->{'day'}) {	# logjam's export format
		print "Logjam export format detected.\n\n" if ($USER->{'VERBOSE'});
		$format = 'logjam';
		foreach my $day (@{$data->{'day'}}) {
			foreach my $entry (@{$day->{'entry'}}) {
				$updated = 0;
				grep_entry($entry);
			}
		}
	} elsif ($data->{'entry'}) {	# LJ's export.bml format
		print "LJ Export format detected.\n\n" if ($USER->{'VERBOSE'});
		$format = 'lj';
		foreach my $entry (@{$data->{'entry'}}) {
			$entry->{'time'} = $entry->{'eventtime'};
			$updated = 0;
			grep_entry($entry);
		}
	}
}

# grep each entry for the specified regexp pattern
sub grep_entry {
	my ($entry) = @_;
	# loop through each matching paragraph
	while ($entry->{'event'} =~ m/^.*($USER->{'egrep'}).*$/mg) {
		# don't update the record if we've already done so (i.e. in a previous paragraph)
		return if $updated;
		print BLUE, "In entry ", CYAN, "'$entry->{'subject'}' ", BLUE, "on $entry->{'time'}", RESET, ":\n";
		print "Pattern ", YELLOW, "/$USER->{'egrep'}/", RESET, " matched at:\n";
		my @matches = split(/($USER->{'egrep'})/, $&);
		foreach my $bit (@matches) {
			if ($bit =~ /($USER->{'egrep'})/) {
				print BOLD, RED, $bit, RESET;
			} else {
				print $bit;
			}
		}
		print	"\n\nAdd tag '$USER->{'tag'}'? (y/n/(s)kip this entry/q) ";
		my $key;
		ReadMode 3;
		do { $key = ReadKey(0); } until (defined($key) && $key =~ /[YyNnQqSs]/);
		ReadMode 0;
		if ($key =~ /[Qq]/) {
			print "\nExiting.\n";
			exit 0;
		}
		print "$key\n\n";
		if ($key =~ /[Yy]/) {
			grab_tags($entry);
		} elsif ($key =~ /[Ss]/) {
			$updated = 1;	# trick loop into thinking this entry is done, so it moves on to the next entry
		}
	}
}

# grab the tags (and the rest of the entry) from the server
sub grab_tags {
	my ($entry) = @_;
	unless ($USER->{'logged_in'}) { &login; }
	if ($format eq 'lj') { $entry->{'itemid'} = &get_lj_id($entry); }
	# Grab the original entry's tags, since they're not in the export file
	print "Grabbing entry $entry->{'itemid'}...\n" if ($USER->{'VERBOSE'});
	my $original_entry = xmlrpc_call('LJ.XMLRPC.getevents', {
		'username'		=> $USER->{'username'},
		'auth_method'	=> 'cookie',
		'selecttype'	=>	'one',
		'itemid'		=> $entry->{'itemid'},
		'ver'			=> '1',
	});
	my $this = $original_entry->{'events'}[0];
	if ($this->{'props'}->{'taglist'}) {
		my @tags = split(', ', $this->{'props'}->{'taglist'});
		print "Entry has taglist '" . join (', ', sort(@tags)) . "'\n" if ($USER->{'VERBOSE'});
		if (grep(/^$USER->{'tag'}$/, @tags)) {
			print "Tag $USER->{'tag'} is already in this entry, skipping.\n\n";
			$updated = 1;
			return;
		} else {
			push(@tags, $USER->{'tag'});
			$this->{'props'}->{'taglist'} = join(', ', sort(@tags));
			print "New taglist is '$this->{'props'}->{'taglist'}'\n\n" if ($USER->{'VERBOSE'});
		}
	} else {
		print "Entry currently has no tags, adding '$USER->{'tag'}'\n\n" if ($USER->{'VERBOSE'});
		$this->{'props'}->{'taglist'} = "$USER->{'tag'}";
	}
	&update_entry($this);
}

# update the entry
sub update_entry {
	my ($this) = @_;
	$this->{'props'}->{'revnum'}++;
	print "Updating entry...\n";
	my $update = xmlrpc_call('LJ.XMLRPC.editevent', {
		'username'		=> $USER->{'username'},
		'auth_method'	=> 'cookie',
		'mode'			=> 'editevent',
		'ver'			=> '1',
		%{$this}
	});
	print "Update results: " . Dumper($update) if ($USER->{'DEBUG'});
	$updated = 1;
	print "Done!\n";
}

# handle the XMLRPC calls
sub xmlrpc_call {
	my ($method, $req) = @_;
	my $res = $xmlrpc->call($method, $req);
	if ($res->fault) {
		print STDERR "Error:\n".
		" String: " . $res->faultstring . "\n" .
		" Code: " . $res->faultcode . "\n";
		exit 1;
	}
	return $res->result;
}

# log in & get a session cookie
sub login {
	print "Logging in...\n";
	print "Getting login challenge...\n" if ($USER->{'DEBUG'});
	my $get_chal = xmlrpc_call("LJ.XMLRPC.getchallenge");
	my $chal = $get_chal->{'challenge'};
	print "Got challenge $chal\n" if ($USER->{'DEBUG'});
	my $response = md5_hex($chal . md5_hex($USER->{'password'}));
	my $login_result = xmlrpc_call('LJ.XMLRPC.sessiongenerate', {
		'username'		=> $USER->{'username'},
		'auth_method'	=> 'challenge',
		'auth_challenge'=> $chal,
		'auth_response' => $response,
		'ver'			=> '1',
	});
	$USER->{'logged_in'} = 1;
	$cookie_jar->set_cookie(0,'ljsession',$login_result->{'ljsession'},
		'/', $LJ_DOMAIN,80,1,0,3600);
	print "Session cookie is $login_result->{'ljsession'}\n" if ($USER->{'VERBOSE'});
	print "Logged in.\n" if ($USER->{'VERBOSE'});
	print "Server response was " . Dumper($login_result) if ($USER->{'DEBUG'});
}

# grab the correct itemid if using LJ's export format (which exports the URL id)
sub get_lj_id {
	print "Figuring out the right itemid...\n" if ($USER->{'VERBOSE'});
	my ($entry) = @_;
	my ($year, $month, $day, $time) = split(/[- ]/, $entry->{'eventtime'});
	print "Grabbing events from $year-$month-$day\n" if ($USER->{'VERBOSE'});
	my $results = xmlrpc_call('LJ.XMLRPC.getevents', {
		'username'		=> $USER->{'username'},
		'auth_method'	=> 'cookie',
		'selecttype'	=>	'day',
		'year'			=> $year,
		'month'			=> $month,
		'day'			=> $day,
		'prefersubject'	=> '1',
	});
	foreach my $post (@{$results->{'events'}}) {
		print "Entry '$post->{'event'}' has id $post->{'itemid'}\n" if ($USER->{'VERBOSE'});
		if ($post->{'event'} eq $entry->{'subject'}) {
			print "We want id $post->{'itemid'}.\n" if ($USER->{'VERBOSE'});
			return $post->{'itemid'};
		}
	}
}

# Expire the session cookie on the server & clear it from the cookiefile
sub expire_session {
	if ($cookie_jar->as_string =~ /ljsession="(.+?)"/m) {
		my ($junk, $name, $id, $session) = split(/:/, $1);
		print "Current session id for $name is $id\n" if ($USER->{'DEBUG'});
		my $expire_result = xmlrpc_call('LJ.XMLRPC.sessionexpire', {
			'username'		=> $USER->{'username'},
			'auth_method'	=> 'cookie',
			'expire'		=> [$id],
			'ver'			=> '1',
		});
		$cookie_jar->clear($LJ_DOMAIN, "/", "ljsession");
		print "Session expired\n";
		exit 0;
	} else {
		print "Don't have a session to expire!\n";
		exit 1;
	}
}

# print Usage & exit
sub usage {
	my ($pos, $option, $string) = @_;
	my @path = split('/', $0);
	my $progname = $path[$#path];
	if ($option) {
		print "Invalid option: $option\n\n";
	}
	print <<EOF;
Usage: $progname [options] [file(s)]
i.e. $progname -u user -p pass -i -e 'watch|imdb.com/' -t movies *.xml
$progname -x

Options:
    -u --username=USERNAME  LiveJournal Username (required)
    -p --password=PASSWORD  LiveJournal Password (required)
    -e --expression=PAT     Regular Expression to match (required)
    -t --tag=TAG            LJ tag to add to matching entries (required)
    -i --ignorecase         Ignore case in pattern
    -w --whole_words        Pattern only matches whole words
    -c --configfile=FILE    Specify a config file (default ~/.ljtagger)
    -k --cookiefile=FILE    Specify a cookie file (default ~/.ljtagger_cookies)
    -x --expire_session     Expire your session cookie
    -d --debug              Debug mode (shows LJ XMLRPC server response)
    -v --verbose            Verbose mode
    -h --help               Display this help text

LJ Tagger will search your locally archived LJ contents for a pattern you
specify, and if it matches, will prompt if you want to add the specified tag to
that LJ Entry.

PAT is a Perl regular expression.  Options username, password, ignorecase,
verbose, whole-words, and cookie-file may be specified in a config file.
Config file syntax is 'option = value'.  Lines starting with a '#' and extra
whitespace are ignored.  For boolean options, set 'value' to e.g. '1' or '0'.

[file(s)] must be XML exports of your LiveJournal content.  Currently
LiveJournal's export.bml format and Logjam's 'offline copy' formats are
supported.

EOF
	exit 1;
}

# vim: ts=4 sw=4
