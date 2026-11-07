#= ============================================================================
#= SSH Tunnel Manager - Makefile
#= Makefile version : 2.0.0
#= Target workspace : ssh-tunnel-manager 0.6.x (Rust, cargo workspace)
#= Requires         : GNU make >= 3.81, a POSIX sh, cargo (rustup honours rust-toolchain.toml)
#= Platforms        : Linux primary (Arch/Omarchy, Fedora, Debian/Ubuntu); macOS for
#=                    headless build/test only (the daemon uses Linux-only keyutils).
#= Conventions      : '#= ' marks real comments; plain '#' marks commented-out code.
#=                    '## text' after a target is the help text shown by `make help`.
#=                    '##@ Name' starts a help section.
#= Usage            : make help | make doctor | make check | make build-all
#= ============================================================================

MAKEFILE_VERSION := 2.0.0

SHELL            := /bin/sh
.DEFAULT_GOAL    := help
.DELETE_ON_ERROR:
MAKEFLAGS        += --no-print-directory

#= ---------------------------------------------------------------------------
#= Configuration (override on the command line, e.g. `make install PREFIX=/usr/local`)
#= ---------------------------------------------------------------------------
CARGO            ?= cargo
LOCKED           ?= --locked
#= VERBOSE=1 echoes every command; default is quiet recipes with timestamped log lines.
VERBOSE          ?= 0
#= LOG_FILE=path appends the [make] log lines to a file as well as stdout.
LOG_FILE         ?=
PREFIX           ?= $(HOME)/.local
DESTDIR          ?=
BINDIR           ?= $(PREFIX)/bin
APPDIR           ?= $(PREFIX)/share/applications
TARGET_DIR       ?= $(if $(CARGO_TARGET_DIR),$(CARGO_TARGET_DIR),target)
DIST_DIR         ?= dist
AUDIT_DIR        ?= $(TARGET_DIR)/audit
#= ARGS is passed through to run-cli / sandbox.
ARGS             ?=
#= Minimum GUI stack (see Cargo.toml features v4_22 / v1_9).
GTK_MIN          ?= 4.22
ADW_MIN          ?= 1.9
CONTAINER_IMAGE  ?= ssh-tunnel-builder
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

Q                := $(if $(filter 1,$(VERBOSE)),,@)

#= ---------------------------------------------------------------------------
#= Derived values
#= ---------------------------------------------------------------------------
VERSION          := $(shell grep -m1 '^version' Cargo.toml 2>/dev/null | cut -d'"' -f2)
GIT_REV          := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
IS_ROOT          := $(shell [ "$$(id -u)" -eq 0 ] && echo yes || echo no)
GTK_OK           := $(shell pkg-config --atleast-version=$(GTK_MIN) gtk4 2>/dev/null && pkg-config --atleast-version=$(ADW_MIN) libadwaita-1 2>/dev/null && echo yes || echo no)

#= Package selections. CI builds everything except the two GTK front-ends on Ubuntu,
#= because the GUI needs GTK 4.22 / libadwaita 1.9 (Fedora 44 class distributions).
GUI_PKG          := ssh-tunnel-gui
LEGACY_GUI_PKG   := ssh-tunnel-gui-gtk
WS_NOGUI         := --workspace --exclude $(GUI_PKG) --exclude $(LEGACY_GUI_PKG)
HEADLESS_PKGS    := -p ssh-tunnel-daemon -p ssh-tunnel-cli -p ssh-tunnel-common
BIN_DAEMON       := $(TARGET_DIR)/release/ssh-tunnel-daemon
BIN_CLI          := $(TARGET_DIR)/release/ssh-tunnel
BIN_GUI          := $(TARGET_DIR)/release/ssh-tunnel-gui
DESKTOP_FILE     := crates/gui-v2/data/io.github.schirmforge.SshTunnelManager.desktop

