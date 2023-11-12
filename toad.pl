#!/usr/bin/perl
#
# Copyright (c) 2016, 2019, 2020 Antoine Jacoutot <ajacoutot@openbsd.org>
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

use v5.36;
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
my ($login, $uid, $gid, $display, $home) = get_active_user_info ();
my $dbus_session_bus_address = get_dbus_session_bus_address ();
my $mounttop = '/run';
my $mountbase = "$mounttop/media";
my $mountopts = 'nodev,nosuid,noexec';
my $devtype;
my $devmax;
my $pkrulebase = "/etc/polkit-1/rules.d/45-toad-$login";

sub broom_sweep {
	my $is_busy;
	my @tryrm;
	my @cfd;

	unlink glob "$pkrulebase-$devname?.rules";

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
	my $pkrule = "$pkrulebase-$devname$part.rules";

	unless(open PKRULE, '>'.$pkrule) {
		die "Unable to create $pkrule\n";
	}

	print PKRULE "polkit.addRule(function(action, subject) {\n";
	print PKRULE "  if (action.id == \"org.freedesktop.policykit.exec\" &&\n";
	print PKRULE "    action.lookup(\"program\") == \"/sbin/umount\" &&\n";
	print PKRULE "    action.lookup(\"command_line\") == \"/sbin/umount $mountbase/$login/$devtype$devnum\") {\n";
	print PKRULE "    if (subject.local && subject.active && subject.user == \"$login\") {\n";
	print PKRULE "      return polkit.Result.YES;\n";
	print PKRULE "    }\n";
	print PKRULE "  }\n";
	print PKRULE "});\n";

	if ($devtype eq 'cd') {
		print PKRULE "polkit.addRule(function(action, subject) {\n";
		print PKRULE "  if (action.id == \"org.freedesktop.policykit.exec\" &&\n";
		print PKRULE "    action.lookup(\"program\") == \"/bin/eject\" &&\n";
		print PKRULE "    action.lookup(\"command_line\") == \"/bin/eject /dev/$devname$part\") {\n";
		print PKRULE "    if (subject.local && subject.active && subject.user == \"$login\") {\n";
		print PKRULE "      return polkit.Result.YES;\n";
		print PKRULE "    }\n";
		print PKRULE "  }\n";
		print PKRULE "});\n";
	}

	close PKRULE;
}

sub gdbus_call {
	my($action, $args) = @_;
	my $cmd = "gdbus call -e";

	my $pid = fork ();
	if (!defined ($pid)) {
		die "could not fork: $!";
	} elsif ($pid) {
		if (waitpid ($pid, 0) > 0) {
			if ($? >> 8 ne 0) {
				return (1);
			}
		}
	} else {
		$( = $) = "$gid $gid";
		$< = $> = $uid;

		$ENV{"DISPLAY"} = $display;
		$ENV{"HOME"} = $home;
		$ENV{"DBUS_SESSION_BUS_ADDRESS"} = $dbus_session_bus_address;

		if ($action eq 'notify') {
			print ("$args\n");
			if (defined ($dbus_session_bus_address)) {
				$cmd .= " -d org.freedesktop.Notifications";
				$cmd .= " -o /org/freedesktop/Notifications";
				$cmd .= " -m org.freedesktop.Notifications.Notify";
				$cmd .= " toad 42 drive-harddisk-usb";
				$cmd .= " \"Toad\" \"$args\" [] {} 5000 >/dev/null";
				system($cmd);
			}
		} elsif ($action eq 'open-fm') {
			if (defined ($dbus_session_bus_address)) {
				$cmd .= " -d org.freedesktop.FileManager1";
				$cmd .= " -o /org/freedesktop/FileManager1";
				$cmd .= " -m org.freedesktop.FileManager1.ShowFolders";
				$cmd .= " '[\"file://$args\"]' \"\" >/dev/null";
				system($cmd);
			}
		}
		# exit the child
		exit (0);
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
		next unless ($uid >= 1000 && $uid <= 60000);

		my $display = $ck_session->GetX11Display ();
		next unless length ($display);

		my $gid = $pw_gid;
		my $login = $pw_name;
		my $home = $pw_dir;

		return ($login, $uid, $gid, $display, $home);
	}
}

