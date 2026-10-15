# reboot-when-idle: `make test`, then `sudo make install enable` (into /usr/local), or `make deb`.
PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
ifeq ($(PREFIX),/usr)
UNITDIR := /usr/lib/systemd/system
TMPFILESDIR := /usr/lib/tmpfiles.d
else
UNITDIR := /etc/systemd/system
TMPFILESDIR := /etc/tmpfiles.d
endif
VERSION ?= 0.2.0
BUILD ?= build
OUT ?= .
UNITS := reboot-when-idle.service reboot-when-idle.timer reboot-when-idle-boot.service reboot-when-idle-trial.service

.PHONY: help check test install enable disable uninstall deb
help:
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t 10

check: ## syntax and the self-test (seconds)
	bash -n reboot-when-idle tests/scenarios.sh packaging/postinst packaging/prerm packaging/postrm
	./reboot-when-idle --self-test

test: check ## the scenarios on this machine, expected and unexpected; nothing reboots (about a minute)
	tests/scenarios.sh

install: ## copy the files; DESTDIR for packaging
	install -Dm755 reboot-when-idle $(DESTDIR)$(BINDIR)/reboot-when-idle
	install -d $(DESTDIR)$(UNITDIR)
	for unit in $(UNITS); do sed 's|@BINDIR@|$(BINDIR)|' systemd/$$unit > $(DESTDIR)$(UNITDIR)/$$unit; done
	install -Dm644 systemd/tmpfiles.conf $(DESTDIR)$(TMPFILESDIR)/reboot-when-idle.conf
	install -Dm644 systemd/watchdog.conf $(DESTDIR)/etc/systemd/system.conf.d/reboot-when-idle.conf
	install -Dm644 grub/reboot-when-idle.cfg $(DESTDIR)/etc/default/grub.d/reboot-when-idle.cfg
	install -d $(DESTDIR)$(PREFIX)/share/reboot-when-idle
	sed 's|/usr/bin/|$(BINDIR)/|g' hooks/claude-code.json > $(DESTDIR)$(PREFIX)/share/reboot-when-idle/claude-code-hooks.json

enable: ## as root after install: holds directory, GRUB, timer and boot checks on
	BINDIR=$(BINDIR) sh packaging/postinst configure

disable: ## as root: timer and boot checks off, GRUB back to how it was
	sh packaging/prerm remove
	rm -f /etc/default/grub.d/reboot-when-idle.cfg /etc/systemd/system.conf.d/reboot-when-idle.conf
	sh packaging/postrm remove

uninstall: disable ## as root: and remove the files
	rm -f $(BINDIR)/reboot-when-idle $(TMPFILESDIR)/reboot-when-idle.conf
	rm -rf $(PREFIX)/share/reboot-when-idle
	for unit in $(UNITS); do rm -f $(UNITDIR)/$$unit; done
	systemctl daemon-reload

deb: check ## build reboot-when-idle_<version>_all.deb into OUT (default: here)
	rm -rf $(BUILD) && $(MAKE) --no-print-directory install DESTDIR=$(BUILD)/root PREFIX=/usr
	install -d $(BUILD)/root/DEBIAN
	sed 's/@VERSION@/$(VERSION)/' packaging/control > $(BUILD)/root/DEBIAN/control
	install -m755 packaging/postinst packaging/prerm packaging/postrm $(BUILD)/root/DEBIAN/
	(cd $(BUILD)/root && find etc -type f -printf '/%p\n' > DEBIAN/conffiles)
	dpkg-deb --root-owner-group --build $(BUILD)/root $(OUT)/reboot-when-idle_$(VERSION)_all.deb
