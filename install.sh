#!/bin/bash
set -euo pipefail

read -p "Введите ваш домен (например: example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "Домен не может быть пустым!"
  exit 1
fi

apt update -y
apt install -y curl nginx certbot python3-certbot-nginx jq sqlite3

PORT=54321
INSTALL_LOG="/root/install.log"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF | tee "$INSTALL_LOG"
y
$PORT
EOF

clean_text() {
  sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' | tr -d '\r[:cntrl:]'
}

USERNAME=$(grep -oP '(?<=Username: )\S+' "$INSTALL_LOG" | clean_text)
PASSWORD=$(grep -oP '(?<=Password: )\S+' "$INSTALL_LOG" | clean_text)
WEBPATH=$(grep -oP '(?<=WebBasePath: )\S+' "$INSTALL_LOG" | clean_text)
PORT=$(grep -oP '(?<=Port: )\d+' "$INSTALL_LOG" | clean_text)

if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$WEBPATH" || -z "$PORT" ]]; then
  DB_PATH="/etc/x-ui/x-ui.db"
  if [[ -f "$DB_PATH" ]]; then
    USERNAME=$(sqlite3 "$DB_PATH" "SELECT username FROM users LIMIT 1;" 2>/dev/null)
    PASSWORD=$(sqlite3 "$DB_PATH" "SELECT password FROM users LIMIT 1;" 2>/dev/null)
    WEBPATH=$(sqlite3 "$DB_PATH" "SELECT webBasePath FROM settings LIMIT 1;" 2>/dev/null)
  fi
fi

WEBPATH=${WEBPATH:-admin}

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN.conf"
cat > "$NGINX_CONF" <<EOF
server { server_name $DOMAIN; listen 80; }
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@$DOMAIN

cat > "$NGINX_CONF" <<EOF
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

ACCESS_URL="https://$DOMAIN/$WEBPATH"
echo ""
echo "###############################################"
echo "Установка 3x-ui завершена успешно!"
echo "Домен: $DOMAIN"
echo "URL доступа: $ACCESS_URL"
echo "Имя пользователя: $USERNAME"
echo "Пароль: $PASSWORD"
echo "###############################################"

echo ""
echo "Добавление нового inbound через API..."

BASE_URL="$ACCESS_URL"
COOKIEJAR="$(mktemp)"
trap 'rm -f "$COOKIEJAR"' EXIT

curl -s -c "$COOKIEJAR" -d "username=$USERNAME&password=$PASSWORD" -L "$BASE_URL/login/" >/dev/null

CERT_JSON="$(curl -s -b "$COOKIEJAR" "${BASE_URL%/}/panel/api/server/getNewX25519Cert")"
PRIVATE_KEY="$(echo "$CERT_JSON" | jq -r '.obj.privateKey')"
PUBLIC_KEY="$(echo "$CERT_JSON" | jq -r '.obj.publicKey')"

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || "$PRIVATE_KEY" == "null" || "$PUBLIC_KEY" == "null" ]]; then
  echo "Ошибка: не удалось получить ключи."
  exit 1
fi

CLIENT_ID="$(cat /proc/sys/kernel/random/uuid)"
SUBID="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16)"
EMAIL="$(tr -dc 'a-z0-9' </dev/urandom | head -c 9)"

SETTINGS_JSON="$(jq -nc --arg id "$CLIENT_ID" --arg email "$EMAIL" --arg sub "$SUBID" '{
  clients: [{id: $id, flow: "", email: $email, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, subId: $sub}],
  decryption: "none", encryption: "none"
}')"

STREAM_JSON="$(jq -nc --arg priv "$PRIVATE_KEY" --arg pub "$PUBLIC_KEY" '{
  network: "tcp", security: "reality", externalProxy: [],
  realitySettings: {
    show: false, xver: 0, target: "google.com:443",
    serverNames: ["eh.vk.ru","m.vk.ru","sun6-20.userapi.com"],
    privateKey: $priv, settings: { publicKey: $pub, fingerprint: "chrome", spiderX: "/" }
  },
  tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
}')"

SNIFF_JSON="$(jq -nc '{enabled: false, destOverride: ["http","tls","quic","fakedns"], metadataOnly: false, routeOnly: false}')"

PAYLOAD="$(jq -n \
  --arg settings "$SETTINGS_JSON" \
  --arg streamSettings "$STREAM_JSON" \
  --arg sniffing "$SNIFF_JSON" \
  '{
    up: 0, down: 0, total: 0, remark: "",
    listen: "", port: 4321, enable: true,
    expiryTime: 0, protocol: "vless",
    trafficReset: "never", lastTrafficResetTime: 0,
    settings: $settings, streamSettings: $streamSettings, sniffing: $sniffing
  }')"

curl -s -b "$COOKIEJAR" -H "Content-Type: application/json" -d "$PAYLOAD" "${BASE_URL%/}/panel/api/inbounds/add" >/dev/null

echo ""
echo "Inbound добавлен успешно!"
echo "Данные для входа:"
echo "URL: $ACCESS_URL"
echo "Имя пользователя: $USERNAME"
echo "Пароль: $PASSWORD"
