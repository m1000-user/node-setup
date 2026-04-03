#!/bin/bash

# Останавливаем скрипт при ошибках
set -e

# --- СБОР ДАННЫХ ---
read -p "Введите ваш Email (для SSL): " EMAIL
read -p "Введите ваш Домен (например, node.example.com): " DOMAIN
read -p "Введите SECRET_KEY (из панели): " SECRET_KEY
echo "------------------------------------------------"

echo "--- 1. Установка Docker и зависимостей ---"
sudo curl -fsSL https://get.docker.com | sh
sudo apt-get update
sudo apt-get install -y cron socat curl ufw expect

echo "--- 2. Установка acme.sh ---"
curl https://get.acme.sh | sh -s email=$EMAIL
export LE_WORKING_DIR="${HOME}/.acme.sh"
# Настраиваем алиас для текущей сессии
alias acme.sh="${HOME}/.acme.sh/acme.sh"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# Подготовка папок
mkdir -p /opt/remnanode/nginx
mkdir -p /opt/fluffychat-web

echo "--- 3. Выпуск SSL сертификата ---"
~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN \
    --key-file /opt/remnanode/nginx/privkey.key \
    --fullchain-file /opt/remnanode/nginx/fullchain.pem \
    --alpn --tlsport 8443

echo "--- 4. Настройка сети и FluffyChat ---"
docker network create remna-network || true

cat <<EOF > /opt/fluffychat-web/docker-compose.yml
services:
  element-web:
    container_name: fluffy-web
    image: aceberg/fluffychat
    restart: unless-stopped
    ports:
      - "80:80"
    networks:
      - remna-network

networks:
  remna-network:
    external: true
EOF

cd /opt/fluffychat-web && docker compose up -d

echo "--- 5. Настройка Nginx Proxy ---"
cat <<EOF > /opt/remnanode/nginx/nginx.conf
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.key;

    location / {
        proxy_pass http://fluffy-web:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

cat <<EOF > /opt/remnanode/nginx/docker-compose.yml
services:
  nginx:
    image: nginx:latest
    container_name: remnawave-proxy
    restart: always
    ports:
      - "9443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/certs/privkey.key:ro
    networks:
      - remna-network

networks:
  remna-network:
    external: true
EOF

cd /opt/remnanode/nginx && docker compose up -d

echo "--- 6. Установка Remnanode ---"
cat <<EOF > /opt/remnanode/docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    volumes:
      - /opt/remnanode/nginx/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - /opt/remnanode/nginx/privkey.key:/etc/nginx/certs/privkey.key:ro
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$SECRET_KEY
EOF

cd /opt/remnanode && docker compose up -d

echo "--- 7. Настройка Firewall ---"
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2222/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 9443/tcp
sudo ufw --force enable

echo "--- 8. Установка WARP CLI  ---"
curl -L https://raw.githubusercontent.com/Skrepysh/tools/refs/heads/main/install-warp-cli.sh > install-warp-cli.sh
chmod +x install-warp-cli.sh

printf "\n40000\n" | ./install-warp-cli.sh

echo "--- 9. Проверка WARP ---"

curl -x socks5://127.0.0.1:40000 ifconfig.me || echo "WARP еще поднимается..."

echo "------------------------------------------------"
echo "ВСЕ ГОТОВО!"
echo "Домен: $DOMAIN"
echo "Порт Remnanode: 2222"
echo "Proxy порт: 9443"
echo "WARP SOCKS5: 127.0.0.1:40000"
echo "------------------------------------------------"