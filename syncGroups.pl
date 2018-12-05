#!/usr/bin/perl
#
# Fetch all users and groups from Confluence. Look for new groups
# and if any are found, populate them with users from Amaint, adding
# new users to Confluence as necessary

# Find the lib directory above the location of myself. Should be the same directory I'm in
# This isn't necessary if these libs get installed in a standard perl lib location
use FindBin;
use lib "$FindBin::Bin/lib";
use Confluence;
use YAML qw(LoadFile);
use Rest;	# Amaint REST interace library (via rest.its.sfu.ca)
use Getopt::Std;

$groupsFile = "/tmp/syncgroups_status_file.tmp";
$configFile = "/opt/amaint/etc/confluence-config.yml";
$credentials = "/usr/local/credentials/confluence";

getopts('ad:f:hn');

# Main block
{
	if (defined($opt_h))
	{
		print "Usage: syncGroups.pl [-ahn][-d <n>][-f file]\n";
		print "  -d  <n> run debug level <n>. 1= verbose, 2=packet dumping verbose\n";
		print "  -a  sync all group memberships\n";
		print "  -f  path to config file (default: $configFile)\n";
		print "  -h  print this help\n";
		print "  -n  Calculate changes but don't carry them out (use with '-d' to see them)\n";
		print "\n";
		exit 0;
	}
	if (defined($opt_d))
	{
		$debug = $opt_d || 1;
		$Confluence::debug = $debug;
		use Data::Dumper;
	}
	$configFile = $opt_f if (defined($opt_f));
	$force = (defined($opt_a)) ? 1 : 0;
	$noaction = (defined($opt_n)) ? 1 : 0;
	$Confluence::readonly = $noaction if ($noaction);
	setup();
	initAllUsersAndGroups();
	@newGroups = findMissingGroups($force);
	foreach $group (@newGroups)
	{
		syncGroup($group);
	}
	disableAndEnableUsers();
	saveGroups();
	if (scalar(keys %changes))
	{
		print "Users with changes:\n";
		foreach (keys %changes)
		{
			print "$_: $changes{$_}\n";
		}
	}
}

# Load config, my list of groups from last run and login to Confluence
sub setup
{
	# Needed if we need to  make an SSL connection without verifying cert
	$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

	# load our snapshot of groups from file
	if (-f $groupsFile)
	{
		open(GF, $groupsFile) or die "Can't open $groupsFile for reading\n";
		@groups_snapshot = <GF>;
		close GF;

		foreach $gs (@groups_snapshot)
		{
			chomp $gs;
			$old_groups{$gs} = 1;
		}
	}

	if (! -f $configFile)
	{
		print "No YAML config file found at $configFile. Can't continue\n";
		exit 1;
	}

	print "Loading YAML config file from $configFile..\n" if $debug;
	($config) = LoadFile($configFile);
	print "Loaded:\n",Dumper($config) if $debug;

	# Set rest server token
	set_rest_token($config->{authtoken});

	# Load the group map for groups in Confluence that don't match their corresponding maillist name
	foreach $key (keys %{$config->{groupMap}})
	{
		$groupMap{$key} = $config->{groupMap}->{$key};
		print "Mapping $key to $groupMap{$key}\n" if $debug;
	}

	# Load in excluded users (users we won't remove from groups)
	foreach $user (@{$config->{excluded}})
	{
		$excluded{$user} = 1;
		print "Excluding $user from group removal\n" if $debug;
	}

	my $url = $config->{url};
	my $admin = $config->{username};
	print "Connecting to $url as $admin\n" if $debug;

	# Set up our connection to Confluence
	$result = Connect($url,$admin,$config->{password});

	if (!$result)
	{
		print STDERR "Unable to connect to Confluence. Exiting now\n";
		exit 1;
	}
}

sub saveGroups
{
	return if ($noaction);
	open(GF,">$groupsFile") or die "Can't save group status to $groupsFile\n";
	foreach $g (keys %old_groups)
	{
		print GF "$g\n";
	}
	close GF;
}

# Return list of groups that are in Confluence but not in our last run
# Pass in force=1 to return all Confluence groups (i.e sync all groups)
sub findMissingGroups
{
	my $force = shift;
	my @newGroups;
	@confGroups = getGroups();
	foreach my $g (@confGroups)
	{
		if ($force || !$old_groups{$g} )
		{
			print "Adding $g to new groups\n" if ($debug);
			push @newGroups,$g;
		}
	}
	return @newGroups;
}

