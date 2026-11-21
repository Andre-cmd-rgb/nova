# nova-dictationd: dictation's speech to text (src/dictation, built by the
# root cargo workspace), heard by NVIDIA's Parakeet on the CPU through Nova's
# whisper-cpp (libparakeet, opened when a dictation needs it), while it is
# said. systemd starts it on the first dictation through its socket
# (nova-dictationd.socket, on for every user as part of the session), and it
# ends once unused; the shell's Super+D talks to it
# (src/shell/plugins/dictation). The model is the user's own download
# (nova dictation setup). Tests live in tests/ (cargo test: the daemon on a
# socket of its own, with a microphone that plays a recording) and in each
# module.

DICTATION_SRC := src/dictation

INSTALL_TARGETS += install-dictation

.PHONY: install-dictation
install-dictation:
	install -Dm755 $(or $(CARGO_TARGET_DIR),target)/release/nova-dictationd $(DESTDIR)$(NOVA_LIB)/nova-dictationd
	install -Dm644 -t $(DESTDIR)$(SYSTEMD_USER) $(DICTATION_SRC)/systemd/nova-dictationd.service $(DICTATION_SRC)/systemd/nova-dictationd.socket
	install -d $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants
	ln -sf ../nova-dictationd.socket $(DESTDIR)$(SYSTEMD_USER)/graphical-session.target.wants/nova-dictationd.socket
