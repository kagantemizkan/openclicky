# OpenClicky — CLI-only build + bundle + sign pipeline.
#
# Signing strategy (per Apple DTS forum 730043 — stable identity ends
# TCC thrash). In priority order, `make build` auto-picks the best
# identity available on the machine:
#
#   1. CLICKY_SIGN_IDENTITY env override         — explicit choice (CI).
#   2. "Developer ID Application: …"             — release-grade, notarizable.
#   3. "Apple Development: …" (Personal Team)    — free, issued by Xcode
#                                                  when you sign in with
#                                                  any Apple ID. Stable
#                                                  Team ID → TCC grants
#                                                  persist across rebuilds.
#   4. Fallback: ad-hoc ("-")                    — cdhash churn forces
#                                                  TCC re-prompt every
#                                                  rebuild. Works, but
#                                                  annoying.
#
# Targets:
#   make build        → build + bundle + sign (best available identity)
#   make run          → build + launch
#   make install      → build + copy to /Applications/OpenClicky.app + launch
#   make dmg          → build + create OpenClicky-<version>-arm64.dmg + sha256
#   make doctor       → dump designated requirement so you can confirm
#                       TCC-stability across rebuilds
#   make reset-tcc    → nuclear option: wipe OpenClicky's TCC grants so the
#                       next launch re-prompts with the new identity
#   make clean        → delete build artefacts
#
# Notarization happens in CI (see .github/workflows/release.yml) — local
# developer builds never notarize.

APP_NAME    := OpenClicky
EXEC        := openclicky
BUNDLE_ID   := com.kagantemizkan.openclicky
VERSION     := 0.1.0
ARCH        := arm64

BUILD_DIR   := .build/release
APP_BUNDLE  := $(APP_NAME).app
APP_ROOT    := $(APP_BUNDLE)/Contents
APP_MACOS   := $(APP_ROOT)/MacOS
APP_RES     := $(APP_ROOT)/Resources
DMG_NAME    := $(APP_NAME)-$(VERSION)-$(ARCH).dmg

# Resolve the best signing identity available NOW. Run this at Make-time
# not at shell-time so the user sees which one was picked.
SIGN_IDENTITY := $(shell \
	if [ -n "$$CLICKY_SIGN_IDENTITY" ]; then \
		echo "$$CLICKY_SIGN_IDENTITY"; \
	elif security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then \
		security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $$2; exit}'; \
	elif security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development'; then \
		security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}'; \
	else \
		echo '-'; \
	fi)

.PHONY: build run install clean bundle dmg doctor reset-tcc

build: bundle

bundle:
	@echo "==> swift build (release)"
	swift build -c release --arch $(ARCH)
	@echo "==> wrapping $(APP_BUNDLE)"
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_MACOS) $(APP_RES)
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_MACOS)/$(EXEC)
	cp Info.plist $(APP_ROOT)/Info.plist
	cp Resources/OpenClicky.icns $(APP_RES)/OpenClicky.icns
	cp scripts/ahenk_tts_server.py $(APP_RES)/ahenk_tts_server.py
	cp scripts/setup-ahenk $(APP_RES)/setup-ahenk
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo "==> codesign: AD-HOC (TCC will re-prompt on every rebuild)"; \
		echo "    Tip: sign into Xcode with an Apple ID (free), then rebuild"; \
		echo "    to pick up a stable Apple Development identity."; \
	else \
		echo "==> codesign: $(SIGN_IDENTITY)"; \
	fi
	codesign --force --sign "$(SIGN_IDENTITY)" \
		--identifier $(BUNDLE_ID) \
		--entitlements OpenClicky.entitlements \
		--options runtime --timestamp=none \
		$(APP_BUNDLE)
	@echo "==> built $(APP_BUNDLE)"

run: bundle
	@echo "==> launching $(APP_BUNDLE)"
	open $(APP_BUNDLE)

# Installs to /Applications/. TCC + Gatekeeper behave best with apps in
# the canonical location, and /Applications/ is where the cask + DMG
# install path lands in production — so dev runs match prod runs.
install: bundle
	@echo "==> installing to /Applications/$(APP_BUNDLE)"
	rm -rf "/Applications/$(APP_BUNDLE)"
	cp -R "$(APP_BUNDLE)" "/Applications/$(APP_BUNDLE)"
	codesign --verify --deep --strict "/Applications/$(APP_BUNDLE)" || true
	open "/Applications/$(APP_BUNDLE)"

dmg: bundle
	@echo "==> building $(DMG_NAME)"
	rm -f $(DMG_NAME) $(DMG_NAME).sha256
	rm -rf .dmg-stage
	mkdir .dmg-stage
	ditto $(APP_BUNDLE) .dmg-stage/$(APP_BUNDLE)
	ln -s /Applications .dmg-stage/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder .dmg-stage -ov -format UDZO $(DMG_NAME)
	rm -rf .dmg-stage
	shasum -a 256 $(DMG_NAME) | awk '{print $$1}' > $(DMG_NAME).sha256
	@echo "==> $(DMG_NAME) + $(DMG_NAME).sha256"

# Dump the designated requirement so you can confirm TCC stability.
# Stable identity → "DR: anchor apple generic and identifier ..."
# Ad-hoc          → "DR: identifier ... and cdhash H\"...\"" (changes every build)
doctor:
	@echo "==> current signing identity selected by Makefile: $(SIGN_IDENTITY)"
	@echo "==> designated requirement:"
	@codesign -d --requirements - "$(APP_BUNDLE)" 2>&1 | sed -n 's/^designated =>/  DR:/p' || true
	@echo "==> code signature summary:"
	@codesign -dv --verbose=4 "$(APP_BUNDLE)" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier|Signature'
	@echo ""
	@echo "==> available codesigning identities on this machine:"
	@security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID' || echo "  (none — only ad-hoc available)"

# Nuclear option: wipe OpenClicky's TCC grants so the next launch re-prompts.
# Use this ONLY after knowingly changing signing identity (e.g. you just
# signed into Xcode with an Apple ID and swapped ad-hoc → Apple Development).
reset-tcc:
	@echo "==> tccutil reset for $(BUNDLE_ID)"
	- tccutil reset ScreenCapture $(BUNDLE_ID)
	- tccutil reset Accessibility $(BUNDLE_ID)
	- tccutil reset Microphone    $(BUNDLE_ID)
	- tccutil reset AppleEvents   $(BUNDLE_ID)
	@echo "==> done. relaunch OpenClicky to re-grant with the new identity."

clean:
	rm -rf .build $(APP_BUNDLE) $(DMG_NAME) $(DMG_NAME).sha256