#= ---------------------------------------------------------------------------
#= Helper macros
#= ---------------------------------------------------------------------------
#= $(call log,message) - timestamped log line to stdout (and LOG_FILE when set).
define log
printf '%s [make] %s\n' "$$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(1)"$(if $(LOG_FILE), | tee -a "$(LOG_FILE)")
endef

#= $(call require,command,hint) - fail early with an actionable message.
define require
command -v $(1) >/dev/null 2>&1 || { echo "error: '$(1)' not found. $(2)" >&2; exit 127; }
endef

#= $(call guard_nonroot) - the daemon refuses uid 0 by design; so do its integration tests.
define guard_nonroot
[ "$(IS_ROOT)" = "no" ] || { echo "error: refusing to run as root (the daemon exits when euid==0). Run as a normal user." >&2; exit 1; }
endef

.PHONY: help version doctor print-vars \
        deps-arch deps-debian deps-fedora tools tools-extra \
        build build-debug build-gui build-all build-legacy-gui typecheck doc \
        fmt fmt-check clippy clippy-gui lint check \
        test test-unit test-integration test-gui test-live test-live-fixture \
        test-keychain-live test-network-modes test-all coverage smoke \
        audit audit-deny audit-advisories audit-json audit-tools machete outdated deps-tree \
        run-daemon run-cli run-gui sandbox ssh-fixture-up ssh-fixture-down \
        install uninstall install-systemd-user \
        dist dist-source dist-bin \
        container-build container-shell container-check \
        ci clean distclean

##@ Help & environment

help: ## Show this help
	@printf 'SSH Tunnel Manager %s (%s) - Makefile %s\n' "$(VERSION)" "$(GIT_REV)" "$(MAKEFILE_VERSION)"
	@awk 'BEGIN{FS=":.*## "} /^##@/{printf "\n%s\n", substr($$0,5)} /^[a-zA-Z0-9_.-]+:.*## /{printf "  %-24s %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@printf '\nOverrides: PREFIX DESTDIR LOCKED= VERBOSE=1 LOG_FILE=path ARGS="..." CARGO TARGET_DIR\n'

version: ## Print project, git and Makefile versions
	@printf 'project=%s\ngit=%s\nmakefile=%s\n' "$(VERSION)" "$(GIT_REV)" "$(MAKEFILE_VERSION)"

print-vars: ## Print the resolved configuration (for debugging the Makefile)
	@printf 'VERSION=%s\nGIT_REV=%s\nIS_ROOT=%s\nGTK_OK=%s (need gtk4>=%s libadwaita>=%s)\nPREFIX=%s\nDESTDIR=%s\nTARGET_DIR=%s\nCONTAINER_ENGINE=%s\n' \
		"$(VERSION)" "$(GIT_REV)" "$(IS_ROOT)" "$(GTK_OK)" "$(GTK_MIN)" "$(ADW_MIN)" "$(PREFIX)" "$(DESTDIR)" "$(TARGET_DIR)" "$(CONTAINER_ENGINE)"

doctor: ## Check the toolchain, build prerequisites and GUI stack (non-destructive)
	@$(call log,doctor: checking prerequisites)
	@fail=0; \
	for c in cargo rustc cc cmake git; do \
		if command -v $$c >/dev/null 2>&1; then printf '  ok       %s\n' "$$c"; \
		else printf '  MISSING  %s (required: aws-lc-sys needs cmake + a C compiler)\n' "$$c"; fail=1; fi; \
	done; \
	for c in pkg-config curl jq sshd ssh-keygen cargo-deny cargo-audit podman; do \
		if command -v $$c >/dev/null 2>&1; then printf '  ok       %s\n' "$$c"; \
		else printf '  optional %s not found\n' "$$c"; fi; \
	done; \
	printf '  rust     %s\n' "$$($(CARGO) --version 2>/dev/null || echo unavailable)"; \
	printf '  gtk4/libadwaita for GUI: %s\n' "$(GTK_OK)"; \
	[ "$(GTK_OK)" = yes ] || printf '           (GUI needs gtk4>=%s and libadwaita>=%s; headless build still works)\n' "$(GTK_MIN)" "$(ADW_MIN)"; \
	[ "$(IS_ROOT)" = no ] || printf '  WARNING  running as root: the daemon and its integration tests refuse uid 0\n'; \
	exit $$fail

