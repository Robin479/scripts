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

.DEFAULT_GOAL := help

.PHONY: help all build bashly-build clean lint lint-plain lint-bashly new-plain new-bashly

# bin/ is gitignored (never committed), so it may not exist yet -- every
# bin/x link depends on this directory existing, order-only (a `|`
# prerequisite), so adding/removing links doesn't make bin/x look stale.
bin:
	mkdir -p bin

help:
	@echo "Targets:"
	@echo "  all                    Build (if needed) and link every bin/ entry"
	@echo "  bin/x                  Build (if needed) and link a single bin/ entry -- the make way"
	@echo "  bashly/x/x             (Re)generate a single bashly project if its bashly.yml/src changed"
	@echo "  build                  Depends on bashly-build"
	@echo "  bashly-build           Run '\$$(BASHLY) generate' for every out-of-date bashly project"
	@echo "  bin                    Create the (gitignored) bin/ directory if it doesn't exist yet"
	@echo "  clean                  Remove every bin/ link (including broken ones) and every generated bashly executable"
	@echo "  lint                   Depends on lint-plain and lint-bashly"
	@echo "  lint-plain             Run \$$(SHELLCHECK) over plain/"
	@echo "  lint-bashly            Run \$$(SHELLCHECK) --shell=bash over bashly/*/src/"
	@echo "  new-plain NAME=x       Scaffold plain/x and link it into bin/"
	@echo "  new-bashly NAME=x      Scaffold bashly/x/ and run '\$$(BASHLY) init' there"
	@echo "  dump-VAR               Print the value of any Makefile variable, e.g. make dump-BIN_TARGETS"
	@echo ""
	@echo "BASHLY currently resolves to:"
	@echo "  $(BASHLY)"
	@echo "(uses ./.local/bin/bashly if it's an executable/symlink, else falls back to"
	@echo "a dockerized bashly). Override per call if neither fits, e.g. make BASHLY=... build"
	@echo ""
	@echo "SHELLCHECK currently resolves to: $(SHELLCHECK)"
	@echo "Override per call if you'd rather use something else, e.g. make SHELLCHECK=... lint"

all: $(BIN_TARGETS)

# One real rule per existing bashly project: bashly/x/x depends on
# everything under its src/ (bashly.yml included -- that's where bashly
# expects it), so it only regenerates when something actually changed.
define BASHLY_PROJECT_RULE
bashly/$(1)/$(1): $(shell find bashly/$(1)/src -type f 2>/dev/null)
	cd bashly/$(1) && $$(BASHLY) generate
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

# bashly has no native "clean" subcommand -- its generated executable is the
# only thing that needs removing on its side.
clean:
	rm -f $(BIN_TARGETS)
	rm -f $(BASHLY_TARGETS)
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
	@cd "bashly/$(NAME)" && $(BASHLY) init
	@echo "Edit bashly/$(NAME)/src/bashly.yml, then run:"
	@echo "  make bin/$(NAME)"

# Debug helper: make dump-VAR echoes the value of any Makefile variable.
dump-%:
	@echo '$*=$($*)'
