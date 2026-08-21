# itpp130-linux-driver
# Reverse engineered Linux CUPS driver for the Munbyn ITPP130 label printer.
# (see README.md for details)

%global debug_package %{nil}

Summary: Linux CUPS driver for the Munbyn ITPP130 label printer (TSPL)
Name: itpp130-linux-driver
Version: 1.0.2
Release: 1
# The filter, wrapper, PPD, documentation and packaging are original work
# licensed GPL-2.0-or-later; see %doc NOTICE for reverse-engineering
# provenance.
License: GPL-2.0-or-later
URL: https://github.com/DaaarQ/itpp130-linux-driver
Source0: %{name}-%{version}.tar.gz
BuildRequires: gcc
BuildRequires: cups-devel >= 2.4
BuildRequires: python3
# libcups.so.2 / libcupsimage.so.2 / GLIBC requires are auto-generated
# from the binary's SONAME dependencies and resolve to cups-libs on
# Fedora/RHEL and to the equivalent package on openSUSE.
Requires: cups-filters >= 1.28.0
Requires: ghostscript
Requires: cups >= 2.4

%description
CUPS driver for the Munbyn ITPP130 / ITPP130B 4x6" thermal label printer
(203 dpi, 100 mm wide), reverse engineered from the vendor's official
macOS and Windows drivers.

The printer speaks TSPL (model number 20). This package provides:

  * rastertolabel-itpp130 - CUPS raster -> TSPL filter
  * gstoraster2tspl       - PDF -> raster (ghostscript) -> TSPL wrapper
  * ITPP130 PPD           - 46 label sizes + custom sizes, darkness, print
                            speed, media tracking (gap/black-line/continuous),
                            gap height/offset, rotation, horizontal/vertical
                            offset, auto-dotted line mode

Usage:  lpadmin -p ITPP130 -E -v usb://Printer/ITPP130?serial=0000000 \
        -m munbyn/ITPP130-Label-printer.ppd

%prep
%setup -q

%build
cc -O2 -Wall -Wno-deprecated-declarations \
   -o rastertolabel-itpp130 rastertolabel-itpp130.c -lcups -lcupsimage

%check
tests/run-tests.sh ./rastertolabel-itpp130
cupstestppd -I filters -q ITPP130-Label-printer.ppd

%install
rm -rf %{buildroot}
# Fedora/RHEL install CUPS filters under /usr/lib/cups/filter
install -d %{buildroot}%{_prefix}/lib/cups/filter
install -d %{buildroot}%{_datadir}/cups/model/munbyn
install -d %{buildroot}%{_defaultdocdir}/%{name}
install -m 755 rastertolabel-itpp130 %{buildroot}%{_prefix}/lib/cups/filter/
install -m 755 gstoraster2tspl %{buildroot}%{_prefix}/lib/cups/filter/
install -m 644 ITPP130-Label-printer.ppd \
        %{buildroot}%{_datadir}/cups/model/munbyn/
install -m 644 README.md %{buildroot}%{_defaultdocdir}/%{name}/
install -m 644 REVERSE-ENGINEERING.md %{buildroot}%{_defaultdocdir}/%{name}/
install -m 644 NOTICE %{buildroot}%{_defaultdocdir}/%{name}/
install -m 644 LICENSE %{buildroot}%{_defaultdocdir}/%{name}/
install -m 644 CHANGELOG.md %{buildroot}%{_defaultdocdir}/%{name}/
install -m 644 SECURITY.md %{buildroot}%{_defaultdocdir}/%{name}/
install -m 644 calib.pdf %{buildroot}%{_defaultdocdir}/%{name}/

%files
%{_prefix}/lib/cups/filter/rastertolabel-itpp130
%{_prefix}/lib/cups/filter/gstoraster2tspl
%{_datadir}/cups/model/munbyn/ITPP130-Label-printer.ppd
%doc %{_defaultdocdir}/%{name}/

%changelog
* Fri Aug 21 2026 DaaarQ - 1.0.2-1
- Remove the inert MediaMethod PPD option.
- Document and centralize raster safety limits.

* Thu Aug 20 2026 DaaarQ - 1.0.1-1
- Validate raster headers and propagate partial-job failures.
- Correct 1-bit tail padding and honor requested copies.
- Add self-contained regression fixtures and PPD conformance fixes.

* Thu Aug 20 2026 DaaarQ - 1.0.0-1
- Initial release: reverse engineered TSPL driver for the Munbyn ITPP130.
