#!/bin/bash
read -p "Введите ваш домен (например: example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "Домен не может быть пустым!"; exit 1; }

apt update -y >/dev/null
apt install -y curl nginx certbot python3-certbot-nginx jq sqlite3 qrencode

PORT=54321
INSTALL_LOG="/root/install.log"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF | tee "$INSTALL_LOG"
y
$PORT
EOF

clean_text() { sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' | tr -d '\r[:cntrl:]'; }

USERNAME=$(grep -oP '(?<=Username: )\S+' "$INSTALL_LOG" | clean_text)
PASSWORD=$(grep -oP '(?<=Password: )\S+' "$INSTALL_LOG" | clean_text)
WEBPATH=$(grep -oP '(?<=WebBasePath: )\S+' "$INSTALL_LOG" | clean_text)
PORT=$(grep -oP '(?<=Port: )\d+' "$INSTALL_LOG" | clean_text)

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN.conf"
cat >"$NGINX_CONF" <<EOF
server { server_name $DOMAIN; listen 80; }
EOF
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx
certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@$DOMAIN

cat >"$NGINX_CONF" <<EOF
server {
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    if (\$host = $DOMAIN) { return 301 https://\$host\$request_uri; }
    server_name $DOMAIN;
    listen 80;
    return 404;
}
EOF
nginx -t && systemctl reload nginx

BASE_URL="https://$DOMAIN/$WEBPATH"
COOKIEJAR="$(mktemp)"
trap 'rm -f "$COOKIEJAR"' EXIT
curl -s -c "$COOKIEJAR" -d "username=$USERNAME&password=$PASSWORD" -L "$BASE_URL/login/"

CERT_JSON="$(curl -s -b "$COOKIEJAR" "${BASE_URL%/}/panel/api/server/getNewX25519Cert")"
PRIVATE_KEY="$(echo "$CERT_JSON" | jq -r '.obj.privateKey')"
PUBLIC_KEY="$(echo "$CERT_JSON" | jq -r '.obj.publicKey')"

CLIENT_ID="$(cat /proc/sys/kernel/random/uuid)"
SUBID="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16)"
EMAIL="$(tr -dc 'a-z0-9' </dev/urandom | head -c 9)"

lengths=(2 4 8 12)
SHORTIDS_JSON=$(jq -nc '[]')

for len in "${lengths[@]}"; do
    id=$(tr -dc 'a-f0-9' </dev/urandom | head -c "$len")
    SHORTIDS_JSON=$(jq --arg id "$id" '. += [$id]' <<<"$SHORTIDS_JSON")
done

SETTINGS_JSON="$(jq -nc --arg id "$CLIENT_ID" --arg email "$EMAIL" --arg sub "$SUBID" '{
  clients: [{id: $id, flow: "", email: $email, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, subId: $sub}],
  decryption: "none", encryption: "none"
}')"

STREAM_SETTINGS_JSON="$(jq -nc --arg privateKey "$PRIVATE_KEY" --arg publicKey "$PUBLIC_KEY" --argjson shortIds "$SHORTIDS_JSON" '{
  network: "tcp", security: "reality", externalProxy: [],
  realitySettings: {
    show: false, xver: 0, target: "google.com:443",
    serverNames: ["eh.vk.ru","m.vk.ru","sun6-20.userapi.com"],
    shortIds: $shortIds,
    privateKey: $privateKey, settings: { publicKey: $publicKey, fingerprint: "chrome", spiderX: "/" }
  },
  tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
}')"

SNIFFING_JSON="$(jq -nc '{enabled: false, destOverride: ["http","tls","quic","fakedns"], metadataOnly: false, routeOnly: false}')"

PAYLOAD="$(jq -n --arg settings "$SETTINGS_JSON" --arg streamSettings "$STREAM_SETTINGS_JSON" --arg sniffing "$SNIFFING_JSON" '{
  up: 0, down: 0, total: 0, remark: "",
  listen: "", port: 4321, enable: true,
  expiryTime: 0, protocol: "vless",
  trafficReset: "never", lastTrafficResetTime: 0,
  settings: $settings, streamSettings: $streamSettings, sniffing: $sniffing
}')"

curl -s -b "$COOKIEJAR" -H "Content-Type: application/json" -d "$PAYLOAD" "${BASE_URL%/}/panel/api/inbounds/add"

echo -e "\n###############################################"
echo "Установка 3x-ui завершена успешно!"
echo "Домен: $DOMAIN"
echo "URL доступа: $BASE_URL"
echo "Имя пользователя: $USERNAME"
echo "Пароль: $PASSWORD"
echo "###############################################"

FIRST_SHORTID=$(echo "$SHORTIDS_JSON" | jq -r '.[0]')
VLESS_LINK="vless://${CLIENT_ID}@${DOMAIN}:4321?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=eh.vk.ru&sid=${FIRST_SHORTID}&spx=%2F#${EMAIL}"

echo ""
echo "VLESS Reality ссылка:"
echo "$VLESS_LINK"

echo ""
echo "QR-код ссылки:"
qrencode -t ANSIUTF8 "$VLESS_LINK"
