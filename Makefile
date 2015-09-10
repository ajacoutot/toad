PREFIX?=	/usr/local
BINDIR= 	${PREFIX}/libexec
MANDIR= 	${PREFIX}/man/cat
SHAREDIR=	${PREFIX}/share
EXAMPLEDIR=	${SHAREDIR}/examples/toad

PROG=		toadd
MAN=		toad.8 toadd.8

INSTALL_DIR=	install -d -o root -g wheel -m 755
INSTALL_SCRIPT=	install -c -S -o root -g bin -m 555

CPPFLAGS+=	-DLIBEXECDIR=\"${BINDIR}\"
LDADD= 		-lutil

WARNINGS=	Yes
CFLAGS+=	-Werror

CLEANFILES=	hotplug-scripts

afterinstall:
	sed -e 's,@PREFIX@,${PREFIX},g' ${.CURDIR}/hotplug-scripts.in > \
		${.CURDIR}/hotplug-scripts
	${INSTALL_DIR} -d ${DESTDIR}${EXAMPLEDIR}
	${INSTALL_SCRIPT} ${.CURDIR}/hotplug-scripts ${DESTDIR}${EXAMPLEDIR}
	${INSTALL_SCRIPT} ${.CURDIR}/toad.pl ${DESTDIR}${BINDIR}/toad

.include <bsd.prog.mk>
