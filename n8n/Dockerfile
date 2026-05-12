ARG N8N_VERSION=latest

FROM alpine:3.20 AS tools

RUN apk add --no-cache bash curl ca-certificates

RUN set -eux; \
    mkdir -p /out/bin /out/usr/bin /out/etc/ssl/certs; \
    cp /bin/bash /out/bin/bash; \
    cp /usr/bin/curl /out/usr/bin/curl; \
    cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/; \
    for bin in /bin/bash /usr/bin/curl; do \
      ldd "$bin" \
        | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p; s/^\s*\(\/[^ ]*\).*/\1/p' \
        | while read -r lib; do \
            mkdir -p "/out$(dirname "$lib")"; \
            cp -L "$lib" "/out$lib"; \
          done; \
    done

FROM n8nio/n8n:${N8N_VERSION}

USER root

COPY --from=tools /out/ /

USER node