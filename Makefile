BIN := incomm
PREFIX ?= $(HOME)/.local

.PHONY: build test test-fast cross dist install clean fmt

# VERSION is the release tag on HEAD without its v, empty anywhere else,
# which leaves the binary calling itself dev with its commit. The release
# workflow and the Homebrew formula set it the same way.
VERSION ?= $(shell git describe --tags --exact-match --match 'v[0-9]*.[0-9]*' 2>/dev/null | sed 's/^v//')
LDFLAGS := $(if $(VERSION),-X incomm/cmd.version=$(VERSION))

build:
	cd cli && go build -ldflags "$(LDFLAGS)" -o $(BIN) .

test:
	cd cli && go test -race ./...

test-fast:
	cd cli && go test ./...

# cross builds the CLI for every system it runs on, without cgo, to see that
# each still compiles and vets clean; nothing it makes is published.
PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64

cross:
	set -e; cd cli; for p in $(PLATFORMS); do \
		os=$${p%/*}; arch=$${p#*/}; exe=$(BIN); [ $$os = windows ] && exe=$(BIN).exe; \
		echo "$$os/$$arch"; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -ldflags "$(LDFLAGS)" -o ../dist/$$os-$$arch/$$exe .; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go vet ./...; \
	done

# dist builds what a release publishes: an archive for Windows on each
# architecture, incomm.exe and its licence at its top, and their SHA-256
# sums, for the Scoop manifest. macOS and Linux are not among them -
# Homebrew builds the tagged commit from source there.
DIST_PLATFORMS := windows/amd64 windows/arm64

dist:
	@test -n "$(VERSION)" || { echo "dist needs VERSION, the release's version without its v"; exit 1; }
	rm -rf dist
	set -e; for p in $(DIST_PLATFORMS); do \
		os=$${p%/*}; arch=$${p#*/}; name=$(BIN)_$(VERSION)_$${os}_$${arch}; \
		mkdir -p dist/$$name; \
		(cd cli && CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -ldflags "$(LDFLAGS)" -o ../dist/$$name/$(BIN).exe .); \
		cp LICENSE README.md dist/$$name/; \
		(cd dist/$$name && zip -q ../$$name.zip *); \
		rm -rf dist/$$name; \
	done
	cd dist && if command -v sha256sum >/dev/null; then sha256sum *.zip; else shasum -a 256 *.zip; fi > checksums.txt

fmt:
	cd cli && gofmt -w .

install: build
	install -d $(PREFIX)/bin
	install -m 0755 cli/$(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f cli/$(BIN)
	rm -rf dist
