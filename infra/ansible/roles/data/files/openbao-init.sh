#!/bin/sh
# One time OpenBao setup. Unseal keys go to two operators, never to git.
set -e
export BAO_ADDR=http://10.10.1.20:8200
bao secrets enable transit
bao secrets enable -path=tenants kv-v2
bao auth enable approle
cat <<'POL' | bao policy write cortex-app -
# Key name comes from TenantContext; the model never names a key.
path "transit/encrypt/tenant-*" { capabilities = ["update"] }
path "transit/decrypt/tenant-*" { capabilities = ["update"] }
path "transit/datakey/plaintext/tenant-*" { capabilities = ["update"] }
path "tenants/data/*" { capabilities = ["read"] }
POL
bao write auth/approle/role/web    token_policies=cortex-app token_ttl=1h
bao write auth/approle/role/worker token_policies=cortex-app token_ttl=1h
# Per tenant at onboarding: bao write -f transit/keys/tenant-<id>
touch /srv/cortex/.openbao-initialised
