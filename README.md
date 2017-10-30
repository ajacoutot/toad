# toad
device automounter for OpenBSD hotplugd(8)

toad (Toad Opens All Devices) is a utility meant to be started from the
hotplugd(8) attach and detach scripts.  It will try to mount all partitions
found on the device under /run/media/username/device.

Optionally, the toadd(8) optical medium detection daemon that works in
conjunction with toad(8) can be used to detect the insertion of a medium in the
optical drives of the machine (maximum 2).

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
- Polkit			required (for eject(1)/umount(8))
- Zenity			optional

toadd(8):
- toad(8)			required

TODO
----
- syslog
- eject(1)
- toadd cleanup mount points on SIG{TERM,HUP,...?}
- check for parts without hardcoding the supported FS?
- also handle USB printers (ugen/usb ownership)?
- check whether fuse0 is accessible and use ntfs3g if available
- pledge(2)
