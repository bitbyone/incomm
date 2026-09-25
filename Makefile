BIN := incomm
PREFIX ?= $(HOME)/.local

.PHONY: build test install clean fmt

build:
	cd cli && go build -o $(BIN) .

test:
	cd cli && go test ./...

fmt:
	cd cli && gofmt -w .

install: build
	install -d $(PREFIX)/bin
	install -m 0755 cli/$(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f cli/$(BIN)
