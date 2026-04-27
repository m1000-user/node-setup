#!/bin/bash

# Exit on error
set -e

# --- SERVICES LIST ---
# Format: "Name|Image|Internal_Port"
SERVICES=(
    "filebrowser|filebrowser/filebrowser|80"
    "memos|neosmemo/memos:stable|5230"
    "pingvin-share|stonith404/pingvin-share|3000"
    "excalidraw|excalidraw/excalidraw|80"
    "searxng|searxng/searxng|8080"
    "sharry|jlesage/sharry|9090"
    "audiobookshelf|advplyr/audiobookshelf|80"
    "kavita|jvmilazz0/kavita|5000"
    "kodbox|kodcloud/kodbox|80"
    "navidrome|deluan/navidrome|4533"
    "gitea|gitea/gitea|3000"
)

# --- DATA COLLECTION ---
read -p "Enter your Email (for SSL): " EMAIL
read -p "Enter your Domain (e.g., node.example.com): " DOMAIN
read -p "Enter SECRET_KEY (from panel): " SECRET_KEY

echo "------------------------------------------------"
echo "Select the service you want to install:"
for i in "${!SERVICES[@]}"; do
    NAME=$(echo "${SERVICES[$i]}" | cut -d'|' -f1)
    echo "[$((i+1))] $NAME"
done

read -p "Service number (Press Enter for a random one): " CHOICE

if [ -z "$CHOICE" ]; then
    RAND_IDX=$(( RANDOM % ${#SERVICES[@]} ))
    SELECTED_SERVICE="${SERVICES[$RAND_IDX]}"
else
    SELECTED_SERVICE="${SERVICES[$((CHOICE-1))]}"
fi

SERVICE_NAME=$(echo "$SELECTED_SERVICE" | cut -d'|' -f1)
SERVICE_IMAGE=$(echo "$SELECTED_SERVICE" | cut -d'|' -f2)
SERVICE_PORT=$(echo "$SELECTED_SERVICE" | cut -d'|' -f3)

echo "--- Installing service: $SERVICE_NAME ---"
echo "------------------------------------------------"

echo "--- 1. Installing Docker and Dependencies ---"
sudo curl -fsSL https://get.docker.com | sh
sudo apt-get update
sudo apt-get install -y cron socat curl ufw expect

echo "--- 2. Installing acme.sh ---"
curl https://get.acme.sh | sh -s email=$EMAIL
export LE_WORKING_DIR="${HOME}/.acme.sh"
alias acme.sh="${HOME}/.acme.sh/acme.sh"
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# Preparing directories
mkdir -p /opt/remnanode/nginx
mkdir -p "/opt/$SERVICE_NAME"

echo "--- 3. Issuing SSL Certificate ---"
~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN \
    --key-file /opt/remnanode/nginx/privkey.key \
    --fullchain-file /opt/remnanode/nginx/fullchain.pem \
    --alpn --tlsport 8443

echo "--- 4. Setting up Network and $SERVICE_NAME ---"
docker network create remna-network || true

cat <<EOF > "/opt/$SERVICE_NAME/docker-compose.yml"
services:
  $SERVICE_NAME:
    container_name: $SERVICE_NAME
    image: $SERVICE_IMAGE
    restart: unless-stopped
    ports:
      - "80:$SERVICE_PORT"
    networks:
      - remna-network

networks:
  remna-network:
    external: true
EOF

cd "/opt/$SERVICE_NAME" && docker compose up -d

echo "--- 5. Configuring Nginx Proxy ---"

cat <<EOF > /opt/remnanode/nginx/nginx.conf
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.key;

    location / {
        proxy_pass http://$SERVICE_NAME:$SERVICE_PORT;
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

echo "--- 6. Installing Remnanode ---"

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
      - SECRET_KEY="$SECRET_KEY"
EOF

cd /opt/remnanode && docker compose up -d

echo "--- 7. Configuring Firewall ---"

sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2222/tcp
sudo ufw --force enable

echo "--- [8/8] Installing WARP CLI ---"
curl -L https://raw.githubusercontent.com/Skrepysh/tools/refs/heads/main/install-warp-cli.sh > warp.sh
chmod +x warp.sh
echo "To install WARP, run: ./warp.sh"

echo "------------------------------------------------"
echo "INSTALLATION COMPLETE!"
echo "Selected Service: $SERVICE_NAME"
echo "Domain: $DOMAIN"
echo "Remnanode Port: 2222"
echo "------------------------------------------------"