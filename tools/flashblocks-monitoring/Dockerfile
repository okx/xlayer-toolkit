FROM golang:1.24-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o flashblocks-monitor .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/flashblocks-monitor /usr/local/bin/
WORKDIR /app
COPY cfg.yml /app/cfg.yml
ENTRYPOINT ["flashblocks-monitor"]