# Sync a group's member from its SFU mail list to Confluence
# Users are automatically added to Confluence if they don't exist
sub syncGroup
{
	my $group = shift;
	$sfu_group = $group;
	my ($r1, $r2) = (0,0);
	if (defined($groupMap{$group}))
	{
		$sfu_group = $groupMap{$group};
	}
	my $newMembers = SFU_members_of_maillist($sfu_group);
	my @oldMembers = getMembers($group);

	if (!defined($newMembers))
	{
		# Probably a Confluence group that doesn't map to a mail list
		print "No such SFU Maillist: $sfu_group. Skipping\n" if ($debug);
		return 0;
	}

	my ($adds,$drops) = compare_arrays($newMembers,\@oldMembers);

	if ($debug)
	{
		print "\nCurrent $group members: ",join(",",sort(@oldMembers)),"\n";
		print "Amaint  $group members: ",join(",",sort(@{$newMembers})),"\n";
		print "Adding to group $group: ",join(",",sort(@{$adds})),"\n";
		print "Removing from group $group: ",join(",",sort(@{$drops})),"\n";
	}

	$r1 = doChanges($group,$adds,0) if (scalar(@{$adds}));
	$r2 = doChanges($group,$drops,1) if (scalar(@{$drops}));
	if (defined($r1) && defined($r2))
	{
		$old_groups{$group} = 1;
	}
	else
	{
		print STDERR "Failed to sync group $group. Not recording as done\n";
	}
	
}

# Add or remove a user to/from a group. Adds the user to Confluence
# if they're not there yet
sub doChanges
{
	my ($group,$users,$dropping) = @_;

	my $result = 0;
	foreach my $user (@{$users})
	{
		if ($dropping)
		{
			next if ($excluded{$user});
			$result = removeUserFromGroup($group,$user);
			$changes{$user} .= "-$group,";
		}
		else
		{
			if (!existsInConfluence($user))
			{
				my $info = info_for_computing_id($user);
				my ($j1,$j2,$sn,$fn,$gn) = split(/:::/,$info);
				$gn = $fn if ($gn eq "");
				$userHash = { name => $user,
					      fullname => "$gn $sn",
					      email => "$user\@sfu.ca",
					      url => ""
					    };
			}
			else
			{
				$userHash = { name => $user };
			}
			$result = addUserToGroup($group,$userHash);
			$changes{$user} .= "+$group,";
		}
	}
	return $result;
}	

# If a mandatory group is defined, make sure active users agrees with the membership of that group
sub disableAndEnableUsers
{
	return if (!defined($config->{mandatory_group}));
	if (!$force)
	{
		print "Not processing all groups so not processing disabled users\n" if $debug;
		return;
	}

	if (defined($config->{mandatory_excluded_group}))
	{
		my @excludedUsers = getMembers($config->{mandatory_excluded_group});
		foreach (@excludedUsers)
		{
			print "Excluded user $_ will be disabled in Confluence\n" if $debug;
			$mandatoryExcludes{$_} = 1;
		}
	}

	my @activeUsers = ();
	my @activeTempUsers = getMembers($config->{mandatory_group});
	foreach (@activeTempUsers)
	{
		if (!defined($mandatoryExcludes{$_}))
		{
			push @activeUsers,$_;
		}
	}
	my @allUsers = getUsers();
	my ($junk, $drops) = compare_arrays(\@activeUsers,\@allUsers);

	foreach my $u (@{$drops})
	{
		print "User $u not in mandatory group. Disabling account\n" if $debug;
		deactivateUser($u) if (!$noaction);
	}

	# Ensure that everyone in the group IS actually active
	foreach my $u (@activeUsers)
	{
		reactivateUser($u);
	}
}

# Compare two ararys, passed in as references
# Returns two array references - one with a list of elements only in array1, and one for array2
# If both returned array references are empty, the arrays are identical
sub compare_arrays
{
	($arr1, $arr2) = @_;
	my (@diff1, @diff2,%count);
	map $count{$_}++ , @{$arr1}, @{$arr2};

	@diff1 = grep $count{$_} == 1, @{$arr1};
	@diff2 = grep $count{$_} == 1, @{$arr2};

	return \@diff1, \@diff2;
}
	
