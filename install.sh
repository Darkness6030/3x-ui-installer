#!/usr/bin/env bash
set -euo pipefail
PS4='+[$(date "+%Y-%m-%dT%H:%M:%S%z")] '
set -x

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 BASE_URL USERNAME PASSWORD" >&2
  exit 2
fi

BASE_URL="$1"
USERNAME="$2"
PASSWORD="$3"
COOKIEJAR="$(mktemp)"
trap 'rm -f "$COOKIEJAR"' EXIT
curl -v -c "$COOKIEJAR" -d "username=$USERNAME&password=$PASSWORD" -L "$BASE_URL/login/"

CERT_JSON="$(curl -v -b "$COOKIEJAR" "${BASE_URL%/}/panel/api/server/getNewX25519Cert")"
PRIVATE_KEY="$(echo "$CERT_JSON" | jq -r '.obj.privateKey')"
PUBLIC_KEY="$(echo "$CERT_JSON" | jq -r '.obj.publicKey')"
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ "$PRIVATE_KEY" = "null" ] || [ "$PUBLIC_KEY" = "null" ]; then
  echo "Failed to obtain keys" >&2
  echo "$CERT_JSON" >&2
  exit 3
fi

CLIENT_ID="$(cat /proc/sys/kernel/random/uuid)"
SUBID="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || echo "$(date +%s%N)" )"
EMAIL="$(tr -dc 'a-z0-9' </dev/urandom | head -c 9 || echo "u$(date +%s)")"

SETTINGS_JSON="$(jq -nc --arg id "$CLIENT_ID" --arg email "$EMAIL" --arg sub "$SUBID" '{
  clients: [{
    id: $id,
    flow: "",
    email: $email,
    limitIp: 0,
    totalGB: 0,
    expiryTime: 0,
    enable: true,
    tgId: "",
    subId: $sub,
    comment: "",
    reset: 0
  }],
  decryption: "none",
  encryption: "none"
}')"

STREAM_JSON="$(jq -nc --arg priv "$PRIVATE_KEY" --arg pub "$PUBLIC_KEY" '{
  network: "tcp",
  security: "reality",
  externalProxy: [],
  realitySettings: {
    show: false,
    xver: 0,
    target: "google.com:443",
    serverNames: ["eh.vk.ru","m.vk.ru","sun6-20.userapi.com"],
    privateKey: $priv,
    minClientVer: "",
    maxClientVer: "",
    maxTimediff: 0,
    shortIds: [],
    mldsa65Seed: "",
    settings: {
      publicKey: $pub,
      fingerprint: "chrome",
      serverName: "",
      spiderX: "/",
      mldsa65Verify: ""
    }
  },
  tcpSettings: {
    acceptProxyProtocol: false,
    header: { type: "none" }
  }
}')"

SNIFF_JSON="$(jq -nc '{
  enabled: false,
  destOverride: ["http","tls","quic","fakedns"],
  metadataOnly: false,
  routeOnly: false
}')"

PAYLOAD="$(jq -n \
  --arg settings "$SETTINGS_JSON" \
  --arg streamSettings "$STREAM_JSON" \
  --arg sniffing "$SNIFF_JSON" \
  '{
    up: 0,
    down: 0,
    total: 0,
    remark: "",
    listen: "",
    port: 4321,
    enable: true,
    expiryTime: 0,
    protocol: "vless",
    trafficReset: "never",
    lastTrafficResetTime: 0,
    settings: $settings,
    streamSettings: $streamSettings,
    sniffing: $sniffing
  }')"

curl -v -b "$COOKIEJAR" -H "Content-Type: application/json" -d "$PAYLOAD" "${BASE_URL%/}/panel/api/inbounds/add"
