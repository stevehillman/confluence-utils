# Library of routines to handle administrative API calls to Confluence

package Confluence;
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(Connect getUsers getUser getGroups addUser addGroup addUserToGroup removeUserFromGroup initAllUsersAndGroups getMembers existsInConfluence);

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

# Add a user to Confluence
sub addUser
{
	my $user = shift;
	if ($readonly)
	{
		print STDERR "READ-ONLY mode: Skipping add of user $user\n";
		$userExists{$user} = 1;
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
	push (@{$Users},$user);
	$userExists{$user} = 1;
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
