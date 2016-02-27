/*
 * Copyright (c) 2013 M:Tier Ltd.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 * Author: Antoine Jacoutot <antoine@mtier.org>
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <util.h>
#include <err.h>
#include <limits.h>

#define OD_DEVCLASS	9
#define POLL_INT	8	/* poll for device every n seconds */
#define TOAD_PATH	LIBEXECDIR "/toad"

__dead void usage(void);

int
main(int argc, char *argv[])
{
	unsigned int dev[] = {0, 0}; /* cd0, cd1 */
	int debug = 0;
	int poll_int = POLL_INT;
	int c;
	unsigned int i;
	char device[PATH_MAX];
	char cmd[64];
	char *has_label = NULL;
	const char *errstr;

	while ((c = getopt(argc, argv, "dw:")) != -1) {
		switch (c) {
		case 'd':
			debug = 1;
			break;
		case 'w':
			poll_int = strtonum(optarg, 1, 60, &errstr);
			if (errstr)
				errx(1, "-w %s: %s", optarg, errstr);
			break;
		default:
			usage();
		}
	}

        argc -= optind;
        argv += optind;
        if (argc > 0)
                usage();

	if (geteuid() != 0)
		errx(1, "need root privileges");

	if (!debug && daemon(0, 0) == -1)
		err(1, "unable to daemonize");

	for (;;) {
		if (debug)
			printf ("polling\n");

		for (i = 0; i < sizeof(dev) / sizeof(int); i++) {
			snprintf (device, sizeof device, "/dev/cd%dc", i);
			has_label = readlabelfs(device, 0);
			if (has_label) {
				if (!dev[i]) {
					snprintf (cmd, sizeof cmd, "%s attach %d cd%d", TOAD_PATH, OD_DEVCLASS, i);
					if (debug)
						printf ("running \"%s\"\n", cmd);
					system(cmd);
					dev[i] = 1;
				}
			} else {
				if (dev[i]) {
					snprintf (cmd, sizeof cmd, "%s detach %d cd%d", TOAD_PATH, OD_DEVCLASS, i);
					if (debug)
						printf ("running \"%s\"\n", cmd);
					system(cmd);
					dev[i] = 0;
				}
			}
		}

		if (debug)
			printf ("sleeping %ds\n", poll_int);

		sleep(poll_int);
	}
	exit(0);
}

__dead void
usage(void)
{
	(void)fprintf(stderr, "usage: %s [-d] [-w wait]\n", getprogname());
	exit(1);
}
