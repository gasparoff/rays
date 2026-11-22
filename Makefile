# Common development tasks. Run `make help` to list them.
.PHONY: help bootstrap test build lint format clean

help: ## List available tasks
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

bootstrap: ## Fetch Ableton Link (submodule) and the Beat Link helper
	Scripts/bootstrap.sh

test: ## Run the full test suite
	swift test --parallel

build: ## Build dist/RAYS.app
	Scripts/build-app.sh

lint: ## Lint Swift sources with swift-format
	swift format lint --recursive --parallel Sources Tests

format: ## Format the Swift files you changed (vs. origin/main)
	git diff --name-only --diff-filter=AM origin/main -- '*.swift' | xargs -r swift format --in-place

clean: ## Remove build products
	rm -rf .build dist
