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
# Render tests for apisix.dataEncryption of the apisix chart.
# Needs helm and yq (https://github.com/mikefarah/yq, v4). Run from the
# repository root after `helm dependency build charts/apisix`.
# Set HELM to use another helm binary.

set -uo pipefail

HELM=${HELM:-helm}
for tool in "${HELM%% *}" yq; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
CHART=charts/apisix
NEW=AbCdEfGhIjKlMnOp
BUILTIN_1=qeddd145sfvddff3
BUILTIN_2=edd1c9f0985e76a2
WARNING="WARNING: APISIX encrypts sensitive plugin fields"

passed=0
failed=0
OUT=""
ERR=""
NOTES=""

check() { # check <description> <command...>
  local desc=$1; shift
  if "$@"; then
    echo "ok   - $desc"; passed=$((passed + 1))
  else
    echo "FAIL - $desc"; failed=$((failed + 1))
  fi
}

render() { # render [helm args...]; sets OUT (manifests) and ERR (stderr), returns helm's exit code
  local errfile rc
  errfile=$(mktemp)
  OUT=$($HELM template apisix "$CHART" --namespace demo "$@" 2>"$errfile")
  rc=$?
  ERR=$(cat "$errfile"); rm -f "$errfile"
  return $rc
}

notes() { # notes [helm args...]; sets NOTES to the rendered NOTES.txt
  NOTES=$($HELM install apisix "$CHART" --namespace demo --dry-run=client "$@" 2>/dev/null | sed -n '/^NOTES:/,$p')
  [ -n "$NOTES" ]
}

config() { yq 'select(.kind == "ConfigMap" and .data["config.yaml"] != null) | .data["config.yaml"]' <<<"$OUT" | yq "$1"; }
config_text() { yq 'select(.kind == "ConfigMap" and .data["config.yaml"] != null) | .data["config.yaml"]' <<<"$OUT"; }
env_ref() { # env_ref <env name>  ->  "<secret>/<key>"
  yq "select(.kind == \"Deployment\") | .spec.template.spec.containers[] | select(.name == \"apisix\") | .env[] | select(.name == \"$1\") | .valueFrom.secretKeyRef | .name + \"/\" + .key" <<<"$OUT"
}
key_envs() { # names of the keyring environment variables, one per line
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "apisix") | .env[] | select(.name | test("^APISIX_DATA_ENCRYPTION_KEY_")) | .name' <<<"$OUT"
}
is() { [ "$1" = "$2" ] || { echo "       expected '$2', got '$1'" >&2; return 1; }; }
fails_with() { # fails_with <message part> [helm args...]
  local text=$1; shift
  if render "$@"; then echo "       rendered without an error" >&2; return 1; fi
  grep -qF -- "$text" <<<"$ERR" || { echo "       error was: $ERR" >&2; return 1; }
}
warns() { grep -qF -- "$WARNING" <<<"$NOTES"; }
does_not_warn() { ! warns; }

# --- defaults: APISIX's built-in keyring, with a warning ------------------------

render
check "default: encryption stays enabled" is "$(config '.apisix.data_encryption.enable_encrypt_fields')" true
check "default: no keyring is rendered, APISIX keeps its built-in one" is "$(config '.apisix.data_encryption.keyring')" null
check "default: no keyring environment variable" is "$(key_envs)" ""
notes
check "default: NOTES warns that the built-in keyring is public" warns

# --- a keyring in the values ---------------------------------------------------

render --set-json "apisix.dataEncryption.keyring=[\"$NEW\",\"$BUILTIN_1\",\"$BUILTIN_2\"]"
check "inline: the keyring is rendered in order" is "$(config '.apisix.data_encryption.keyring | join(",")')" "$NEW,$BUILTIN_1,$BUILTIN_2"
check "inline: the keys are quoted" grep -qF -- "- \"$NEW\"" <<<"$(config_text)"
notes --set-json "apisix.dataEncryption.keyring=[\"$NEW\"]"
check "inline: no warning about the built-in keyring" does_not_warn

render --set-json 'apisix.dataEncryption.keyring=["1234567890123456"]'
check "inline: a key made of digits stays a string" is "$(config '.apisix.data_encryption.keyring[0] | tag')" '!!str'

