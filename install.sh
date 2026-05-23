#!/bin/bash

# Exit on error
set -e

ENV_FILE=".env"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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
    "fluffy-web|aceberg/fluffychat|80"
)

# Load existing .env if it exists
if [ -f "$ENV_FILE" ]; then
    # Export variables but ignore comments
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

ask_variable() {
    local var_name=$1
    local prompt_text=$2
    local current_val=${!var_name}

    if [ ! -z "$current_val" ]; then
        read -p "$prompt_text (Current: $current_val). Use previous? [Y/n]: " use_old
        if [[ "$use_old" =~ ^[Nn]$ ]]; then
            read -p "Enter new $var_name: " new_val
            eval "$var_name=\"$new_val\""
        fi
    else
        read -p "Enter $prompt_text: " new_val
        eval "$var_name=\"$new_val\""
    fi
}

# --- DATA COLLECTION ---
echo "--- Configuration ---"
ask_variable "EMAIL" "Email (for SSL)"
ask_variable "DOMAIN" "Domain (e.g., node.example.com)"
ask_variable "SECRET_KEY" "SECRET_KEY (from panel)"

# --- SERVICE SELECTION ---
SELECTED_SERVICE=""

if [ ! -z "$SERVICE_NAME" ]; then
    read -p "Saved service is '$SERVICE_NAME'. Use previous? [Y/n]: " use_old_service
    if [[ "$use_old_service" =~ ^[Yy]$ || -z "$use_old_service" ]]; then
        # Ищем строку сервиса в массиве по имени
        for s in "${SERVICES[@]}"; do
            if [[ "$(echo "$s" | cut -d'|' -f1)" == "$SERVICE_NAME" ]]; then
                SELECTED_SERVICE="$s"
                break
            fi
        done
        if [ -z "$SELECTED_SERVICE" ]; then
            echo "Warning: Saved service '$SERVICE_NAME' not found in the available list. Forced re-selection."
        fi
    fi
fi

if [ -z "$SELECTED_SERVICE" ]; then
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
fi

SERVICE_IMAGE=$(echo "$SELECTED_SERVICE" | cut -d'|' -f2)
SERVICE_PORT=$(echo "$SELECTED_SERVICE" | cut -d'|' -f3)

cat <<EOF > "$ENV_FILE"
EMAIL=$EMAIL
DOMAIN=$DOMAIN
SECRET_KEY=$SECRET_KEY
SERVICE_NAME=$SERVICE_NAME
EOF

echo "--- Installing service: $SERVICE_NAME ---"
echo "------------------------------------------------"

echo "--- 1. Checking and Installing Dependencies ---"

if command -v docker &> /dev/null; then
    echo "Docker is already installed ($(docker --version | head -n1)). Skipping installation."
else
    echo "Docker not found. Installing..."
    sudo curl -fsSL https://get.docker.com | sh
fi

if docker compose version &> /dev/null; then
    echo "Docker Compose plugin is available. Skipping installation."
else
    echo "Docker Compose not found or outdated. Updating docker packages..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
fi

echo "Ensuring system utilities are installed..."
sudo apt-get update
sudo apt-get install -y cron socat curl ufw expect

echo "--- 2. Installing acme.sh ---"
curl https://get.acme.sh | sh -s email=$EMAIL
export LE_WORKING_DIR="${HOME}/.acme.sh"
alias acme.sh="${HOME}/.acme.sh/acme.sh"

echo "Select default Certificate Authority (CA):"
echo "1) Let's Encrypt"
echo "2) ZeroSSL"
read -p "Enter choice [1-2]: " CA_CHOICE

case $CA_CHOICE in
    1)
        echo "Setting default CA to Let's Encrypt..."
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ;;
    2)
        echo "Setting default CA to ZeroSSL..."
        ~/.acme.sh/acme.sh --set-default-ca --server zerossl
        ;;
    *)
        echo "Invalid choice. Defaulting to Let's Encrypt to be safe."
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ;;
esac

# Preparing directories
mkdir -p /opt/remnanode/nginx
mkdir -p "/opt/$SERVICE_NAME"

echo "--- 3. Issuing SSL Certificate ---"

CERT_KEY="/opt/remnanode/nginx/privkey.key"
CERT_PEM="/opt/remnanode/nginx/fullchain.pem"

