export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: ghostty build test app run mcp clean

ghostty:            ## Build libghostty (GhosttyKit.xcframework) from vendor/ghostty
	scripts/build-ghostty.sh

build:              ## Debug build of the app and MCP server
	swift build

test:
	swift test

app:                ## Release .app bundle in build/
	scripts/bundle.sh

run: app
	open "build/Jigowatt.app"

mcp:                ## Print the command to register the MCP server with Claude Code
	@echo claude mcp add --scope user jigowatt -- \"$(CURDIR)/build/Jigowatt.app/Contents/MacOS/jigowatt-mcp\"

clean:
	rm -rf .build build
