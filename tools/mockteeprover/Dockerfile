FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /mock-tee-prover .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates wget
COPY --from=builder /mock-tee-prover /usr/local/bin/mock-tee-prover

EXPOSE 8690

ENTRYPOINT ["mock-tee-prover"]
