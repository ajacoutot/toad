/*
 * Copyright (c) 2017 Robert Nagy <robert@openbsd.org>
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
 */

#include <sys/stat.h>
#include <errno.h>
#include <err.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char *argv[])
{
	uid_t uid = getuid();
	struct stat st;
	struct passwd *pw;
	char path[PATH_MAX], *p = NULL;
	int i=0;

	if (argc > 1)
		strlcpy(path, argv[1], sizeof(path));
	else
		errx(1, "missing path argument");

	pw = getpwuid(uid);
	if (!pw)
		err(1, "getpwuid() failed");

	for ((p = strtok(path, "/")); p; (p = strtok(NULL, "/"))) {
		if ((i == 0 && strncasecmp(p, "run", strlen(p))) ||
		    (i == 1 && strncasecmp(p, "media", strlen(p))) ||
		    (i == 2 && strncasecmp(p, pw->pw_name, strlen(p))))
			goto invalid;
		i++;
        }

	if (i <= 3)
invalid:
		errx(1, "%s is outside of /run/media/%s", argv[1], pw->pw_name);

	if (stat(argv[1], &st) != 0)
		err(1, "stat() failed");

	if (uid && (uid != st.st_uid))
		errx(1, "uid (%d) is not allowed to unmount %s", uid, argv[1]);

	if (setuid(geteuid()) != 0)
		err(1, "setuid() failed");

	if (setgid(getegid()) != 0)
		err(1, "setgid() failed");

	if (execv("/sbin/umount", argv) == -1)
		err(1, "execv() failed");

	return 0;
}
