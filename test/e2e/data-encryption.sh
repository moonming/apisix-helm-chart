#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# End-to-end tests for apisix.dataEncryption of the apisix chart, against a
# real cluster (for example kind) with real APISIX and etcd pods. They read
# what APISIX stored in etcd and decrypt it with openssl, to check which key
# encrypted it.
# Needs kubectl, helm, curl, openssl and yq (v4). Run from the repository root
# after `helm dependency build charts/apisix`.
#
#   KEEP_NAMESPACES=1  keep the test namespaces for debugging

set -uo pipefail

HELM=${HELM:-helm}
CHART=${CHART:-charts/apisix}
BUILTIN_KEY=qeddd145sfvddff3

random_letters() { LC_ALL=C tr -dc 'A-Za-z' </dev/urandom | head -c "$1"; }
ADMIN_KEY=$(random_letters 32)
KEY_1=$(random_letters 16)
KEY_2=$(random_letters 16)
COMMON=(--set apisix.admin.credentials.admin="$ADMIN_KEY"
        --set etcd.replicaCount=1
        --wait --timeout 10m)

passed=0
failed=0
PF_PIDS=()
NAMESPACES=()
ADMIN_PORT=19180
GATEWAY_PORT=19080

cleanup() {
  stop_port_forwards
  if [ "${KEEP_NAMESPACES:-}" != 1 ]; then
    for ns in "${NAMESPACES[@]:-}"; do
      [ -n "$ns" ] || continue
      $HELM uninstall --namespace "$ns" apisix --wait >/dev/null 2>&1
      kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1
    done
  fi
}
trap cleanup EXIT

check() { # check <description> <command...>
  local desc=$1; shift
  if "$@"; then
    echo "ok   - $desc"; passed=$((passed + 1))
  else
    echo "FAIL - $desc"; failed=$((failed + 1))
  fi
}

wait_for() { # wait_for <seconds> <command...>: retry until the command succeeds
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 2
  done
}

stop_port_forwards() {
  for pid in "${PF_PIDS[@]:-}"; do [ -n "$pid" ] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }; done
  PF_PIDS=()
}

connect() { # connect <namespace>: port-forward the Admin API and the gateway of a ready release
  stop_port_forwards
  kubectl --namespace "$1" rollout status deployment/apisix --timeout=300s >/dev/null
  kubectl --namespace "$1" port-forward svc/apisix-admin "$ADMIN_PORT:9180" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  kubectl --namespace "$1" port-forward svc/apisix-gateway "$GATEWAY_PORT:80" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  wait_for 60 curl -s -o /dev/null "http://127.0.0.1:$ADMIN_PORT/" &&
    wait_for 60 curl -s -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/"
}

admin_put() { # admin_put <path> <json>: prints the status code
  curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$ADMIN_PORT$1" \
    -H "X-API-KEY: $ADMIN_KEY" -H 'Content-Type: application/json' -d "$2"
}

created() { case "$1" in 200|201) return 0 ;; *) echo "       status $1" >&2; return 1 ;; esac; }

add_route() { # a route that only lets consumers of key-auth through
  created "$(admin_put /apisix/admin/routes/e2e '{"uri":"/e2e","plugins":{"key-auth":{},"mocking":{"response_status":200,"response_example":"ok"}}}')"
}

add_consumer() { # add_consumer <name> <key-auth key>
  local body="{\"username\":\"$1\",\"plugins\":{\"key-auth\":{\"key\":\"$2\"}}}"
  created "$(admin_put /apisix/admin/consumers "$body")"
}

admin_get_key() { # admin_get_key <consumer>: the key-auth key as the Admin API returns it
  curl -s "http://127.0.0.1:$ADMIN_PORT/apisix/admin/consumers/$1" -H "X-API-KEY: $ADMIN_KEY" |
    yq -p json '.value.plugins."key-auth".key'
}

resave_consumer() { # resave_consumer <consumer>: GET it and PUT it back without the
  # create_time and update_time fields, which a PUT rejects, as the README describes
  local body
  body=$(curl -s "http://127.0.0.1:$ADMIN_PORT/apisix/admin/consumers/$1" -H "X-API-KEY: $ADMIN_KEY" |
    yq -p json -o json -I0 '.value | del(.create_time, .update_time)')
  created "$(admin_put /apisix/admin/consumers "$body")"
}

gateway_code() { # gateway_code <apikey>: status code of /e2e for that key
  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GATEWAY_PORT/e2e" -H "apikey: $1"
}

# accepts <apikey>: the gateway lets the key through. APISIX syncs from etcd in
# the background, so wait for a consumer that was just added. Check rejects only
# after an accepts on the same pods, so that the consumers are already synced.
accepts() { wait_for 30 test "$(gateway_code "$1")" = 200; }
rejects() { is "$(gateway_code "$1")" 401; }
is() { [ "$1" = "$2" ] || { echo "       expected '$2', got '$1'" >&2; return 1; }; }

stored_key() { # stored_key <namespace> <consumer>: the key-auth key as stored in etcd
  kubectl --namespace "$1" exec apisix-etcd-0 -- etcdctl get "/apisix/consumers/$2" --print-value-only |
    yq -p json '.plugins."key-auth".key'
}

