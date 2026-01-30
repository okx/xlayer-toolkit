FROM okexchain/go-builder:v1  AS builder

RUN apt-get install -y wget \
    && wget -qO- https://get.docker.com | sh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY ./cmd  ./cmd
COPY ./packages  ./packages
RUN go build -o bin/replayor ./cmd/replayor/main.go

WORKDIR /app

FROM okexchain/go-builder:v1

# Install certs
# RUN apk add --no-cache ca-certificates
# COPY ./oplabs.crt /usr/local/share/ca-certificates/oplabs.crt
# RUN chmod 644 /usr/local/share/ca-certificates/oplabs.crt && update-ca-certificates

WORKDIR /app

COPY --from=builder /app/bin/replayor /bin/replayor

CMD ["/app/replayor.sh"]
