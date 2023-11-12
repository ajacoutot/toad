# toad
device automounter for OpenBSD hotplugd(8)

toad (Toad Opens All Devices) is a utility meant to be started from the
hotplugd(8) attach and detach scripts.  It will try to mount all
partitions found on the device under /run/media/${USER}/device.  Where
${USER} is the active user login name and device is the type of the
device, usb or cd, followed by its number (from 0 to 9).  This follows
the udev hierarchy in Linux which allows interaction with GLib/GIO's
GUnixMount.

Detection of the currently active user is done using ConsoleKit and DBus,
toad will not do anything unless these are properly setup and running.
Obviously, hotplugd(8) must be running as well.

toadd(8) is an optical medium detection daemon that works in conjunction
with the toad(8) automounter.  It will detect the insertion of a medium
in the optical drives of the machine (maximum 2) by periodically reading
their disklabel(8).

See toad(8) for more information about how to create the hotplugd(8) attach and
detach scripts. A sample script that can be used as both an attach and a detach
script is provided: hotplug-scripts.

Installing
----------
    $ make
    $ doas make install

Runtime dependencies
--------------------
toad(8):
- Net::DBus			required
- ConsoleKit			required
- GLib (OpenBSD package)	required (patched for umount(8) with pkexec(1))
- Polkit			required (for eject(1)/umount(8))

toadd(8):
- toad(8)			required

TODO
----
- better notifications and logging (syslog)
- toadd cleanup mount points on SIG{TERM,HUP,...?}
- check for parts without hardcoding the supported FS?
- check whether fuse0 is accessible and use ntfs3g if available
- pledge(2), unveil(2)
- move most system() calls to perl modules
