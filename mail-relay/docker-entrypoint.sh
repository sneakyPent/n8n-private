#!/bin/sh
set -eu

: "${MAIL_UPSTREAM_HOST:?MAIL_UPSTREAM_HOST is required}"

MAIL_UPSTREAM_PORT="${MAIL_UPSTREAM_PORT:-587}"
MAIL_RELAY_NETWORKS="${MAIL_RELAY_NETWORKS:-172.20.0.0/24}"
MAIL_TLS_SECURITY_LEVEL="${MAIL_TLS_SECURITY_LEVEL:-encrypt}"
MAIL_RELAY_HOSTNAME="${MAIL_RELAY_HOSTNAME:-mail-relay.local}"

postconf -e "myhostname = ${MAIL_RELAY_HOSTNAME}"
postconf -e "relayhost = [${MAIL_UPSTREAM_HOST}]:${MAIL_UPSTREAM_PORT}"
postconf -e "mynetworks = 127.0.0.0/8, ${MAIL_RELAY_NETWORKS}"
postconf -e "smtp_tls_security_level = ${MAIL_TLS_SECURITY_LEVEL}"

# Force Postfix to use native OS host lookup so /etc/hosts (extra_hosts) works.
postconf -e "smtp_host_lookup = native"

# Explicit TLS toggle
if [ "$MAIL_TLS_SECURITY_LEVEL" = "none" ]; then
  postconf -e "smtp_use_tls = no"
else
  postconf -e "smtp_use_tls = yes"
fi

# Make resolver/hosts files available to Postfix runtime environment.
mkdir -p /var/spool/postfix/etc

for f in hosts resolv.conf nsswitch.conf services; do
  if [ -f "/etc/$f" ]; then
    cp -f "/etc/$f" "/var/spool/postfix/etc/$f"
  fi
done

if [ -n "${MAIL_UPSTREAM_USERNAME:-}" ] && [ -n "${MAIL_UPSTREAM_PASSWORD:-}" ]; then
  printf "[%s]:%s %s:%s\n" \
    "$MAIL_UPSTREAM_HOST" \
    "$MAIL_UPSTREAM_PORT" \
    "$MAIL_UPSTREAM_USERNAME" \
    "$MAIL_UPSTREAM_PASSWORD" \
    > /etc/postfix/sasl_passwd

  postmap hash:/etc/postfix/sasl_passwd
  chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db

  postconf -e "smtp_sasl_auth_enable = yes"
  postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
else
  rm -f /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
  postconf -e "smtp_sasl_auth_enable = no"
  postconf -e "smtp_sasl_password_maps ="
fi

postfix check
exec postfix start-fg
