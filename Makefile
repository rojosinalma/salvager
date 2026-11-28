DOCKER_IMAGE := salvager-test
RUN := docker run --rm -u "$$(id -u):$$(id -g)" -v "$(CURDIR)":/src $(DOCKER_IMAGE)
# (The ratchet's loosening needs its two variables inside the container.)
RUN_ENV := docker run --rm -u "$$(id -u):$$(id -g)" -e ALLOW_WORSE -e REASON -v "$(CURDIR)":/src $(DOCKER_IMAGE)
SHELL := /bin/bash
# The real-font gate (a local dev tool, not in git): wow-ui-sim with the game's fonts. SIM_TOOL may point elsewhere.
SIM_TOOL ?= $(CURDIR)/.agents/tools/wow-ui-sim

# Local settings (gitignored): INSTALL_HOST, ADDONS_DIR, CURSEFORGE_*. See .env.example.
-include .env
export

.PHONY: image test lint check ratchet ratchet-check sim-check install layout package release

image:
	docker build -q -t $(DOCKER_IMAGE) test/

# The specs write what they measure to .ratchet/ (gitignored); busted's and luacheck's outputs are kept there too.
# The draw times (perf_spec) run first, in a Lua of their own: after the whole suite they measured up to 2x (0.4.0).
test: image
	@mkdir -p .ratchet
	set -o pipefail; $(RUN) busted --lpath="./?.lua" spec/perf_spec.lua 2>&1 | tee .ratchet/busted.txt
	set -o pipefail; $(RUN) busted --lpath="./?.lua" --exclude-pattern=perf_spec spec 2>&1 | tee -a .ratchet/busted.txt

lint: image
	@mkdir -p .ratchet
	set -o pipefail; $(RUN) luacheck -q Salvager spec scripts/ratchet.lua 2>&1 | tee .ratchet/luacheck.txt

# Every measured number against its baseline (spec/ratchet.json, SDD 121): a table of what got worse, and fail.
ratchet-check: image
	$(RUN) lua scripts/ratchet.lua check

check: test lint ratchet-check

# Moves the baseline to the better numbers only. A looser one on purpose:
#   make ratchet ALLOW_WORSE='layout%-typical:ledger/.*:width' REASON="why"   (Lua patterns, comma separated)
ratchet: test lint
	$(RUN_ENV) lua scripts/ratchet.lua tighten

# Every window and view drawn with the game's fonts (wow-ui-sim, glass mounted): bloat, gaps, cut texts, and the
# sim's own ratchet. Skipped where the tool is not there (it is not in git).
sim-check:
	@if [ -x "$(SIM_TOOL)/check.sh" ]; then SIM_SRC="$(CURDIR)/Salvager" "$(SIM_TOOL)/check.sh"; \
	else echo "sim-check: skipped, $(SIM_TOOL)/check.sh not here (a local dev tool, not in git)"; fi

# Replaces the addon folder on the gaming PC (Windows OpenSSH). Reload the game UI after (/reload).
install: check sim-check
	@if [ -z "$(INSTALL_HOST)" ] || [ -z "$(ADDONS_DIR)" ]; then echo "install: set INSTALL_HOST and ADDONS_DIR in .env"; exit 1; fi
	ssh -o RequestTTY=no $(INSTALL_HOST) 'if (Test-Path "$(ADDONS_DIR)/Salvager") { Remove-Item -Recurse -Force "$(ADDONS_DIR)/Salvager" }'
	scp -q -r Salvager "$(INSTALL_HOST):$(ADDONS_DIR)/"
	ssh -o RequestTTY=no $(INSTALL_HOST) 'Get-ChildItem "$(ADDONS_DIR)/Salvager" | Select-Object -ExpandProperty Name'
	@want=$$(grep '^## Version:' Salvager/Salvager.toc | tr -d '\r'); \
	got=$$(ssh -o RequestTTY=no $(INSTALL_HOST) 'Select-String -Path "$(ADDONS_DIR)/Salvager/Salvager.toc" -Pattern "^## Version:" | ForEach-Object { $$_.Line }' 2>/dev/null | tr -d '\r'); \
	if [ "$$want" != "$$got" ]; then echo "install FAILED: $(INSTALL_HOST) has '$$got', expected '$$want'"; exit 1; fi; \
	echo "installed: $$got"

# Draws each window of the layout dump (SDD 94) from the gaming PC's saved variables into .agents/tmp/layout/
# (<window>.png) and lists its layout problems. /reload the game first: the dump is written at logout and reload.
layout:
	python3 scripts/layout.py

# dist/Salvager-<version>.zip, the file CurseForge gets.
package: check
	python3 scripts/release.py package

# Uploads the zip to CurseForge and tags v<version>. RELEASE_TYPE=alpha|beta|release (default beta).
release: check
	python3 scripts/release.py release
