DOCKER_IMAGE := salvager-test
RUN := docker run --rm -v "$(CURDIR)":/src $(DOCKER_IMAGE)

# Local settings (gitignored): INSTALL_HOST, ADDONS_DIR, CURSEFORGE_*. See .env.example.
-include .env
export

.PHONY: image test lint check install package release

image:
	docker build -q -t $(DOCKER_IMAGE) test/

test: image
	$(RUN) busted --lpath="./?.lua" spec

lint: image
	$(RUN) luacheck -q Salvager spec

check: test lint

# Replaces the addon folder on the gaming PC (Windows OpenSSH). Reload the game UI after (/reload).
install: check
	@if [ -z "$(INSTALL_HOST)" ] || [ -z "$(ADDONS_DIR)" ]; then echo "install: set INSTALL_HOST and ADDONS_DIR in .env"; exit 1; fi
	ssh -o RequestTTY=no $(INSTALL_HOST) 'if (Test-Path "$(ADDONS_DIR)/Salvager") { Remove-Item -Recurse -Force "$(ADDONS_DIR)/Salvager" }'
	scp -q -r Salvager "$(INSTALL_HOST):$(ADDONS_DIR)/"
	ssh -o RequestTTY=no $(INSTALL_HOST) 'Get-ChildItem "$(ADDONS_DIR)/Salvager" | Select-Object -ExpandProperty Name'
	@want=$$(grep '^## Version:' Salvager/Salvager.toc | tr -d '\r'); \
	got=$$(ssh -o RequestTTY=no $(INSTALL_HOST) 'Select-String -Path "$(ADDONS_DIR)/Salvager/Salvager.toc" -Pattern "^## Version:" | ForEach-Object { $$_.Line }' 2>/dev/null | tr -d '\r'); \
	if [ "$$want" != "$$got" ]; then echo "install FAILED: $(INSTALL_HOST) has '$$got', expected '$$want'"; exit 1; fi; \
	echo "installed: $$got"

# dist/Salvager-<version>.zip, the file CurseForge gets.
package: check
	python3 scripts/release.py package

# Uploads the zip to CurseForge and tags v<version>. RELEASE_TYPE=alpha|beta|release (default beta).
release: check
	python3 scripts/release.py release