PRE_HOOK="ufw allow 8443/tcp && ufw reload"
POST_HOOK="ufw delete allow 8443/tcp && ufw reload"

if [ -f "$CERT_PEM" ] && [ -f "$CERT_KEY" ]; then
    echo "SSL certificates already exist at $CERT_PEM. Skipping initial issuance."
else
    echo "No existing certificates found."

    ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" \
        --key-file "$CERT_KEY" \
        --fullchain-file "$CERT_PEM" \
        --alpn --tlsport 8443
    
fi

echo "--- 4. Setting up  $SERVICE_NAME ---"

cat <<EOF > "/opt/$SERVICE_NAME/docker-compose.yml"
services:
  $SERVICE_NAME:
    container_name: $SERVICE_NAME
    image: $SERVICE_IMAGE
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:$SERVICE_PORT"
EOF

docker compose -f "/opt/$SERVICE_NAME/docker-compose.yml" up -d

echo "--- 5. Configuring Nginx Proxy ---"

cat <<EOF > /opt/remnanode/nginx/nginx.conf
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://$host$request_uri;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    server_name $DOMAIN;
    http2 on;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
EOF

cat <<EOF > /opt/remnanode/nginx/docker-compose.yml
services:
  nginx:
    image: nginx:latest
    container_name: remnawave-proxy
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/certs/privkey.key:ro
      - /dev/shm:/dev/shm:rw
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
EOF

docker compose -f "/opt/remnanode/nginx/docker-compose.yml" up -d

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
      - /dev/shm:/dev/shm:rw
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="$SECRET_KEY"
EOF

docker compose -f "/opt/remnanode/docker-compose.yml" up -d

echo "--- 7. Configuring Firewall ---"

sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2222/tcp
sudo ufw --force enable

echo "Configuring automatic renewal via crontab..."

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file "$CERT_KEY" \
    --fullchain-file "$CERT_PEM" \
    --pre-hook "$PRE_HOOK" \
    --post-hook "$POST_HOOK" \
    --reloadcmd "docker compose -f /opt/remnanode/nginx/docker-compose.yml restart && docker compose -f /opt/remnanode/docker-compose.yml restart"

CRON_JOB="0 0 * * * \"${HOME}/.acme.sh\"/acme.sh --cron --home \"${HOME}/.acme.sh\" > /dev/null"
(crontab -l 2>/dev/null | grep -F "acme.sh --cron" || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -)

echo "Cron task successfully configured/verified."

echo "--- [8/8] Installing WARP CLI ---"
chmod +x warp.sh
"./warp.sh"

echo "------------------------------------------------"
echo "INSTALLATION COMPLETE!"
echo "Selected Service: $SERVICE_NAME"
echo "Domain: $DOMAIN"
echo "Remnanode Port: 2222"
echo "Checking WARP SOCKS5 proxy..."
curl -x socks5://127.0.0.1:40000 ifconfig.me
echo ""
echo "------------------------------------------------"
read -p "Do you want to generate a ready-to-use Xray-core server config (VLESS+REALITY)? [y/N]: " SHOW_CONFIG

if [[ "$SHOW_CONFIG" =~ ^[Yy]$ ]]; then
    echo "Generating REALITY keys and shortIds..."
    
    KEYS=$(docker exec remnanode xray x25519 2>/dev/null)
    
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
    
    SHORT_ID=$(openssl rand -hex 8)

    echo -e "\n=== GENERATED XRAY SERVER CONFIG ==="
    cat <<EOF
{
  "log": {
    "loglevel": "none"
  },
  "dns": {
    "tag": "dns_inbound",
    "servers": [
      "9.9.9.9",
      "149.112.112.112"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "TAG",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "xver": 1,
          "target": "/dev/shm/nginx.sock",
          "shortIds": [
            "$SHORT_ID"
          ],
          "privateKey": "$PRIVATE_KEY",
          "serverNames": [
            "$DOMAIN"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    },
    {
      "tag": "warp",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "port": 40000,
            "address": "127.0.0.1"
          }
        ]
      }
    }
  ],
  "routing": {
    "rules": [
    ]
  }
}
EOF
    echo -e "=====================================\n"
fi