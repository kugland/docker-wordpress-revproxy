FROM nginx:1.22.0-alpine

LABEL org.opencontainers.image.title="wordpress-revproxy" \
      org.opencontainers.image.description="Reverse proxy (nginx) docker image for my WordPress stack" \
      org.opencontainers.image.source="https://github.com/kugland/docker-wordpress-revproxy" \
      org.opencontainers.image.authors="André Kugland <kugland@gmail.com>"

RUN apk add --no-cache bash openssl && rm -rf /var/cache/apk/*

COPY ./default.conf /etc/nginx/conf.d/00-default.conf

COPY ./gen-configs.sh /docker-entrypoint.d/00-gen-configs.sh
RUN chmod +x /docker-entrypoint.d/00-gen-configs.sh

COPY ./cloudflare.conf /etc/nginx/snippets/cloudflare.conf
COPY ./origin-pull-ca.pem /etc/nginx/ssl/origin-pull-ca.pem

VOLUME [ "/etc/nginx/certs" ]
