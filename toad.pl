#!/usr/bin/perl
#
# Copyright (c) 2016 Antoine Jacoutot <ajacoutot@openbsd.org>
# Copyright (c) 2013, 2014, 2015, 2016 M:tier Ltd.
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# Author: Antoine Jacoutot <antoine@mtier.org>

use strict;
use warnings;

use File::Path qw(make_path);
use Net::DBus;
use User::pwent qw(:FIELDS);

if ( $< != 0 ) {
	print "need root privileges\n";
	exit (1);
}

sub usage {
	print "usage: $0 attach|detach devclass device\n";
	exit (1);
}

if (@ARGV < 3) { usage (); }

my ($action, $devclass, $devname) = @ARGV;
my ($login, $uid, $gid) = get_active_user_info ();
my $mounttop = '/run';
my $mountbase = "$mounttop/media";
my $mountopts = 'nodev,nosuid,noexec';
my $devtype;
my $devmax;

sub broom_sweep {
	my $is_busy;
	my @tryrm;
	my @cfd;

	if (-d $mountbase && $mountbase ne '/') {
		opendir (TOP, $mountbase) or return;
		while (my $file = readdir (TOP)) {
			next if ($file =~ m/^\./);
			next unless (-d "$mountbase/$file");
			push @cfd, "$mountbase/$file";
			opendir (SUB, "$mountbase/$file") or die "cannot open $mountbase/$file: $!";
			while (my $subfile = readdir (SUB)) {
				next if ($subfile =~ m/^\./);
				next unless (-d "$mountbase/$file/$subfile");
				if ((stat ("$mountbase/$file/$subfile"))[1] != 2) {
					push @cfd, "$mountbase/$file/$subfile";
				} else {
					# subdir is mounted, so don't try to
					# remove parent
					$is_busy = 1;
					my $i = 0;
					my $c = scalar @cfd;
					while ($cfd[$i]) {
						$i++ until $cfd[$i] eq "$mountbase/$file" or $i==$c;
						splice (@cfd, $i, 1);
					}
				}
			}
			closedir (SUB);
		}
		closedir (TOP);

		@tryrm = reverse sort @cfd;

		foreach my $rmfile (@tryrm) {
			rmdir ($rmfile);
		}

		# nothing is mounted, so remove the hierarchy
		unless ($is_busy) {
			rmdir ($mountbase);
			rmdir ($mounttop);
		}
	}
}

sub create_hier {
	make_path ($mountbase, {owner=>0, group=>0, mode=>0755});
	chown 0, 0, $mounttop, $mountbase;
	chmod 0755, $mounttop, $mountbase;
}

sub create_mount_point {
	my $devnum = shift;

	create_hier ();

	make_path ("$mountbase/$login/$devtype$devnum", {owner=>$uid, group=>$gid, mode=>0700});
	chown $uid, $gid, "$mountbase/$login", "$mountbase/$login/$devtype$devnum";
	chmod 0700, "$mountbase/$login", "$mountbase/$login/$devtype$devnum";
}

sub create_pkrule {
	my($devname, $devnum, $part) = @_;
	my $pkfile = "/usr/local/share/polkit-1/actions/org.freedesktop.policykit.toad.pkexec.umount.$devname$part.policy";

	unless(open PKFILE, '>'.$pkfile) {
		die "Unable to create $pkfile\n";
	}

	print PKFILE "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
	print PKFILE "<!DOCTYPE policyconfig PUBLIC\n";
	print PKFILE " \"-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN\"\n";
	print PKFILE " \"http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd\">\n";
	print PKFILE "<policyconfig>\n";
	print PKFILE "  <action id=\"org.freedesktop.policykit.toad.pkexec.umount.$devname$part\">\n";
	print PKFILE "    <defaults>\n";
	print PKFILE "        <allow_any>no</allow_any>\n";
	print PKFILE "        <allow_inactive>no</allow_inactive>\n";
	print PKFILE "        <allow_active>yes</allow_active>\n";
	print PKFILE "    </defaults>\n";
	print PKFILE "    <annotate key=\"org.freedesktop.policykit.exec.path\">/sbin/umount</annotate>\n";
	print PKFILE "    <annotate key=\"org.freedesktop.policykit.exec.argv1\">/run/media/$login/$devtype$devnum</annotate>\n";
	print PKFILE "  </action>\n";
	print PKFILE "</policyconfig>\n";

	close PKFILE;
}

