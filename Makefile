.PHONY: build test app dmg

export MACOSX_DEPLOYMENT_TARGET ?= 14.0
# Documents is a file provider on this Mac and stamps FinderInfo onto .build,
# which makes codesign reject the test bundle. /tmp is a normal volume.
export BUILD_PATH ?= /tmp/curlbrew-build

# Swift 6.4 Command Line Tools keep the Testing macro plugin in
# usr/lib/swift/host/plugins/testing, and SwiftPM stops searching the host plugin
# paths once --arch is passed, so @Test fails to resolve. Point swiftc at that
# directory when it exists; with Xcode the plugin is found without this flag.
TESTING_PLUGIN_PATH := $(shell p="$$(xcode-select -p)/usr/lib/swift/host/plugins/testing"; [ -d "$$p" ] && echo "$$p")
TESTING_PLUGIN_FLAGS := $(if $(TESTING_PLUGIN_PATH),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGIN_PATH))

build:
	swift build --arch arm64 --build-path "$(BUILD_PATH)"

test:
	swift test --arch arm64 --build-path "$(BUILD_PATH)" $(TESTING_PLUGIN_FLAGS)

app: build
	BUILD_PATH="$(BUILD_PATH)" ./Scripts/package-app.sh

# Necesita create-dmg: brew install create-dmg
dmg: app
	./Scripts/package-dmg.sh
