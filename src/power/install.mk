# thinkpad-power and thinkpad-powerd: the ThinkPad P1 Gen 4i's power manager.
# Shipped on every machine and inert everywhere else: each unit carries a DMI
# condition, the udev rule and the sleep hook check the model themselves, and
# the model's modprobe and NetworkManager drop-ins come from its hardware
# profile (data/hardware). thinkpad-powerd is built by the root cargo workspace.
# The history and the measurements behind every choice are in
# docs/hardware/thinkpad-p1-gen4i.md.
#
# nova-undervolt is for any Intel laptop whose firmware lets a voltage offset
# through; its unit does nothing until `nova power undervolt set` writes one.

POWER_SRC := src/power

INSTALL_TARGETS += install-power
SHELL_SOURCES   += $(POWER_SRC)/bin/thinkpad-power $(POWER_SRC)/bin/nova-power-gpu-mode-apply \
                   $(POWER_SRC)/bin/nova-power-undervolt-apply $(POWER_SRC)/systemd/nova-undervolt-resume \
                   $(POWER_SRC)/test/roundtrip.sh $(POWER_SRC)/test/watts.sh
TEST_SCRIPTS    += $(POWER_SRC)/test/roundtrip.sh

POWER_WANTS := multi-user.target:thinkpad-power.service \
               suspend.target:thinkpad-power.service \
               hibernate.target:thinkpad-power.service \
               suspend-then-hibernate.target:thinkpad-power.service \
               multi-user.target:thinkpad-powerd.service \
               multi-user.target:nova-undervolt.service \
               timers.target:thinkpad-power-gpu.timer

.PHONY: install-power
install-power:
	install -Dm755 $(POWER_SRC)/bin/thinkpad-power $(DESTDIR)$(NOVA_BIN)/thinkpad-power
	install -Dm755 $(POWER_SRC)/bin/nova-power-gpu-mode-apply $(DESTDIR)$(NOVA_LIB)/nova-power-gpu-mode-apply
	install -Dm644 $(POWER_SRC)/polkit/org.nova.power-gpu.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.power-gpu.policy
	install -Dm755 $(POWER_SRC)/bin/nova-power-undervolt-apply $(DESTDIR)$(NOVA_LIB)/nova-power-undervolt-apply
	install -Dm644 $(POWER_SRC)/polkit/org.nova.power-undervolt.policy $(DESTDIR)$(PREFIX)/share/polkit-1/actions/org.nova.power-undervolt.policy
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/thinkpad-powerd $(DESTDIR)$(NOVA_BIN)/thinkpad-powerd
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-undervolt $(DESTDIR)$(NOVA_BIN)/nova-undervolt
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_SYSTEM) $(POWER_SRC)/systemd/*.service $(POWER_SRC)/systemd/*.timer
	install -Dm755 $(POWER_SRC)/systemd/thinkpad-power-resume $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/thinkpad-power-resume
	install -Dm755 $(POWER_SRC)/systemd/nova-undervolt-resume $(DESTDIR)$(PREFIX)/lib/systemd/system-sleep/nova-undervolt
	install -Dm644 -t $(DESTDIR)$(PREFIX)/lib/udev/rules.d $(POWER_SRC)/udev/*.rules
	# Enabled for everyone, like a package that ships its own .wants links; the
	# DMI conditions keep them from starting anywhere but a P1 Gen 4i, and
	# nova-undervolt's from starting before an offset is set.
	for want in $(POWER_WANTS); do \
	  install -d "$(DESTDIR)$(SYSTEMD_SYSTEM)/$${want%%:*}.wants" && \
	  ln -sf "../$${want#*:}" "$(DESTDIR)$(SYSTEMD_SYSTEM)/$${want%%:*}.wants/$${want#*:}"; \
	done