sub get_dbus_session_file {
	my $id;
	my $machine_id = "/etc/machine-id";

	if (open my $fh, "<", $machine_id) {
		read $fh, $id, -s $fh;
		close $fh;
	} else {
		print "Can't open file \"$machine_id\"\n";
		return;
	}

	$id =~ s/\R//g; # drop line break
	$display =~ s/://;

	return "$home/.dbus/session-bus/$id-$display";
}

sub get_dbus_session_bus_address {
	my $dbus_session_file = get_dbus_session_file ();

	if (!defined ($dbus_session_file)) {
		return;
	}

	if (open my $fh, "<", $dbus_session_file) {
		while (<$fh>) {
			chomp;
			my ($l, $r) = split /=/, $_, 2;
			if ($l eq "DBUS_SESSION_BUS_ADDRESS") {
				$r =~ s/'//g;
				return ($r);
			}
		}
		close $fh;
	} else {
		print "Can't open file \"$dbus_session_file\"\n";
	}
}

sub get_mount_fs_type {
	my ($fstype) = @_;
	my $mount_t;

	if ($fstype eq 'NTFS') {
		$mount_t = 'ntfs';
	}
	return ($mount_t);
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
			my $mount_t = get_mount_fs_type($fs);
			push (@parts, "$part[0]:$mount_t");
		}
	}

	return (@parts);
}

sub mount_device {
	my @allparts;
	my @parts;
	my $mount_cmd = "/sbin/mount";

	# XXX skip device on error (e.g. DIOCGDINFO) or softraid(4) attachment
	if (system ("set -o pipefail; /sbin/disklabel $devname 2>/dev/null | ! grep -qw RAID") != 0) {
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
		gdbus_call ("notify", "No supported partition found on device $devname");
		return (0);
	}

	foreach my $part (@parts) {
		$part =~ s/^\s+//;
		my @part = split(/:/, $part);
		my $device = "/dev/$devname$part[0]";

		# skip already mounted partition
		if (system ("/sbin/mount | grep -q $device") == 0) {
			next;
		}

		my $devnum = get_mount_point ();
		create_mount_point ($devnum);
		create_pkrule ($devname, $devnum, $part);

		# DISCUSS: should we inform user about missing
		# mounting tools (i.e. blkid, ntfs-3g, mount.exfat-fuse)

		# check if NTFS is actually exFAT
		if ($part[1] eq 'ntfs' && -x '/usr/local/sbin/blkid') {
			if (System ("/usr/local/sbin/blkid $device | grep -q 'TYPE=\"exfat\"'") == 0) {
				$part[1] = 'exfat';
			}
		}

		if ($part[1] eq 'ntfs' && '/usr/local/bin/ntfs-3g') {
			$mount_cmd = "/usr/local/bin/ntfs-3g";
			$mountopts = "$mountopts,uid=$uid,gid=$gid,umask=077";
		}

		if ($part[1] eq 'exfat' && -x '/usr/local/sbin/mount.exfat-fuse') {
			$mount_cmd = "/usr/local/sbin/mount.exfat-fuse";
			$mountopts = "uid=$uid,gid=$gid,umask=077,noatime";
		}

		my $trymount = `$mount_cmd -o $mountopts $device $mountbase/$login/$devtype$devnum 2>&1`;
		if (length ($trymount) != 0) {
			system ("$trymount -o $mountopts,ro $device $mountbase/$login/$devtype$devnum");
			unless ($? == 0) {
				gdbus_call ("notify", "Cannot mount $device!");
				broom_sweep ();
				next;
			}
			unless ($trymount =~ /Permission denied/) {
				gdbus_call ("notify", "Unclean filesystem on device $device, mounting read-only");
			}
		}

		gdbus_call ("open-fm", "$mountbase/$login/$devtype$devnum");
	}
}

if ($devclass == 2) {
	$devtype = 'usb';
	$devmax = 10;
} elsif ($devclass == 9) {
	$devtype = 'cd';
	$devmax = 2;
} else {
	gdbus_call ("notify", "Device type not supported");
	exit (1);
}

if ($action eq 'attach') {
	if (!defined ($login) || !defined ($uid) || !defined ($gid)) {
		print "ConsoleKit: user does not own the active session\n";
		exit (1);
	}
	if ($devtype eq 'cd' || $devtype eq 'usb') { mount_device (); }
} elsif ($action eq 'detach') {
	if ($devtype eq 'cd' || $devtype eq 'usb') { broom_sweep (); }
} else { usage (); }
