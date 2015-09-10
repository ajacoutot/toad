#!/usr/bin/perl
#
# Copyright (c) 2013, 2014 M:tier Ltd.
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
	print 'need root privileges\n';
	exit (1);
}

if (@ARGV < 3) { usage (); }

my ($action, $devclass, $devname) = @ARGV;
my ($login, $uid, $gid, $home, $display) = get_active_user_info ();
my $mounttop = '/run';
my $mountbase = "$mounttop/media";
my $mountopts = 'nodev,nosuid,noexec';
my $devtype;
my $devmax;

sub usage {
	print "usage: $0 attach|detach devclass device\n";
	return (1);
}

sub get_active_user_info {
	my $system_bus = Net::DBus->system;
	my $ck_service = $system_bus->get_service ('org.freedesktop.ConsoleKit');
	my $ck_manager = $ck_service->get_object ('/org/freedesktop/ConsoleKit/Manager');

	for my $session_id (@{$ck_manager->GetSessions ()}) {
		my $ck_session = $ck_service->get_object ($session_id);
		next unless $ck_session->IsActive ();

		my $display = $ck_session->GetX11Display ();
		next unless length ($display);

		my $uid = $ck_session->GetUnixUser ();
		getpwuid ($uid) || die "no $uid user: $!";
		next unless $uid >= 1000;

		my $gid = $pw_gid;
		my $login = $pw_name;
		my $home = $pw_dir;

		return ($login, $uid, $gid, $home, $display);
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
	my $xmsg;
	my @xcmd = ('zenity', 'gxmessage');

	# ignore softraid(4) crypto device attachment
	my $sr_crypto = `/sbin/disklabel $devname 2>/dev/null | grep "SR CRYPTO"`;
	if ($sr_crypto) {
		return (0);
	}

	XMSG: foreach (split (/:/, $ENV{PATH})) {
		foreach my $xcmd (@xcmd) {
			$xmsg = $_ . '/' . $xcmd;
			if (-x $xmsg) {
				last XMSG;
			}
		}
	}
	unless (-x $xmsg) {
		$xmsg ="xmessage";
	}
	if ($xmsg =~ /zenity/) {
		$xmsg = "$xmsg --no-wrap --warning --text";
	} else {
		$xmsg = "$xmsg -center";
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

	my $usermount = `/sbin/sysctl -n kern.usermount=1`;
	if ($usermount != 1) {
		print 'failed to enable sysctl kern.usermount\n';
		return (1);
	}

	foreach my $part (@parts) {
		$part =~ s/^\s+//;
		my $device = "/dev/$devname$part";
		my $devnum = get_mount_point ();
		my $dirty = 0;

		create_mount_point ($devnum);

		# change device nodes ownership to the active user;
		# we need access to 'c' for mount(8) to detect the filesystem
		chown $uid, -1, "$device", "/dev/r${devname}c";

		my $pid = fork ();
		if (!defined ($pid)) {
			die "could not fork: $!";
		} elsif ($pid) {
			if (waitpid ($pid, 0) > 0) {
				if ($? >> 8 ne 0) {
					broom_sweep ();
				} else {
					restore_dev ();
				}
			}
		} else {
			$( = $) = "$gid $gid";
			$< = $> = $uid;

			$ENV{"DISPLAY"} = $display;
			$ENV{"HOME"} = $home;
			# XXX hardcoded path to XAUTHORITY
			$ENV{"XAUTHORITY"} = "$home/.Xauthority";

			my $mountrw = `/sbin/mount -o ${mountopts} ${device} $mountbase/$login/$devtype$devnum 2>&1`;
			if (length ($mountrw) != 0) {
				system ("/sbin/mount -o ${mountopts},ro ${device} $mountbase/$login/$devtype$devnum");
				unless ($? == 0) {
					system ("${xmsg} \"Cannot mount ${device}!\n\n$mountrw\"");
					die ("cannot mount ${device}: $!");
				}
				unless ($mountrw =~ /Permission denied/) {
					$dirty = 1;
				}
			}
			if ($dirty == 1) {
				system ("${xmsg} \"Filesystem on device ${device} is not clean and cannot be mounted
read-write, mounting in read-only mode!
fsck(8) may be used for consistency check and repair.\"");
			}
			system ("xdg-open file://$mountbase/$login/$devtype$devnum");
			# xmsg and xdg-open failures are non-fatal and at this
			# point we are mounted, so exit the child cleanly
			exit (0);
		}
	}
}

sub restore_dev {
	# we are already monted or detaching, no need to own the raw device
	chown 0, -1, <"/dev/r${devname}c">;

	# we are already monted or detaching, no need to own the block device;
	# 'cd' is a special case: gio passes the mounted block device path
	# to eject(1), so the user must own the node for it to work
	if ($devtype ne 'cd' || ($devtype eq 'cd' && $action eq 'detach')) {
		chown 0, -1, <"/dev/${devname}*">;
	}
}

sub broom_sweep {
	my $is_busy;
	my @tryrm;
	my @cfd;

	restore_dev ();

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
					# subdir is mounted, so don't try to rm parent
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

if ($devclass == 2) {
	$devtype = 'usb';
	$devmax = 10;
} elsif ($devclass == 9) {
	$devtype = 'cd';
	$devmax = 2;
} else {
	print 'device type not supported\n';
	exit (1);
}

if ($action eq 'attach') {
	if (!defined($login) || !defined($uid) || !defined($gid) || !defined($home) || !defined($display)) {
		print 'ConsoleKit: user does not own the active session\n';
		exit (1);
	}
	mount_device ();
} elsif ($action eq 'detach') {
	broom_sweep ();
} else {
	usage ();
}