sub fw_update {
	require OpenBSD::FwUpdate;

	# remove "attach" and "devclass" from args to unconfuse pkg_add(1)
	shift(@ARGV);
	shift(@ARGV);

	my $driver = ${ARGV[0]};
	my $fw = OpenBSD::FwUpdate::State->new(@ARGV);
	OpenBSD::FwUpdate->find_machine_drivers($fw);
	OpenBSD::FwUpdate->find_installed_drivers($fw);

	if ($fw->{all_drivers}{$driver}) {
		if (!$fw->is_installed($driver)) {
			if (OpenBSD::FwUpdate->parse_and_run == 0) {
				print "Installed firmware package for $driver(4).\n";
			} else {
				print "Failed to install firmware package for $driver(4).\n";
			}
		}
	} else {
		print "Unknown driver $driver(4).\n";
	}
}

sub get_active_user_info {
	my $system_bus = Net::DBus->system;
	my $ck_service = $system_bus->get_service ('org.freedesktop.ConsoleKit');
	my $ck_manager = $ck_service->get_object ('/org/freedesktop/ConsoleKit/Manager');

	for my $session_id (@{$ck_manager->GetSessions ()}) {
		my $ck_session = $ck_service->get_object ($session_id);
		next unless $ck_session->IsActive ();

		my $uid = $ck_session->GetUnixUser ();
		getpwuid ($uid) || die "no $uid user: $!";
		next unless $uid >= 1000;

		my $gid = $pw_gid;
		my $login = $pw_name;

		return ($login, $uid, $gid);
	}
}

sub get_mount_point {
	my $devnum;

	for ($devnum = 0; $devnum < $devmax; $devnum = $devnum + 1) {
		my $mounts = `/sbin/mount | /usr/bin/grep $mountbase/$login/$devtype$devnum`;
		next unless ($mounts eq '');
		last;
	}
	return ($devnum);
}

sub get_parts {
	my @parts;
	my @supportedfs = ('MSDOS', 'NTFS', '4.2BSD', 'ext2fs', 'ISO9660', 'UDF');

	foreach my $fs (@supportedfs) {
		my $fsmatch = `/sbin/disklabel $devname 2>/dev/null | /usr/bin/grep " $fs "`;
		while ($fsmatch =~ /([^\n]+)\n?/g) {
			my @part = split /:/, $1;
			push (@parts, $part[0]);
		}
	}

	return (@parts);
}

sub mount_device {
	my @allparts;
	my @parts;

	# ignore softraid(4) crypto device attachment
	my $sr_crypto = `/sbin/disklabel $devname 2>/dev/null | grep "SR CRYPTO"`;
	if ($sr_crypto) {
		return (0);
	}

	if ($devtype eq 'cd') {
		@parts = 'a';
	} else {
		@allparts = get_parts ();
		foreach my $part (@allparts) {
			if ($part !~ 'c$') {
				push @parts, $part;
			}
		}
	}

	unless (@parts) {
		print "no supported partition found on device $devname\n";
		return (0);
	}

	foreach my $part (@parts) {
		$part =~ s/^\s+//;
		my $device = "/dev/$devname$part";
		my $devnum = get_mount_point ();
		my $dirty = 0;

		create_mount_point ($devnum);
		create_pkrule ($devname, $devnum, $part);

		my $mountrw = `/sbin/mount -o $mountopts $device $mountbase/$login/$devtype$devnum 2>&1`;
		if (length ($mountrw) != 0) {
			system ("/sbin/mount -o $mountopts,ro $device $mountbase/$login/$devtype$devnum");
			unless ($? == 0) {
				print "Cannot mount $device!\n\n$mountrw\n";
				broom_sweep ();
				next;
			}
			unless ($mountrw =~ /Permission denied/) {
				$dirty = 1;
			}
		}
		if ($dirty == 1) {
			print "Filesystem on device $device is not clean and
cannot be mounted read-write, mounting in read-only mode! fsck(8) may be used
for consistency check and repair.\n";
		}
	}
}

if ($devclass == 2) {
	$devtype = 'usb';
	$devmax = 10;
} elsif ($devclass == 3) {
	$devtype = 'net';
} elsif ($devclass == 9) {
	$devtype = 'cd';
	$devmax = 2;
} else {
	print "device type not supported\n";
	exit (1);
}

if ($action eq 'attach') {
	if (!defined($login) || !defined($uid) || !defined($gid)) {
		print "ConsoleKit: user does not own the active session\n";
		exit (1);
	}
	if ($devtype eq 'cd' || $devtype eq 'usb') { mount_device (); }
	elsif ($devtype eq 'net') { fw_update (); }
} elsif ($action eq 'detach') {
	if ($devtype eq 'cd' || $devtype eq 'usb') { broom_sweep (); }
} else { usage (); }
