# Copyright 2026 DaaarQ
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit toolchain-funcs

DESCRIPTION="Linux CUPS driver for the Munbyn ITPP130 label printer (TSPL)"
HOMEPAGE="https://github.com/DaaarQ/itpp130-linux-driver"
SRC_URI="https://github.com/DaaarQ/itpp130-linux-driver/releases/download/v${PV}/itpp130-linux-driver-${PV}-src.tar.gz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="~amd64 ~arm64"
IUSE=""

DEPEND="
	virtual/os-headers
	net-print/cups
"
RDEPEND="
	net-print/cups:=
	net-print/cups-filters:=
	app-text/ghostscript-gpl:=
"

S="${WORKDIR}/${P}"

src_compile() {
	$(tc-getCC) ${CFLAGS} -Wall -Wno-deprecated-declarations \
		-o rastertolabel-itpp130 rastertolabel-itpp130.c \
		-lcups -lcupsimage || die "compile failed"
}

src_install() {
	exeinto /usr/libexec/cups/filter
	doexe rastertolabel-itpp130 gstoraster2tspl

	insinto /usr/share/cups/model/munbyn
	doins ITPP130-Label-printer.ppd

	dodoc README.md REVERSE-ENGINEERING.md NOTICE LICENSE CHANGELOG.md \
		SECURITY.md calib.pdf
}
