# Library of routines to handle administrative API calls to Confluence

package Confluence;
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(Connect getUsers getUser getGroups addUser addGroup addUserToGroup removeUserFromGroup initAllUsersAndGroups getMembers existsInConfluence deactivateUser reactivateUser);

use Frontier::Client;

$base = "/rpc/xmlrpc";

$debug = 0;

# Read-only. Set to 1 to block write operations
$readonly=0;

my ($Connectioa,$Auth,%group_members,$have_members,$Users,$Groups,%userExists);
$have_members=0;

sub Connect
{
	my ($server,$user,$pw) = @_; 

	$url = $server.$base;

	$Connection = Frontier::Client->new(url => $url, debug => ($debug > 1));

	eval {
		$Auth = $Connection->call("confluence2.login",$user,$pw);
	};
	if ($@)
	{
		print $@;
		return undef;
	}
	
	return $Auth;
}

sub getUsers
{
	my $users;
	if (!defined($Users))
	{
		eval {
			$Users = $Connection->call("confluence2.getActiveUsers",$Auth,Frontier::Client->boolean(1));
		};
		if ($@)
		{
			print $@;
			return undef;
		}
		foreach my $u (@{$Users}) { $userExists{$u} = 1; }
	}
	return @{$Users};
}

# Fetch all groups from Confluence
sub getGroups
{
	if (!defined($Groups))
	{
		eval {
			$Groups = $Connection->call("confluence2.getGroups",$Auth);
		};
		if ($@)
		{
			print $@;
			return undef;
		}
	}
	return @{$Groups};
}

# deactivate a user
sub deactivateUser
{
	my $user = shift;
	if ($readonly)
	{
		print STDERR "READ-ONLY mode: Won't disable  user $user\n";
		delete($userExists{$user});
		return 1;
	}

	my $result;
	eval {
		$result = $Connection->call("confluence2.deactivateUser",$Auth,$user);
	};
	if ($@)
	{
		# We'll get an error if the user doesn't exist OR is already deactivated
		# so this *may* not matter. Only log it if user doesn't exist
		if ($@ =~ /User has already been deactivated/)
		{
			return 1;
		}
		print $@;
		return undef;
	}

	delete($userExists{$user});
	return $result;
}

# reactivate an existing disabled account
# Assumes the user already exists and catches an error if not
sub reactivateUser
{
	my $user = shift;
	if ($readonly)
	{
		print STDERR "READ-ONLY mode: Won't re-enable user $user\n";
		$userExists{$user} = 1;
		return 1;
	}

	my $result;
	eval {
		$result = $Connection->call("confluence2.reactivateUser",$Auth,$user);
	};
	if ($@)
	{
		# We'll get an error if the user doesn't exist OR is already active
		# so this *may* not matter. Only log it if user doesn't exist
		if ($@ =~ /User is already active/)
		{
			return 1;
		}
		print $@;
		return undef;
	}
	return $result;
}

	
# check if a user is active. 1=yes, 0=no, undef=doesn't exist
sub isActiveUser
{
	my $user = shift;
	my $result;
	eval {
		$result = $Connection->call("confluence2.isActiveUser",$Auth,$user);
	};
	# We get an error if the user doesn't exist, so if no error, they already exist
	if ($@)
	{
		print "isActiveUser: User $user doesn't exist: $@\n" if $debug;
		return undef;
	}
	return $result;
}

# Add a user to Confluence
sub addUser
{
	my $user = shift;
	my $username = $user->{name};

	# First check if they're already there but deactivated
	my $result = isActiveUser($username);

	# We get an undef if the user doesn't exist, so if no error, they already exist
	if (defined($result))
	{
		print "addUser: $username already exists\n" if $debug;
		if (!$result)
		{
			# User isn't active so reactivate
			if (reactivateUser($username))
			{
				print "addUser: Reactivated user $username\n" if $debug;
				# success, so add to our arrays
				push (@{$Users},$username);
				$userExists{$username} = 1;
				return 1;
			}
			# Failed to reactivate user?!
			print STDERR "Unable to reactivate user $username\n";
			return undef;
		}
		return 0;
	}
		
	if ($readonly)
	{
		print STDERR "READ-ONLY mode: Skipping add of user $username\n";
		$userExists{$username} = 1;
		return 1;
	}
	initAllUsersAndGroups();
	eval {
		$Connection->call("confluence2.addUser",$Auth,$user,genRandPW());
	};
	if ($@)
	{
		print $@;
		return undef;
	}
	push (@{$Users},$username);
	$userExists{$username} = 1;
}

# Add a user to a group
sub addUserToGroup
{
	my ($group, $userHash) = @_;
	my $member = $userHash->{name};
	addUser($userHash) if (!$userExists{$member});
	if (!$readonly) {
		eval {
			$Connection->call("confluence2.addUserToGroup",$Auth,$member,$group);
		};
		if ($@)
		{
			print $@;
			return undef;
		}
	}
	# Update our local copy of Confluence's group memberships
	initAllUsersAndGroups();
	push (@{$group_members{$group}},$member);
	return 1;
}

# Remove a user from a group
sub removeUserFromGroup
{
	my ($group, $member) = @_;
	if (!$readonly)
	{
		eval {
			$Connection->call("confluence2.removeUserFromGroup",$Auth,$member,$group);
		};
		if ($@)
		{
			print $@;
			return undef;
		}
	}
	# Update our local copy of Confluence's group memberships
	initAllUsersAndGroups();
	my $c=0;
	foreach my $mem (@{$group_members{$group}})
	{
		# Found the member?
		if ($mem eq $member)
		{
			# Splice them out of the array
			splice(@{$group_members{$group}},$c,1);
			last;
		}
		# Nope.. keep searching
		$c++;
	}
	return 1;
}

# populate users, groups, and membership map
# Confluence has no way to get the members of a group. Our only
# option is to fetch all users, fetch all groups, iterate through all users
# to fetch their group memberships and build a hash of arrays for the result
sub initAllUsersAndGroups
{
	if (!$have_members)
	{
		getUsers();
		getGroups();
		foreach $g (@{$Groups})
		{
			$group_members{$g} = [];
		}

		foreach $u (@{$Users})
		{
			eval {
				$u_groups = $Connection->call("confluence2.getUserGroups",$Auth,$u);
			};
			if ($@)
			{
				print $@;
				return undef;
			}
			foreach $ug (@{$u_groups})
			{
				push (@{$group_members{$ug}},$u);
			}
		}
		$have_members=1;
	}
}

sub getMembers
{
	my $group = shift;
	initAllUsersAndGroups if (!$have_members);
	return @{$group_members{$group}};
}

sub genRandPW
{
	my @chars = ("A".."Z","a".."z","0".."9");
	my $pw;
	$pw .= $chars[rand @chars] for 1..20;
	return $pw;
}

sub existsInConfluence
{
	$user = shift;
	return $userExists{$user};
}
1;
