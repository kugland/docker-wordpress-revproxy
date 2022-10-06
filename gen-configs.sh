#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

declare -A SITES

define_site() {
  # Usage: define_site [--default-www|--default-non-www] DOMAIN UPSTREAM:PORT
  #
  # Define a site.
  #
  # If --default-www is specified, then the default domain is www.DOMAIN.
  # If --default-non-www is specified, then the default domain is DOMAIN.
  local default_www=www
  local domain
  local upstream_host
  local upstream_port
  REPLY="$(getopt -o '' --long default-www,default-non-www -n "define_site" -- "$@")"
  if [ $? != 0 ]; then
    exit 1
  fi
  eval set -- "$REPLY"
  while true; do
    case "$1" in
      --default-www) default_www=www; shift ;;
      --default-non-www) default_www=non-www; shift ;;
      --) shift; break ;;
    esac
  done
  domain="$1"
  upstream_host="${2/:*/}"
  upstream_port="${2/*:/}"
  if [ -z "$domain" ] || [ -z "$upstream_host" ] || [ -z "$upstream_port" ]; then
    echo "Usage: define_site [--default-(non-)www] DOMAIN UPSTREAM:PORT"
    exit 1
  fi
  SITES[$domain]="$upstream_host;$upstream_port;$default_www"
  echo "Site defined: $domain, $upstream_host:$upstream_port, $default_www"
}

redirect() {
  SITES[$1]="redirect;$1;$2"
}

source /etc/revproxy-sites.conf

generate_config() {
  local domain="$1"
  local upstream_host="$2"
  local upstream_port="$3"
  local default_www="$4"

  echo "Setting up config for reverse proxy: ${domain} -> ${upstream_host}:${upstream_port}"
  (
    echo "server {"
    echo "  server_name ${domain} www.${domain};"
    echo "  client_max_body_size 64M;"
    if [ "${default_www}" = "non-www" ]; then
      echo "  if (\$host = www.${domain}) {"
      echo "    return 302 https://${domain}\$request_uri;"
      echo "  }"
    elif [ "${default_www}" = "www" ]; then
      echo "  if (\$host = ${domain}) {"
      echo "    return 302 https://www.${domain}\$request_uri;"
      echo "  }"
    fi
    echo "  location / {"
    echo "    resolver 127.0.0.11 ipv6=off;"
    echo "    set \$upstream http://${upstream_host}:${upstream_port};"
    echo "    proxy_pass \$upstream;"
    echo "    proxy_pass_request_headers on;"
    echo "    proxy_set_header Host \$host;"
    echo "    proxy_set_header X-Real-IP \$remote_addr;"
    echo "    proxy_set_header X-Forwarded-For \$remote_addr;"
    echo "    proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "    proxy_set_header Https \$https;"
    echo "    proxy_set_header X-Server-Name \$server_name;"
    echo "    proxy_set_header X-Server-Port \$server_port;"
    echo "    proxy_set_header X-Request-Scheme \$scheme;"
    echo "  }"
    echo "  listen 443 ssl;"
    echo "  ssl_certificate        /etc/nginx/certs/${domain}.crt;"
    echo "  ssl_certificate_key    /etc/nginx/certs/${domain}.key;"
    echo "  include snippets/cloudflare.conf;"
    echo "}"
  ) > "/etc/nginx/conf.d/99-${domain}.conf"
}

generate_redirect() {
  local domain="$1"
  local target="$2"

  echo "Setting up redirect: https://${domain} -> https://${target}"
  (
    echo "server {"
    echo "  server_name ${domain};"
    echo "  return 302 https://${target}\$request_uri;"
    echo "  listen 443 ssl;"
    echo "  ssl_certificate        /etc/nginx/certs/${domain}.crt;"
    echo "  ssl_certificate_key    /etc/nginx/certs/${domain}.key;"
    echo "  include snippets/cloudflare.conf;"
    echo "}"
  ) > "/etc/nginx/conf.d/99-${domain}.conf"
}

generate_certificate() {
  local domain="$1"
  passkey="/tmp/${domain}.pass.key"
  cert="/etc/nginx/certs/${domain}.crt"
  privkey="/etc/nginx/certs/${domain}.key"
  csr="/tmp/${domain}.csr"
  if [ ! -f "${cert}" ] || [ ! -f "${privkey}" ]; then
    echo "Generating self-signed certificate for ${domain}."
    password="$(openssl rand -base64 32)"
    openssl genrsa -des3 -passout pass:"$password" -out "${passkey}" 2048
    openssl rsa -passin pass:"$password" -in "${passkey}" -out "${privkey}"
    openssl req -new -key "${privkey}" -out "${csr}" \
      -subj "/C=US/ST=DC/L=Washington/O=OrgName/OU=IT Department/CN=${domain}"
    openssl x509 -req -days 365 -in "${csr}" -signkey "${privkey}" -out "${cert}"
    chmod 0600 "${privkey}" "${cert}"
    rm "${passkey}"
    rm "${csr}"
  fi
}

generate_certificate default
for domain in "${!SITES[@]}"; do
  upstream_host="$(echo "${SITES[$domain]}" | cut -d';' -f1)"
  if [ "${upstream_host}" == "redirect" ]; then  
    from="$(echo "${SITES[$domain]}" | cut -d';' -f2)"
    target="$(echo "${SITES[$domain]}" | cut -d';' -f3)"
    generate_redirect "$from" "$target"
  else
    upstream_port="$(echo "${SITES[$domain]}" | cut -d';' -f2)"
    default_www="$(echo "${SITES[$domain]}" | cut -d';' -f3)"

    generate_config "${domain}" "${upstream_host}" "${upstream_port}" "${default_www}"
  fi
  generate_certificate "${domain}"
done