##@ System dependencies (use sudo; run once)

deps-arch: ## Install build deps on Arch/Omarchy (pacman)
	sudo pacman -S --needed base-devel cmake pkgconf git rustup openssh curl jq gtk4 libadwaita
	rustup default stable

deps-debian: ## Install build deps on Debian/Ubuntu (apt); GUI libs may be too old
	sudo apt-get update
	sudo apt-get install -y build-essential cmake pkg-config git curl jq openssh-server libgtk-4-dev libadwaita-1-dev

deps-fedora: ## Install build deps on Fedora (dnf)
	sudo dnf install -y gcc gcc-c++ make cmake perl-interpreter pkgconf-pkg-config git curl jq openssh-server gtk4-devel libadwaita-devel

tools: ## Install cargo-deny and cargo-audit (slow, once per environment)
	$(CARGO) install --locked cargo-deny cargo-audit

tools-extra: ## Install optional tools: cargo-machete, cargo-nextest, cargo-llvm-cov
	$(CARGO) install --locked cargo-machete cargo-nextest cargo-llvm-cov

##@ Build

build: ## Release build of everything except the GTK GUIs (daemon, cli, libs)
	@$(call log,build: release $(WS_NOGUI))
	$(Q)$(CARGO) build --release $(LOCKED) $(WS_NOGUI)

build-debug: ## Debug build of the default workspace members
	@$(call log,build-debug)
	$(Q)$(CARGO) build $(LOCKED)

build-gui: ## Release build of the production GTK GUI (needs gtk4>=4.22, libadwaita>=1.9)
	@[ "$(GTK_OK)" = yes ] || { echo "error: GUI needs gtk4>=$(GTK_MIN) and libadwaita>=$(ADW_MIN) (found: $$(pkg-config --modversion gtk4 2>/dev/null || echo none) / $$(pkg-config --modversion libadwaita-1 2>/dev/null || echo none)). Use 'make container-check' or a newer distro." >&2; exit 1; }
	@$(call log,build-gui)
	$(Q)$(CARGO) build --release $(LOCKED) -p $(GUI_PKG)

build-all: build ## Build everything; includes the GUI when the GTK stack is new enough
	@if [ "$(GTK_OK)" = yes ]; then $(MAKE) build-gui; \
	else $(call log,build-all: GUI skipped - gtk4/libadwaita too old or missing); fi

build-legacy-gui: ## Compile-check the obsolete gui-gtk crate (retained upstream, unmaintained)
	$(Q)$(CARGO) check $(LOCKED) -p $(LEGACY_GUI_PKG)

typecheck: ## Fast type-check without producing binaries
	$(Q)$(CARGO) check $(LOCKED) $(WS_NOGUI) --all-targets

doc: ## Build rustdoc for the headless crates
	$(Q)$(CARGO) doc $(LOCKED) --no-deps $(WS_NOGUI)

##@ Quality

fmt: ## Format all code
	$(Q)$(CARGO) fmt --all

fmt-check: ## Verify formatting (CI gate)
	$(Q)$(CARGO) fmt --all -- --check

clippy: ## Lint headless crates, warnings are errors (CI gate)
	$(Q)$(CARGO) clippy $(LOCKED) $(WS_NOGUI) --all-targets --all-features -- -D warnings

clippy-gui: ## Lint the production GUI (needs GTK stack)
	@[ "$(GTK_OK)" = yes ] || { echo "error: GTK stack too old for the GUI" >&2; exit 1; }
	$(Q)$(CARGO) clippy $(LOCKED) -p $(GUI_PKG) --all-targets -- -D warnings

lint: fmt-check clippy ## Formatting + clippy

check: fmt-check clippy test ## Format, clippy and tests (fast local gate)

