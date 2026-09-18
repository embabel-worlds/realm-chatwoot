#!/bin/sh
# First boot for the demo Chatwoot. Idempotent: a second `up` finds the secrets, the
# schema and the token, and does nothing.
set -eu

if [ ! -s /state/secrets.env ]; then
  # Rails will not boot without it, and regenerating it later would invalidate every
  # session and encrypted column — so it is made once and kept with the volume.
  echo "SECRET_KEY_BASE=$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')" > /state/secrets.env
  echo "init: generated secrets"
fi
set -a; . /state/secrets.env; set +a

echo "init: preparing the database"
bundle exec rails db:chatwoot_prepare

if [ -s /state/chatwoot.env ]; then
  echo "init: account and token already exist"
else
  echo "init: creating the account, its agent and an API inbox"
  bundle exec rails runner /stack/bootstrap.rb
  [ -s /state/chatwoot.env ] || { echo "init: token was not written" >&2; exit 1; }
fi
echo "init: done"
