FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/route53

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Create apps directory with a placeholder so `import /etc/caddy/apps/*`
# does not fatal on older Caddy versions when no apps are deployed yet
RUN mkdir -p /etc/caddy/apps && touch /etc/caddy/apps/.placeholder