##@ Test

test: ## Hermetic tests (tier 1); as root falls back to lib/bin tests only
	@if [ "$(IS_ROOT)" = yes ]; then \
		$(call log,test: running as root - skipping daemon integration tests (daemon refuses uid 0)); \
		$(CARGO) test $(LOCKED) $(WS_NOGUI) --lib --bins; \
	else \
		$(call log,test: tier 1 hermetic suite); \
		$(CARGO) test $(LOCKED) $(WS_NOGUI); \
	fi

test-unit: ## Unit tests only (lib + bin targets)
	$(Q)$(CARGO) test $(LOCKED) $(WS_NOGUI) --lib --bins

test-integration: ## Daemon API integration tests (spawns the daemon; must not be root)
	@$(call guard_nonroot)
	$(Q)$(CARGO) test $(LOCKED) -p ssh-tunnel-daemon --test daemon_api

test-gui: ## Tests for the production GUI (needs GTK stack)
	@[ "$(GTK_OK)" = yes ] || { echo "error: GTK stack too old for the GUI" >&2; exit 1; }
	$(Q)$(CARGO) test $(LOCKED) -p $(GUI_PKG)

#= Live SSH tests are #[ignore]d. STRICT turns a missing target into a failure instead
#= of a silent skip that still reports "ok".
test-live: ## Tier-3/4 live SSH tests vs a provisioned host (.local/testing/ssh-target.env)
	@$(call guard_nonroot)
	SSH_TUNNEL_TEST_STRICT=all $(CARGO) test $(LOCKED) -- --ignored --nocapture

test-live-fixture: ## Tier-2 live tests against an unprivileged local sshd (needs sshd, no root)
	@$(call guard_nonroot)
	@$(call require,sshd,Install openssh-server (the binary may live in /usr/sbin).)
	./scripts/ssh-fixture.sh up
	@SSH_TUNNEL_TEST_STRICT=1 $(CARGO) test $(LOCKED) -p ssh-tunnel-daemon --test live_ssh -- --ignored --nocapture; \
		status=$$?; ./scripts/ssh-fixture.sh down; exit $$status

ssh-fixture-up: ## Start the local sshd test fixture
	./scripts/ssh-fixture.sh up

ssh-fixture-down: ## Stop the local sshd test fixture
	./scripts/ssh-fixture.sh down

test-keychain-live: ## Keychain tests against a throwaway gnome-keyring session
	@$(call require,dbus-run-session,Install the dbus package.)
	@$(call require,gnome-keyring-daemon,Install gnome-keyring.)
	dbus-run-session -- sh -c '\
		echo -n "test-password" | gnome-keyring-daemon --unlock --replace --daemonize >/dev/null 2>&1; \
		$(CARGO) test $(LOCKED) -p ssh-tunnel-common --test keychain_live -- --ignored --nocapture \
			--skip helper_reads_back'

test-network-modes: build ## End-to-end CLI test of unix-socket / tcp-http / tcp-https modes
	@$(call guard_nonroot)
	./scripts/test-network-modes.sh

