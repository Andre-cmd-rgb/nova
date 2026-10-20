# Speaker tunings, matched to the machine by nova-audio-tuning.

INSTALL_TARGETS += install-audio

AUDIO_FILES := $(shell cd data/audio && find . -type f -name '*.conf')

.PHONY: install-audio
install-audio:
	cd data/audio && for f in $(AUDIO_FILES); do install -Dm644 "$$f" "$(DESTDIR)$(NOVA_SHARE)/default/audio/$$f"; done
