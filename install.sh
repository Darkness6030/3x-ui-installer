#!/bin/bash
set -e

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

USERNAME=$(grep -oP '(?<=Username: )\S+' "$INSTALL_LOG" | tr -d '\r[:cntrl:]')
PASSWORD=$(grep -oP '(?<=Password: )\S+' "$INSTALL_LOG" | tr -d '\r[:cntrl:]')
WEBPATH=$(grep -oP '(?<=WebBasePath: )\S+' "$INSTALL_LOG" | tr -d '\r[:cntrl:]')
PORT=$(grep -oP '(?<=Port: )\d+' "$INSTALL_LOG" | tr -d '\r[:cntrl:]')

if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$WEBPATH" || -z "$PORT" ]]; then
  DB_PATH="/etc/x-ui/x-ui.db"
  if [[ -f "$DB_PATH" ]]; then
    USERNAME=$(sqlite3 "$DB_PATH" "SELECT username FROM users LIMIT 1;" 2>/dev/null)
    PASSWORD=$(sqlite3 "$DB_PATH" "SELECT password FROM users LIMIT 1;" 2>/dev/null)
    WEBPATH=$(sqlite3 "$DB_PATH" "SELECT webBasePath FROM settings LIMIT 1;" 2>/dev/null)
  fi
fi

if [[ -z "$WEBPATH" ]]; then
  WEBPATH="admin"
fi

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN.conf"
cat > "$NGINX_CONF" <<EOF
server {
    server_name $DOMAIN;
    listen 80;
}
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
    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }
    server_name $DOMAIN;
    listen 80;
    return 404;
}
EOF

nginx -t && systemctl reload nginx

ACCESS_URL="https://$DOMAIN/$WEBPATH"
echo ""
echo "###############################################"
echo "✅ Установка 3x-ui завершена успешно!"
echo "Домен: $DOMAIN"
echo "Порт: $PORT"
echo "URL доступа: $ACCESS_URL"
echo "Имя пользователя: $USERNAME"
echo "Пароль: $PASSWORD"
echo "###############################################"