smoke: build ## Start the release daemon in a temp HOME and verify auth (401 without token, 200 with)
	@$(call guard_nonroot)
	@$(call require,curl,Install curl.)
	@$(call log,smoke: starting daemon in a throwaway HOME)
	@set -eu; \
	tmp="$$(mktemp -d)"; chmod 700 "$$tmp"; pid=""; \
	trap 'if [ -n "$$pid" ]; then kill "$$pid" 2>/dev/null || true; fi; rm -rf "$$tmp"' EXIT INT TERM; \
	env -i HOME="$$tmp" XDG_RUNTIME_DIR="$$tmp" PATH="$$PATH" SSH_TUNNEL_SKIP_KEYRING=1 \
		"$(BIN_DAEMON)" >"$$tmp/daemon.log" 2>&1 & pid=$$!; \
	sock="$$tmp/ssh-tunnel-manager/ssh-tunnel-manager.sock"; \
	tok="$$tmp/.config/ssh-tunnel-manager/daemon.token"; \
	i=0; while [ ! -S "$$sock" ] || [ ! -s "$$tok" ]; do \
		i=$$((i+1)); [ $$i -le 50 ] || { echo "FAIL: daemon did not start"; cat "$$tmp/daemon.log"; exit 1; }; sleep 0.2; done; \
	c1="$$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$$sock" http://x/api/health)"; \
	c2="$$(curl -s -o /dev/null -w '%{http_code}' -H "X-Tunnel-Token: $$(cat "$$tok")" --unix-socket "$$sock" http://x/api/health)"; \
	[ "$$c1" = 401 ] || { echo "FAIL: expected 401 without token, got $$c1"; exit 1; }; \
	[ "$$c2" = 200 ] || { echo "FAIL: expected 200 with token, got $$c2"; exit 1; }; \
	[ "$$(stat -c %a "$$tok" 2>/dev/null || stat -f %Lp "$$tok")" = 600 ] || { echo "FAIL: token file not 0600"; exit 1; }; \
	echo "smoke OK: 401 without token, 200 with token, token file 0600"

test-all: check test-integration test-network-modes smoke ## Everything hermetic plus local end-to-end checks

coverage: ## Line coverage via cargo-llvm-cov (make tools-extra first)
	@$(call require,cargo-llvm-cov,Run: make tools-extra)
	$(Q)$(CARGO) llvm-cov $(LOCKED) $(WS_NOGUI) --html --output-dir $(TARGET_DIR)/coverage
	@$(call log,coverage report: $(TARGET_DIR)/coverage/html/index.html)

##@ Supply-chain & dependency audit

audit: audit-deny ## Supply-chain gate (cargo deny: advisories, licences, bans, sources)

audit-deny: ## cargo deny check using deny.toml (needs: make tools)
	@$(call require,cargo-deny,Run: make tools)
	$(Q)$(CARGO) deny check

audit-advisories: ## cargo audit (RustSec) human-readable
	@$(call require,cargo-audit,Run: make tools)
	$(Q)$(CARGO) audit

audit-json: ## cargo audit as JSON into target/audit/cargo-audit.json (portable data)
	@$(call require,cargo-audit,Run: make tools)
	@mkdir -p "$(AUDIT_DIR)"
	@$(CARGO) audit --json > "$(AUDIT_DIR)/cargo-audit.json" || true
	@$(call log,wrote $(AUDIT_DIR)/cargo-audit.json)

audit-tools: tools ## Alias for 'tools' (kept for compatibility with Makefile v1)

machete: ## Report unused dependencies (report only)
	@$(call require,cargo-machete,Run: make tools-extra)
	-$(Q)$(CARGO) machete

outdated: ## Show what `cargo update` would change (dry run)
	$(Q)$(CARGO) update --dry-run

deps-tree: ## Duplicate dependency versions
	$(Q)$(CARGO) tree --duplicates $(WS_NOGUI)

##@ Run

run-daemon: build-debug ## Run the daemon with debug logging (must not be root)
	@$(call guard_nonroot)
	RUST_LOG=debug $(CARGO) run $(LOCKED) -p ssh-tunnel-daemon

run-cli: ## Run the CLI: make run-cli ARGS="list"
	$(Q)$(CARGO) run $(LOCKED) -p ssh-tunnel-cli -- $(ARGS)

run-gui: ## Run the production GTK GUI
	@[ "$(GTK_OK)" = yes ] || { echo "error: GTK stack too old for the GUI" >&2; exit 1; }
	$(Q)$(CARGO) run $(LOCKED) -p $(GUI_PKG)

sandbox: ## Disposable shell with a daemon and seeded profiles: make sandbox ARGS="--mode tcp-https --profiles key,2fa"
	./scripts/dev-env.sh $(ARGS)

##@ Install

