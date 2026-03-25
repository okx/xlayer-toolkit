BINARY  := mockteerpc
IMAGE   := mockteerpc
TAG     ?= latest

.PHONY: build install run test docker-build docker-run clean

build:
	go build -o bin/$(BINARY) ./cmd/mockteerpc

install:
	go install ./cmd/mockteerpc

run:
	go run ./cmd/mockteerpc

test:
	go test ./...

docker-build:
	docker build -t $(IMAGE):$(TAG) .

docker-run:
	docker run --rm -p 8090:8090 $(IMAGE):$(TAG)

clean:
	rm -rf bin/
