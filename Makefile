SCHEME := mCore
PROJECT := mCore.xcodeproj
PACKAGES := $(wildcard Packages/*)
DESTINATION ?= $(shell scripts/sim-destination.sh)

.PHONY: generate build test test-packages lint strings clean

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -destination "$(DESTINATION)" -quiet

test: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination "$(DESTINATION)" -quiet

test-packages:
	@for pkg in $(PACKAGES); do \
		echo "==> swift test $$pkg"; \
		swift test --package-path $$pkg --quiet || exit 1; \
	done

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict --quiet; \
	else \
		echo "swiftlint not installed (brew install swiftlint); skipping"; \
	fi

# Syncs App/Resources/Localizable.xcstrings with the strings used in code (Xcode does this when building in the IDE).
strings: generate
	xcodebuild -exportLocalizations -project $(PROJECT) -localizationPath build/localization -exportLanguage en -sdk iphonesimulator -quiet

clean:
	rm -rf $(PROJECT) DerivedData build
	@for pkg in $(PACKAGES); do rm -rf $$pkg/.build; done