install: build ## Install binaries to PREFIX/bin (honours DESTDIR); GUI installed if built
	@$(call log,install: $(DESTDIR)$(BINDIR))
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 "$(BIN_DAEMON)" "$(DESTDIR)$(BINDIR)/ssh-tunnel-daemon"
	install -m 0755 "$(BIN_CLI)" "$(DESTDIR)$(BINDIR)/ssh-tunnel"
	@if [ -x "$(BIN_GUI)" ]; then \
		install -m 0755 "$(BIN_GUI)" "$(DESTDIR)$(BINDIR)/ssh-tunnel-gui"; \
		install -d "$(DESTDIR)$(APPDIR)"; \
		install -m 0644 "$(DESKTOP_FILE)" "$(DESTDIR)$(APPDIR)/"; \
		$(call log,installed GUI and desktop entry); \
	else $(call log,GUI binary not built - skipped (run make build-gui first)); fi
	@echo "Ensure $(BINDIR) is on your PATH."

uninstall: ## Remove files installed by 'make install'
	rm -f "$(DESTDIR)$(BINDIR)/ssh-tunnel-daemon" "$(DESTDIR)$(BINDIR)/ssh-tunnel" "$(DESTDIR)$(BINDIR)/ssh-tunnel-gui"
	rm -f "$(DESTDIR)$(APPDIR)/io.github.schirmforge.SshTunnelManager.desktop"

install-systemd-user: ## Install + enable the per-user systemd service via scripts/install.sh
	@$(call guard_nonroot)
	./scripts/install.sh --prefix "$(PREFIX)" --user-unit --enable

##@ Packaging

dist: dist-source dist-bin ## Source and binary tarballs with SHA-256 sums in dist/

dist-source: ## git archive of HEAD (tracked files only)
	@mkdir -p "$(DIST_DIR)"
	git archive --format=tar.gz --prefix=ssh-tunnel-manager-$(VERSION)/ -o "$(DIST_DIR)/ssh-tunnel-manager-$(VERSION)-src.tar.gz" HEAD
	@cd "$(DIST_DIR)" && sha256sum "ssh-tunnel-manager-$(VERSION)-src.tar.gz" > "ssh-tunnel-manager-$(VERSION)-src.tar.gz.sha256"

dist-bin: build ## Binary tarball of the release headless binaries
	@mkdir -p "$(DIST_DIR)"
	tar -C "$(TARGET_DIR)/release" -czf "$(DIST_DIR)/ssh-tunnel-manager-$(VERSION)-linux-$$(uname -m).tar.gz" ssh-tunnel ssh-tunnel-daemon
	@cd "$(DIST_DIR)" && sha256sum ssh-tunnel-manager-$(VERSION)-linux-*.tar.gz > "ssh-tunnel-manager-$(VERSION)-bin.sha256"

##@ Container (Fedora toolchain with GTK 4.22 for the GUI)

container-build: ## Build the dev image from containers/Containerfile.dev
	@$(call require,$(notdir $(CONTAINER_ENGINE)),Install podman or docker.)
	$(CONTAINER_ENGINE) build -t $(CONTAINER_IMAGE) -f containers/Containerfile.dev containers/

container-shell: ## Interactive shell in the dev image with the repo mounted at /src
	$(CONTAINER_ENGINE) run --rm -it -v "$(CURDIR):/src:Z" -w /src $(CONTAINER_IMAGE) bash

container-check: ## Run 'make check build-all' inside the dev image (installs rust toolchain via rustup first)
	$(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/src:Z" -w /src $(CONTAINER_IMAGE) \
		bash -lc 'command -v cargo >/dev/null || { curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; . "$$HOME/.cargo/env"; }; make check build-all'

##@ CI & cleanup

ci: fmt-check clippy test build ## Mirrors the `check` job in .github/workflows/ci.yml

clean: ## Remove cargo build artifacts
	$(Q)$(CARGO) clean

distclean: clean ## clean + dist/ (does not touch .local/ test config)
	rm -rf "$(DIST_DIR)"
