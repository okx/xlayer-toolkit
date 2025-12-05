FROM golang:1.23-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go build -o bin/replayor ./cmd/replayor/main.go

WORKDIR /app

FROM ubuntu:25.04

# Install certs
# RUN apk add --no-cache ca-certificates
# COPY ./oplabs.crt /usr/local/share/ca-certificates/oplabs.crt
# RUN chmod 644 /usr/local/share/ca-certificates/oplabs.crt && update-ca-certificates

WORKDIR /app

COPY --from=builder /app/bin/replayor /bin/replayor

CMD ["/app/replayor.sh"]