decrypt() { # decrypt <key> <stored value>: AES-128-CBC with the key as its IV, as APISIX does
  local hex value=$2
  hex=$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')
  value=${value#'$ENC$v1$'}   # marker that newer APISIX versions put in front of the ciphertext
  printf '%s' "$value" | openssl base64 -d -A 2>/dev/null |
    openssl enc -d -aes-128-cbc -K "$hex" -iv "$hex" 2>/dev/null
}

not_encrypted_with() { # not_encrypted_with <namespace> <consumer> <key> <plain text>
  [ "$(decrypt "$3" "$(stored_key "$1" "$2")")" != "$4" ]
}

encrypted_with() { # encrypted_with <namespace> <consumer> <key> <plain text>
  local stored
  stored=$(stored_key "$1" "$2")
  [ -n "$stored" ] && [ "$stored" != "$4" ] || { echo "       stored in clear text: '$stored'" >&2; return 1; }
  [ "$(decrypt "$3" "$stored")" = "$4" ] || { echo "       '$stored' does not decrypt with that key" >&2; return 1; }
}

new_namespace() { NAMESPACES+=("$1"); kubectl create namespace "$1" >/dev/null; }

install() { # install <namespace> [helm args...]
  local ns=$1; shift
  $HELM install apisix "$CHART" --namespace "$ns" "${COMMON[@]}" "$@" >/dev/null
}

upgrade() { # upgrade <namespace> [helm args...]
  local ns=$1; shift
  $HELM upgrade apisix "$CHART" --namespace "$ns" "${COMMON[@]}" "$@" >/dev/null
}

# --- a keyring from an existing Secret, then a rotation ------------------------

NS=de-secret
new_namespace "$NS"
kubectl --namespace "$NS" create secret generic apisix-keyring --from-literal=key1="$KEY_1" --save-config >/dev/null
check "secret: the release installs" install "$NS" --set apisix.dataEncryption.secretName=apisix-keyring
check "secret: connected" connect "$NS"
check "secret: route created" add_route
check "secret: consumer jack created" add_consumer jack jack-key
check "secret: jack's key is stored encrypted with the key from the Secret" encrypted_with "$NS" jack "$KEY_1" jack-key
check "secret: it is not encrypted with the built-in key" not_encrypted_with "$NS" jack "$BUILTIN_KEY" jack-key
check "secret: the gateway accepts jack's key" accepts jack-key
check "secret: the gateway rejects a wrong key" rejects wrong-key

# rotate: put a new key first and keep the old one, so jack's key stays readable
kubectl --namespace "$NS" create secret generic apisix-keyring --from-literal=key1="$KEY_1" --from-literal=key2="$KEY_2" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
check "rotation: the upgrade succeeds" upgrade "$NS" --set apisix.dataEncryption.secretName=apisix-keyring \
  --set-json 'apisix.dataEncryption.secretKeys=["key2","key1"]'
check "rotation: connected to the new pods" connect "$NS"
check "rotation: jack's old key still works" accepts jack-key
check "rotation: consumer rose created" add_consumer rose rose-key
check "rotation: rose's key is encrypted with the new first key" encrypted_with "$NS" rose "$KEY_2" rose-key
check "rotation: the gateway accepts rose's key" accepts rose-key

# --- moving an existing release off the built-in keyring -----------------------

NS=de-migrate
new_namespace "$NS"
check "built-in: the release installs with the default values" install "$NS"
check "built-in: connected" connect "$NS"
check "built-in: route created" add_route
check "built-in: consumer old created" add_consumer old old-key
check "built-in: consumer stale created" add_consumer stale stale-key
check "built-in: by default the data is encrypted with the public built-in key" encrypted_with "$NS" old "$BUILTIN_KEY" old-key

check "migration: the upgrade with a new key first and the built-in key after it succeeds" \
  upgrade "$NS" --set-json "apisix.dataEncryption.keyring=[\"$KEY_1\",\"$BUILTIN_KEY\"]"
check "migration: connected to the new pods" connect "$NS"
check "migration: the old consumers still work" accepts old-key
check "migration: the old consumers still work (stale)" accepts stale-key
check "migration: a GET of the Admin API returns the key decrypted" is "$(admin_get_key old)" old-key
check "migration: consumer old saved again with what the GET returned" resave_consumer old
check "migration: old is now encrypted with the new key" encrypted_with "$NS" old "$KEY_1" old-key
check "migration: consumer new created" add_consumer new new-key
check "migration: new data is encrypted with the new key" encrypted_with "$NS" new "$KEY_1" new-key

check "dropping the built-in key: the upgrade succeeds" upgrade "$NS" --set-json "apisix.dataEncryption.keyring=[\"$KEY_1\"]"
check "dropping the built-in key: connected to the new pods" connect "$NS"
check "dropping the built-in key: data encrypted with the new key works" accepts new-key
check "dropping the built-in key: data saved again works" accepts old-key
check "dropping the built-in key: data not saved again can no longer be read" rejects stale-key

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
