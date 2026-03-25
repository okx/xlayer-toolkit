FROM golang:1.23-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o mockteerpc ./cmd/mockteerpc

FROM alpine:3.21

RUN apk --no-cache add ca-certificates

WORKDIR /app
COPY --from=builder /app/mockteerpc .

EXPOSE 8090

ENTRYPOINT ["./mockteerpc"]
CMD ["--addr", ":8090"]
