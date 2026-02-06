# Postlite - PostgreSQL wire protocol for SQLite
# Deployed on: oci-f-micro_1 (130.110.251.193)
# Path on server: /home/ubuntu/postlite/

FROM golang:1.21-bookworm AS builder
RUN apt-get update && apt-get install -y gcc libc6-dev
WORKDIR /build
RUN git clone https://github.com/benbjohnson/postlite.git .
RUN CGO_ENABLED=1 go build -tags vtable -o postlite ./cmd/postlite

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/postlite /usr/local/bin/postlite
EXPOSE 5432
ENTRYPOINT ["postlite"]