render --set apisix.dataEncryption.enableEncryptFields=false
check "disabled: enable_encrypt_fields is rendered false" is "$(config '.apisix.data_encryption.enable_encrypt_fields')" false
notes --set apisix.dataEncryption.enableEncryptFields=false
check "disabled: no warning about the built-in keyring" does_not_warn

# --- a keyring in an existing Secret -------------------------------------------

render --set apisix.dataEncryption.secretName=apisix-keyring
check "secret: one key by default" is "$(key_envs)" APISIX_DATA_ENCRYPTION_KEY_1
check "secret: it reads the key key1" is "$(env_ref APISIX_DATA_ENCRYPTION_KEY_1)" apisix-keyring/key1
check "secret: config.yaml refers to the variable" is "$(config '.apisix.data_encryption.keyring | join(",")')" '${{APISIX_DATA_ENCRYPTION_KEY_1}}'

render --set apisix.dataEncryption.secretName=apisix-keyring --set-json 'apisix.dataEncryption.secretKeys=["new","old"]'
check "secret: one variable per key, in keyring order" is "$(env_ref APISIX_DATA_ENCRYPTION_KEY_1),$(env_ref APISIX_DATA_ENCRYPTION_KEY_2)" apisix-keyring/new,apisix-keyring/old
check "secret: config.yaml lists the variables in the same order" is "$(config '.apisix.data_encryption.keyring | join(",")')" '${{APISIX_DATA_ENCRYPTION_KEY_1}},${{APISIX_DATA_ENCRYPTION_KEY_2}}'
notes --set apisix.dataEncryption.secretName=apisix-keyring
check "secret: no warning about the built-in keyring" does_not_warn

render --set apisix.fullCustomConfig.enabled=true --set apisix.dataEncryption.secretName=apisix-keyring
check "secret with fullCustomConfig: the variable is still set for the custom config" is "$(env_ref APISIX_DATA_ENCRYPTION_KEY_1)" apisix-keyring/key1

# --- values that cannot work -----------------------------------------------------

check "fail: the first key is the first built-in key" fails_with "the first key, which APISIX encrypts with, is one of the built-in keys" \
  --set-json "apisix.dataEncryption.keyring=[\"$BUILTIN_1\",\"$NEW\"]"
check "fail: the first key is the second built-in key" fails_with "the first key, which APISIX encrypts with, is one of the built-in keys" \
  --set-json "apisix.dataEncryption.keyring=[\"$BUILTIN_2\"]"
values=$(mktemp)
printf 'apisix:\n  dataEncryption:\n    keyring:\n      - %s\n      - 1234567890123456\n' "$NEW" >"$values"
check "fail: an unquoted number in the keyring" fails_with "apisix.dataEncryption.keyring: entry 2 is not a string" -f "$values"
check "fail: the error does not print the key" bash -c '! grep -qF 1234567890123456 <<<"$1"' _ "$ERR"
rm -f "$values"
check "fail: keyring and secretName together" fails_with "set either keyring or secretName, not both" \
  --set-json "apisix.dataEncryption.keyring=[\"$NEW\"]" --set apisix.dataEncryption.secretName=apisix-keyring
check "fail: secretName without secretKeys" fails_with "apisix.dataEncryption.secretKeys must list the keys" \
  --set apisix.dataEncryption.secretName=apisix-keyring --set-json 'apisix.dataEncryption.secretKeys=[]'

# --- when the warning applies -----------------------------------------------------

notes --set apisix.deployment.mode=standalone
check "standalone (file): no warning, APISIX does not encrypt without etcd" does_not_warn
notes --set apisix.deployment.role_traditional.config_provider=yaml --set etcd.enabled=false
check "standalone (API): no warning, APISIX does not encrypt without etcd" does_not_warn
notes --set apisix.fullCustomConfig.enabled=true
check "fullCustomConfig: no warning, the custom config decides" does_not_warn
notes --set apisix.deployment.mode=decoupled --set apisix.deployment.role=data_plane
check "decoupled data plane: warns, it decrypts with the same keyring" warns
notes --set apisix.deployment.mode=decoupled --set apisix.deployment.role=control_plane
check "decoupled control plane: warns" warns
notes --set-json 'apisix.data_encryption={"keyring":["AbCdEfGhIjKlMnOp"]}'
check "the old apisix.data_encryption value: NOTES says it is not read" grep -qF "apisix.data_encryption is not read by this chart" <<<"$NOTES"

echo
echo "passed: $passed, failed: $failed"
[ "$failed" -eq 0 ]
