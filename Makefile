LOCAL_BASHLY := $(CURDIR)/.local/bin/bashly
ifeq ($(shell test -x "$(LOCAL_BASHLY)" && echo yes),yes)
BASHLY ?= $(LOCAL_BASHLY)
else
BASHLY ?= docker run --rm -v "$$PWD:/app" -w /app -u "$$(id -u):$$(id -g)" dannyben/bashly
endif

SHELLCHECK ?= shellcheck

BASHLY_PROJECTS     := $(patsubst bashly/%/,%,$(wildcard bashly/*/))
BASHLY_TARGETS      := $(foreach p,$(BASHLY_PROJECTS),bashly/$(p)/$(p))
BASHLY_BIN_TARGETS  := $(foreach p,$(BASHLY_PROJECTS),bin/$(p))

PLAIN_SCRIPTS       := $(shell find plain -maxdepth 1 -type f -executable 2>/dev/null)
PLAIN_BIN_TARGETS   := $(foreach f,$(PLAIN_SCRIPTS),bin/$(notdir $(basename $(f))))

BIN_TARGETS         := $(BASHLY_BIN_TARGETS) $(PLAIN_BIN_TARGETS)

BASH_COMPLETION_TARGETS := $(foreach p,$(BASHLY_PROJECTS),bash-completion.d/$(p))

# Same default bash-completion's own loader uses (see __load_completion in
# /usr/share/bash-completion/bash_completion): ${BASH_COMPLETION_USER_DIR:-
# ${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}. Kept as the same env
# var name on purpose, so a value the user already has set is honored
# identically here and at actual completion time.
BASH_COMPLETION_USER_DIR ?= $(if $(XDG_DATA_HOME),$(XDG_DATA_HOME),$(HOME)/.local/share)/bash-completion

# Old-style bash-completion has no per-command lazy loading at all -- it only
# ever eagerly sources /etc/bash_completion.d/* (root-owned, skipped entirely
# here as out of scope for a per-user tool) and this one file,
# unconditionally, every shell startup. Same env var name bash-completion
# itself uses, for the same reason as BASH_COMPLETION_USER_DIR above.
BASH_COMPLETION_USER_FILE ?= $(HOME)/.bash_completion

# Whichever of these exists first tells us bash-completion is installed at
# all; install-bash-completions greps it for __load_completion (the lazy
# per-command loader's own implementation, present only in the modern
# bash-completion this repo otherwise targets) to decide which of the two
# integration styles to actually use.
BASH_COMPLETION_FRAMEWORK := $(firstword $(wildcard /usr/share/bash-completion/bash_completion /etc/bash_completion))

.DEFAULT_GOAL := help

.PHONY: help all build bashly-build clean lint lint-plain lint-bashly new-plain new-bashly bash-completions install-bash-completions uninstall-bash-completions

# bin/ is gitignored (never committed), so it may not exist yet -- every
# bin/{cmd} link depends on this directory existing, order-only (a `|`
# prerequisite), so adding/removing links doesn't make bin/{cmd} look stale.
bin:
	mkdir -p bin

# bash-completion.d/ holds the tracked template (.template.sh.in) alongside
# generated, gitignored per-project completion scripts -- same split as bin/
# vs bashly/.template/, just both in one directory here. Order-only
# prerequisite for the same reason bin/ is: existing/not doesn't matter for
# staleness.
bash-completion.d:
	mkdir -p bash-completion.d

help:
	@echo "Targets:"
	@echo "  all                         Build (if needed) and link everything: bin/, bash-completion.d/"
	@echo "  bin/{cmd}                   Build and link a single bin/ entry"
	@echo "  bashly/{cmd}/{cmd}          (Re)generate a bashly project if its src/ changed"
	@echo "  build                       Depends on bashly-build"
	@echo "  bashly-build                Run bashly generate for every out-of-date project"
	@echo "  bin                         Create the (gitignored) bin/ directory"
	@echo "  bash-completions            Build every bash-completion.d/ entry"
	@echo "  bash-completion.d/{cmd}     Build a single bash-completion.d/ entry"
	@echo "  install-bash-completions    Hook bashly projects into bash-completion (lazy or eager; fails if neither)"
	@echo "  uninstall-bash-completions  Undo install-bash-completions, wherever it linked"
	@echo "  clean                       Remove all bin/, bash-completion.d/ and generated bashly executables"
	@echo "  lint                        Depends on lint-plain and lint-bashly"
	@echo "  lint-plain                  Run shellcheck over plain/"
	@echo "  lint-bashly                 Run shellcheck over bashly/*/src/"
	@echo "  new-plain NAME={cmd}        Scaffold plain/{cmd} and link it into bin/"
	@echo "  new-bashly NAME={cmd}       Scaffold bashly/{cmd}/ from bashly/.template/"
	@echo "  dump-VAR                    Print the value of any Makefile variable"
	@echo ""
	@echo "BASHLY                     = $(BASHLY)"
	@echo "SHELLCHECK                 = $(SHELLCHECK)"
	@echo "BASH_COMPLETION_USER_DIR   = $(BASH_COMPLETION_USER_DIR)"
	@echo "BASH_COMPLETION_USER_FILE  = $(BASH_COMPLETION_USER_FILE)"
	@echo "BASH_COMPLETION_FRAMEWORK  = $(if $(BASH_COMPLETION_FRAMEWORK),$(BASH_COMPLETION_FRAMEWORK),NOT FOUND)"
	@echo "(override any of these per call, e.g. make SHELLCHECK=... lint)"

all: $(BIN_TARGETS) $(BASH_COMPLETION_TARGETS)

# One real rule per existing bashly project: bashly/{cmd}/{cmd} depends on
# everything under its src/ (bashly.yml included -- that's where bashly
# expects it), so it only regenerates when something actually changed.
define BASHLY_PROJECT_RULE
bashly/$(1)/$(1): $(shell find bashly/$(1)/src -type f 2>/dev/null) $(wildcard bashly/$(1)/settings.yml)
	cd bashly/$(1) && $$(BASHLY) generate --upgrade
endef
$(foreach p,$(BASHLY_PROJECTS),$(eval $(call BASHLY_PROJECT_RULE,$(p))))

bashly-build: $(BASHLY_TARGETS)

build: bashly-build

# One real rule per bin/ entry: depends on its bashly project (triggering
# regeneration if stale) or its plain/ source, and (re)links it.
define BASHLY_BIN_RULE
bin/$(1): bashly/$(1)/$(1) | bin
	ln -sfv "../bashly/$(1)/$(1)" "$$@"
endef
$(foreach p,$(BASHLY_PROJECTS),$(eval $(call BASHLY_BIN_RULE,$(p))))

define PLAIN_BIN_RULE
bin/$(notdir $(basename $(1))): $(1) | bin
	ln -sfv "../$(1)" "$$@"
endef
$(foreach f,$(PLAIN_SCRIPTS),$(eval $(call PLAIN_BIN_RULE,$(f))))

# One real rule per bashly project's completion script: purely a function of
# the project's name (and this repo's fixed absolute path to its bin/ entry),
# not of that project's actual command tree -- the real completion logic is
# generated fresh at shell-startup time by invoking `<name> completions bash`
# (see bash-completion.d/.template.sh.in), so this only needs to be
# regenerated when the template itself changes, never when a project's
# bashly.yml does.
define BASH_COMPLETION_RULE
bash-completion.d/$(1): bash-completion.d/.template.sh.in | bash-completion.d
	sed -e 's/@NAME@/$(1)/g' -e 's|@BIN_PATH@|$(CURDIR)/bin/$(1)|g' "$$<" > "$$@"
	chmod +x "$$@"
endef
$(foreach p,$(BASHLY_PROJECTS),$(eval $(call BASH_COMPLETION_RULE,$(p))))

bash-completions: $(BASH_COMPLETION_TARGETS)

# Prefers bash-completion's lazy per-command loader (bash-completion.d/<name>
# symlinked into BASH_COMPLETION_USER_DIR); falls back to the old eager style
# (BASH_COMPLETION_USER_FILE sourcing bash-completion.sh) if that's all the
# detected framework supports; fails if bash-completion isn't installed at
# all. Never clobbers anything it doesn't already own.
install-bash-completions: $(BASH_COMPLETION_TARGETS)
	@if [ -z "$(BASH_COMPLETION_FRAMEWORK)" ]; then \
		echo "error: bash-completion doesn't appear to be installed on this system" >&2; \
		echo "  (checked /usr/share/bash-completion/bash_completion and /etc/bash_completion)" >&2; \
		echo "  install it first, e.g.: sudo apt-get install bash-completion" >&2; \
		exit 1; \
	fi; \
	if grep -q '__load_completion' "$(BASH_COMPLETION_FRAMEWORK)" 2>/dev/null; then \
		echo "modern bash-completion detected ($(BASH_COMPLETION_FRAMEWORK)) -- using $(BASH_COMPLETION_USER_DIR)/completions/"; \
		mkdir -pv "$(BASH_COMPLETION_USER_DIR)/completions"; \
		for p in $(BASHLY_PROJECTS); do \
			f="$(BASH_COMPLETION_USER_DIR)/completions/$$p"; \
			if [ -e "$$f" ] && [ ! -L "$$f" ]; then \
				echo "skipping $$f: exists and is not a symlink"; \
			elif [ -L "$$f" ] && [ "$$(readlink "$$f")" != "$(CURDIR)/bash-completion.d/$$p" ]; then \
				echo "skipping $$f: already a symlink to $$(readlink "$$f")"; \
			elif [ -L "$$f" ] && [ "$$(stat -c '%Y' "$(CURDIR)/bash-completion.d/$$p")" -le "$$(stat -c '%Y' "$$f")" ]; then \
				: already linked and up to date, nothing to do; \
			else \
				ln -sfv "$(CURDIR)/bash-completion.d/$$p" "$$f"; \
			fi; \
		done; \
	else \
		echo "old-style bash-completion detected ($(BASH_COMPLETION_FRAMEWORK), no dynamic loading) -- using $(BASH_COMPLETION_USER_FILE)"; \
		f="$(BASH_COMPLETION_USER_FILE)"; \
		line='. "$(CURDIR)/bash-completion.sh"'; \
		if [ ! -e "$$f" ] && [ ! -L "$$f" ]; then \
			ln -sfv "$(CURDIR)/bash-completion.sh" "$$f"; \
		elif [ -L "$$f" ]; then \
			[ "$$(readlink "$$f")" = "$(CURDIR)/bash-completion.sh" ] || echo "skipping $$f: already a symlink to $$(readlink "$$f")"; \
		elif grep -Fxq "$$line" "$$f" 2>/dev/null; then \
			: already wired up, nothing to do; \
		else \
			printf '%s\n' "$$line" >> "$$f" && echo "appended to $$f: $$line"; \
		fi; \
	fi

# Undoes install-bash-completions everywhere it could have linked, ignoring
# $(BASHLY_PROJECTS) -- removes any symlink (broken or not) that resolves into
# this repo, wherever found. For BASH_COMPLETION_USER_FILE: deletes it if it's
# such a symlink, else strips just our one appended line (deleting the file
# only if that leaves it empty). Never touches anything else.
uninstall-bash-completions:
	@[ -d "$(BASH_COMPLETION_USER_DIR)/completions" ] && for f in "$(BASH_COMPLETION_USER_DIR)/completions"/*; do \
		[ -L "$$f" ] || continue; \
		case "$$(readlink -f "$$f")" in \
			"$(CURDIR)"/*) rm -fv "$$f" ;; \
		esac; \
	done || true
	@f="$(BASH_COMPLETION_USER_FILE)"; \
	if [ -L "$$f" ]; then \
		case "$$(readlink -f "$$f")" in \
			"$(CURDIR)"/*) rm -fv "$$f" ;; \
		esac; \
	elif [ -f "$$f" ]; then \
		line='. "$(CURDIR)/bash-completion.sh"'; \
		if grep -Fxq "$$line" "$$f"; then \
			if [ "$$(grep -Fxv "$$line" "$$f" | wc -c)" -eq 0 ]; then \
				rm -fv "$$f"; \
			else \
				grep -Fxv "$$line" "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f" && echo "removed 1 line from $$f"; \
			fi; \
		fi; \
	fi

# bashly has no native "clean" subcommand -- its generated executable is the
# only thing that needs removing on its side.
clean:
	rm -f $(BIN_TARGETS)
	rm -f $(BASHLY_TARGETS)
	rm -f $(BASH_COMPLETION_TARGETS)
	@[ -d bin ] && find bin -maxdepth 1 -xtype l -print -delete || true

lint: lint-plain lint-bashly

lint-plain:
	@tool=$$(set -- $(SHELLCHECK); echo "$$1"); \
	command -v "$$tool" >/dev/null 2>&1 || { echo "$$tool: not found"; exit 1; }; \
	script_files=$$(find plain -maxdepth 1 -type f ! -name '.gitkeep' 2>/dev/null); \
	set -- $$script_files; found=$$#; \
	if [ "$$found" -eq 0 ]; then echo "no files to lint"; exit 0; fi; \
	$(SHELLCHECK) $$script_files; ret=$$?; \
	echo "linted $$found file(s)"; \
	exit $$ret

lint-bashly:
	@tool=$$(set -- $(SHELLCHECK); echo "$$1"); \
	command -v "$$tool" >/dev/null 2>&1 || { echo "$$tool: not found"; exit 1; }; \
	bashly_files=$$(find bashly -mindepth 2 -path '*/src/*' -name '*.sh' -type f 2>/dev/null); \
	set -- $$bashly_files; found=$$#; \
	if [ "$$found" -eq 0 ]; then echo "no files to lint"; exit 0; fi; \
	$(SHELLCHECK) --shell=bash $$bashly_files; ret=$$?; \
	echo "linted $$found file(s)"; \
	exit $$ret

new-plain:
	@[ -n "$(NAME)" ] || { echo "Usage: make new-plain NAME=foo"; exit 1; }
	@[ ! -e "plain/$(NAME)" ] || { echo "plain/$(NAME) already exists"; exit 1; }
	@mkdir -p plain
	@printf '#!/usr/bin/env bash\nset -euo pipefail\n\n' > "plain/$(NAME)"
	@chmod +x "plain/$(NAME)"
	@$(MAKE) bin/$(NAME)
	@echo "Created plain/$(NAME), linked as bin/$(NAME)"

new-bashly:
	@[ -n "$(NAME)" ] || { echo "Usage: make new-bashly NAME=foo"; exit 1; }
	@[ ! -e "bashly/$(NAME)" ] || { echo "bashly/$(NAME) already exists"; exit 1; }
	@mkdir -p "bashly/$(NAME)"
	@cd bashly/.template && find . -mindepth 1 \( -false \
		-o -type d -exec mkdir -p "../$(NAME)/{}" \; \
		-o -name '*.in' -exec sh -c ' \
			sed "s/@NAME@/$(NAME)/g" "$$1" > "../$(NAME)/$${1%.in}"' _ {} \; \
		-o -exec cp {} "../$(NAME)/{}" \; \)
	@echo "Created bashly/$(NAME)/ from bashly/.template/"
	@echo "Edit it, then run:"
	@echo "  make bin/$(NAME)"
	@echo "  make install-bash-completions   # picks up $(NAME) for bash-completion's lazy loader too"

# Debug helper: make dump-VAR echoes the value of any Makefile variable.
dump-%:
	@echo '$*=$($*)'
