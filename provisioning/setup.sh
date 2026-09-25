#!/usr/bin/env bash
# Universal server setup for VolleySpike staging/production
# Usage: Run ON the server at /opt/volleyspike/setup.sh
set -euo pipefail

DEPLOY_PATH="/opt/volleyspike"

# --- Idempotency guard ---
if [ -f "$DEPLOY_PATH/.env" ]; then
  if [ "${1:-}" != "--force" ]; then
    echo "ERROR: $DEPLOY_PATH/.env already exists."
    echo "  Fresh re-provisioning: re-run with --force (regenerates all secrets)."
    echo "  Migrating an existing environment: copy the old .env* files into $DEPLOY_PATH,"
    echo "  then re-run with SKIP_SECRET_GENERATION=1 ./setup.sh --force (--force alone"
    echo "  still regenerates secrets and desyncs a restored environment)."
    exit 1
  fi
  if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
    echo "WARNING: --force passed with SKIP_SECRET_GENERATION=1 — reusing existing secrets, guard bypassed only."
  else
    echo "WARNING: --force passed, overwriting existing environment files and regenerating secrets."
  fi
fi

echo "=== VolleySpike Server Setup ==="
echo ""

# 1. Verify docker access
if ! docker ps > /dev/null 2>&1; then
  echo "ERROR: Cannot access Docker. Ensure user is in docker group."
  exit 1
fi

# 2. Install QEMU binfmt support for cross-platform migration bundles (arm64 hosts only)
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  echo "Setting up QEMU binfmt for amd64 emulation..."
  docker run --privileged --rm tonistiigi/binfmt --install amd64
  echo "  binfmt registered."
fi

# 3. Prompt for environment
read -rp "Environment [staging/production]: " ENVIRONMENT
if [ "$ENVIRONMENT" != "staging" ] && [ "$ENVIRONMENT" != "production" ]; then
  echo "ERROR: Must be 'staging' or 'production'"
  exit 1
fi

# 4. Prompt for frontend URL
# The former "API Domain" prompt was removed: the DOMAIN it set was never consumed
# anywhere in this script, and its staging default was wrong besides
# ("staging.api.volleyspike.app" — the staging host actually serves
# "staging-api.volleyspike.app"). A prompt that configures nothing but looks like
# it does is worse than no prompt. See SPI-5711.
if [ "$ENVIRONMENT" = "staging" ]; then
  DEFAULT_FRONTEND="https://staging.volleyspike.app"
else
  DEFAULT_FRONTEND="https://www.volleyspike.app"
fi

read -rp "Frontend URL [$DEFAULT_FRONTEND]: " FRONTEND_URL
FRONTEND_URL="${FRONTEND_URL:-$DEFAULT_FRONTEND}"

# Derive ASPNETCORE_ENVIRONMENT
if [ "$ENVIRONMENT" = "staging" ]; then
  ASPNET_ENV="Staging"
else
  ASPNET_ENV="Production"
fi

# Derive log level from environment
if [ "$ENVIRONMENT" = "staging" ]; then
  LOG_LEVEL="Information"
else
  LOG_LEVEL="Warning"
fi

echo ""

# 5. Create directory structure
mkdir -p "$DEPLOY_PATH"/{caddy,init,migrations,backups}

# 6. Generate secure passwords
if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
  echo "SKIP_SECRET_GENERATION=1 — reusing existing env files, not generating secrets."
else
  echo "Generating secure passwords..."
  POSTGRES_PASSWORD=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
  REDIS_PASSWORD=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
  RABBITMQ_PASSWORD=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)
  JWT_SECRET=$(openssl rand -base64 96 | tr -d '/+=' | head -c 64)

  # Verify password lengths (48 bytes base64 = ~64 chars, minus ~25% special = ~48 chars, truncate to 32 is safe)
  if [ ${#POSTGRES_PASSWORD} -lt 32 ] || [ ${#REDIS_PASSWORD} -lt 32 ] || [ ${#RABBITMQ_PASSWORD} -lt 32 ]; then
    echo "ERROR: Password generation produced unexpectedly short output. Re-run setup."
    exit 1
  fi
  if [ ${#JWT_SECRET} -lt 64 ]; then
    echo "ERROR: JWT secret generation produced unexpectedly short output. Re-run setup."
    exit 1
  fi

  echo "  Passwords generated."
fi

# 7. Prompt for AWS credentials
echo ""
echo "--- AWS Credentials (S3 + SES, used by all services) ---"
read -rp "AWS Access Key ID: " AWS_ACCESS_KEY_ID
read -rsp "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
echo ""
read -rp "AWS Region [eu-west-2]: " AWS_REGION
AWS_REGION="${AWS_REGION:-eu-west-2}"
read -rp "S3 Bucket Name: " S3_BUCKET_NAME

# 8. Prompt for Stripe credentials (optional)
echo ""
echo "--- Stripe Credentials (press Enter to skip) ---"
read -rsp "Stripe API Key: " STRIPE_API_KEY
echo ""
read -rsp "Stripe Webhook Secret: " STRIPE_WEBHOOK_SECRET
echo ""

# 8b. Frontend server-side secrets (optional)
echo ""
echo "--- Frontend Server-Side Secrets (press Enter to skip) ---"
read -rp "Google OAuth Client ID (for frontend, or press Enter to skip): " AUTH_GOOGLE_ID
read -rp "Google OAuth Client Secret (or press Enter to skip): " AUTH_GOOGLE_SECRET
EXISTING_AUTH_SECRET=""
if [ -f "$DEPLOY_PATH/.env.frontend" ]; then
  EXISTING_AUTH_SECRET=$(grep -oP '(?<=^AUTH_SECRET=).*' "$DEPLOY_PATH/.env.frontend" || true)
fi
if [ -n "$EXISTING_AUTH_SECRET" ]; then
  AUTH_SECRET="$EXISTING_AUTH_SECRET"
  echo "Preserving existing AUTH_SECRET (regenerating would invalidate all sessions)"
else
  AUTH_SECRET=$(openssl rand -base64 32)
  echo "Generated new AUTH_SECRET"
fi
read -rp "Linear API Key (for beta feedback, or press Enter to skip): " LINEAR_API_KEY

# 8c. Telegram credentials for monitoring
echo ""
echo "--- Telegram Monitoring (reuse CI/CD bot, or press Enter to skip) ---"
read -rp "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -rp "Telegram Chat ID: " TELEGRAM_CHAT_ID

# 9. Prompt for GHCR login
echo ""
echo "--- GitHub Container Registry ---"
read -rp "GitHub username: " GITHUB_USERNAME
read -rsp "GitHub PAT (read:packages scope): " GITHUB_PAT
echo ""

echo "Logging into ghcr.io..."
echo "$GITHUB_PAT" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
chmod 600 "$HOME/.docker/config.json" 2>/dev/null || true
# Note: GHCR credentials are stored in ~/.docker/config.json in plaintext.
# Consider using docker-credential-helpers for encrypted storage in hardened environments.
echo "  GHCR login successful."

# 10. Write .env (Docker Compose interpolation)
if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
  echo "SKIP_SECRET_GENERATION=1 — leaving existing $DEPLOY_PATH/.env in place."
else
  # Note: GITHUB_REPOSITORY_OWNER must be lowercase for GHCR image paths.
  # docker-compose.yml uses ${GITHUB_REPOSITORY_OWNER:-bielov-team-track} with a lowercase default.
  # This .env value takes precedence over any workflow-injected variable for compose operations.
  cat > "$DEPLOY_PATH/.env" << EOF
# Docker Compose interpolation variables (auto-generated $(date +%Y-%m-%d))
POSTGRES_USER=volleyer_user
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
RABBITMQ_DEFAULT_USER=volleyer
RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASSWORD}
GITHUB_REPOSITORY_OWNER=bielov-team-track
EOF
fi

# 11. Write .env.common (shared container env vars)
if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
  echo "SKIP_SECRET_GENERATION=1 — leaving existing $DEPLOY_PATH/.env.common in place."
else
  cat > "$DEPLOY_PATH/.env.common" << EOF
# Shared container environment (auto-generated $(date +%Y-%m-%d))
POSTGRES_USER=volleyer_user
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
RABBITMQ_DEFAULT_USER=volleyer
RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASSWORD}
GITHUB_REPOSITORY_OWNER=bielov-team-track

# AWS credentials
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_REGION=${AWS_REGION}
AWS_DEFAULT_REGION=${AWS_REGION}
S3__Bucket=${S3_BUCKET_NAME}
S3__PublicBaseUrl=https://${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com
S3__PresignedUrlExpiryMinutes=15
EOF
fi

# 12. Write per-service env files
if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
  echo "SKIP_SECRET_GENERATION=1 — leaving existing $DEPLOY_PATH/.env.<service> files in place."
else
  SERVICES=(auth events clubs profiles messages notifications social coaching payments rewards)
  PORTS=(5005 5010 5020 5170 5180 5030 5040 5060 5050 5070)
  DB_NAMES=(auth events clubs profiles messages notifications social coaching payments rewards)
  # Services with dual Kestrel endpoints (HTTP + gRPC) — do NOT set ASPNETCORE_URLS
  GRPC_SERVICES="events clubs coaching payments"

  for i in "${!SERVICES[@]}"; do
    SVC="${SERVICES[$i]}"
    DB="${DB_NAMES[$i]}"
    PORT="${PORTS[$i]}"

    cat > "$DEPLOY_PATH/.env.${SVC}" << EOF
# ${SVC}-service environment (${ENVIRONMENT})
ConnectionStrings__DefaultConnection=Host=postgres;Database=${DB};Username=volleyer_user;Password='${POSTGRES_PASSWORD}'
$(echo "${SVC}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_DB_CONNECTION=Host=localhost;Port=5432;Database=${DB};Username=volleyer_user;Password='${POSTGRES_PASSWORD}'
Redis__ConnectionString=redis:6379,password=${REDIS_PASSWORD}
RabbitMQ__Host=rabbitmq
RabbitMQ__Username=volleyer
RabbitMQ__Password=${RABBITMQ_PASSWORD}
Jwt__Secret=${JWT_SECRET}
Jwt__Issuer=volleyspike
Jwt__Audience=volleyspike
Cors__AllowedOrigins__0=${FRONTEND_URL}
$(if [[ "$FRONTEND_URL" == *"www."* ]]; then echo "Cors__AllowedOrigins__1=${FRONTEND_URL/www./}"; elif [[ "$FRONTEND_URL" == https://* ]]; then echo "Cors__AllowedOrigins__1=${FRONTEND_URL/https:\/\//https:\/\/www.}"; fi)
ASPNETCORE_ENVIRONMENT=${ASPNET_ENV}
Logging__LogLevel__Default=${LOG_LEVEL}
Logging__LogLevel__Microsoft.AspNetCore=Warning
Logging__LogLevel__Microsoft.EntityFrameworkCore.Database.Command=Warning
EOF

    # Only set ASPNETCORE_URLS for services without gRPC endpoints
    if ! echo "$GRPC_SERVICES" | grep -qw "$SVC"; then
      echo "ASPNETCORE_URLS=http://+:${PORT}" >> "$DEPLOY_PATH/.env.${SVC}"
    fi
  done

  # Social-service Redis connection string override
  cat >> "$DEPLOY_PATH/.env.social" << EOF
ConnectionStrings__Redis=redis:6379,password=${REDIS_PASSWORD}
EOF

  # Inter-service gRPC URLs
  cat >> "$DEPLOY_PATH/.env.events" << 'EOF'
Services__ClubsService__Url=http://clubs-service:5021
Services__CoachingService__Url=http://coaching-service:5061
Services__PaymentsService__Url=http://payments-service:5051
Services__ProfilesService__Url=http://profiles-service:5171
EOF

  cat >> "$DEPLOY_PATH/.env.social" << 'EOF'
Services__ClubsService__GrpcUrl=http://clubs-service:5021
EOF

  cat >> "$DEPLOY_PATH/.env.payments" << 'EOF'
GrpcClients__ClubsService=http://clubs-service:5021
GrpcClients__ProfilesService=http://profiles-service:5171
EOF

  cat >> "$DEPLOY_PATH/.env.rewards" << 'EOF'
Services__ProfilesService__GrpcUrl=http://profiles-service:5171
EOF

  cat >> "$DEPLOY_PATH/.env.rewards" << EOF
Rewards__ThumbBaseUrl=${FRONTEND_URL}/rewards/thumbs
EOF

  # Service-specific URLs
  cat >> "$DEPLOY_PATH/.env.auth" << EOF

Urls__Web=${FRONTEND_URL}
EOF

  cat >> "$DEPLOY_PATH/.env.events" << EOF

Urls__Web=${FRONTEND_URL}
Urls__UserProfilesUrl=${FRONTEND_URL}/profiles/

Stripe__RefreshUrl=${FRONTEND_URL}/stripe/refresh
Stripe__ReturnUrl=${FRONTEND_URL}/hub/settings/payments
Stripe__CheckoutSuccessUrl=${FRONTEND_URL}/payments/success
Stripe__CheckoutCancelUrl=${FRONTEND_URL}/payments/cancel
EOF

  cat >> "$DEPLOY_PATH/.env.payments" << EOF

Urls__Web=${FRONTEND_URL}
Stripe__CheckoutSuccessUrl=${FRONTEND_URL}/payments/success
Stripe__CheckoutCancelUrl=${FRONTEND_URL}/payments/cancel
EOF

  # Add Stripe keys if provided
  if [ -n "$STRIPE_API_KEY" ]; then
    echo "Stripe__ApiKey=${STRIPE_API_KEY}" >> "$DEPLOY_PATH/.env.events"
    echo "Stripe__ApiKey=${STRIPE_API_KEY}" >> "$DEPLOY_PATH/.env.payments"
  fi
  if [ -n "$STRIPE_WEBHOOK_SECRET" ]; then
    echo "Stripe__WebhookSecret=${STRIPE_WEBHOOK_SECRET}" >> "$DEPLOY_PATH/.env.events"
    echo "Stripe__WebhookSecret=${STRIPE_WEBHOOK_SECRET}" >> "$DEPLOY_PATH/.env.payments"
  fi
fi

# 12b. Write frontend env file
if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
  echo "SKIP_SECRET_GENERATION=1 — leaving existing $DEPLOY_PATH/.env.frontend in place."
else
  cat > "$DEPLOY_PATH/.env.frontend" << EOF
# frontend environment (${ENVIRONMENT})
# NOTE: NEXT_PUBLIC_* vars are baked at build time via Docker build-args in CI.
# They are NOT set here — env_file injection has no effect on client-side code.
# Only server-side runtime vars belong in this file.
HOSTNAME=0.0.0.0
PORT=3000
EOF

  # Append server-side secrets if provided
  {
    [ -n "$AUTH_GOOGLE_ID" ] && echo "AUTH_GOOGLE_ID=${AUTH_GOOGLE_ID}"
    [ -n "$AUTH_GOOGLE_SECRET" ] && echo "AUTH_GOOGLE_SECRET=${AUTH_GOOGLE_SECRET}"
    echo "AUTH_SECRET=${AUTH_SECRET}"
    [ -n "$LINEAR_API_KEY" ] && echo "LINEAR_API_KEY=${LINEAR_API_KEY}"
  } >> "$DEPLOY_PATH/.env.frontend"
fi

# 13. Create empty .env.tags
if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
  echo "SKIP_SECRET_GENERATION=1 — leaving existing $DEPLOY_PATH/.env.tags in place."
else
  touch "$DEPLOY_PATH/.env.tags"
fi

# 13b. Write monitor env file and install systemd service
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  if [ "${SKIP_SECRET_GENERATION:-0}" = "1" ]; then
    echo "SKIP_SECRET_GENERATION=1 — leaving existing $DEPLOY_PATH/.env.monitor in place."
  else
    cat > "$DEPLOY_PATH/.env.monitor" << EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
MONITOR_COMPOSE_PROJECT=volleyspike
MONITOR_COOLDOWN=300
ENVIRONMENT=${ENVIRONMENT}
EOF
  fi

  # Install monitor script and systemd service. Both must already be staged at
  # $DEPLOY_PATH (see README "Before running setup.sh") — skip with a warning
  # instead of aborting the whole script if the operator hasn't placed them yet.
  if [ -f "$DEPLOY_PATH/docker-monitor.sh" ] && [ -f "$DEPLOY_PATH/docker-monitor.service" ]; then
    sudo chmod +x "$DEPLOY_PATH/docker-monitor.sh"
    sudo cp "$DEPLOY_PATH/docker-monitor.service" /etc/systemd/system/docker-monitor.service
    sudo systemctl daemon-reload
    sudo systemctl enable docker-monitor.service
    sudo systemctl start docker-monitor.service
    echo "  Docker monitor service installed and started."
  else
    echo "  Skipping Docker monitor install: docker-monitor.sh/.service not found in $DEPLOY_PATH."
  fi
else
  echo "  Skipping Docker monitor setup (no Telegram credentials)."
fi

# 14. Secure permissions. Some .env.* files (e.g. .env.monitoring, used by
# docker-compose.exporters.yml) are root-owned on real servers; chmod on a
# file this user doesn't own returns EPERM and would abort the whole script.
for f in "$DEPLOY_PATH"/.env "$DEPLOY_PATH"/.env.*; do
  [ -e "$f" ] || continue
  [ -O "$f" ] || { echo "  skipping $f (not owned by $(whoami))"; continue; }
  chmod 600 "$f"
done

echo ""
echo "  Environment files written."

# 15. Unset sensitive variables from shell memory
unset POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD JWT_SECRET
unset AWS_SECRET_ACCESS_KEY STRIPE_API_KEY STRIPE_WEBHOOK_SECRET GITHUB_PAT AUTH_SECRET AUTH_GOOGLE_SECRET LINEAR_API_KEY TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

# 16. Install postgresql-client
if ! command -v pg_dump &> /dev/null; then
  echo "Installing postgresql-client for backup support..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq postgresql-client
fi

# 17. Create .pgpass (read password back from generated env file)
PGPASS_FILE="$HOME/.pgpass"
if [ ! -f "$PGPASS_FILE" ] || [ "${1:-}" = "--force" ]; then
  PG_PASS_VALUE=$(grep '^POSTGRES_PASSWORD=' "$DEPLOY_PATH/.env" | cut -d= -f2)
  echo "localhost:5432:*:volleyer_user:${PG_PASS_VALUE}" > "$PGPASS_FILE"
  chmod 600 "$PGPASS_FILE"
  unset PG_PASS_VALUE
  echo "  Created $PGPASS_FILE"
fi

# 18. Firewall — see provisioning/nftables.conf, applied by bootstrap.sh.
# Deliberately NOT handled here. The previous iptables/DOCKER-USER implementation
# left an orphaned `ip filter FORWARD` policy-drop chain that silently blackholed
# all Prometheus scrapes for 17 days once Docker moved to the nftables backend.
# ufw must stay purged: on Ubuntu the old branch would enable `default deny
# incoming` and sever 80/443/51820.

# 19. Optional swap setup
echo ""
if [ ! -f /swapfile ]; then
  read -rp "Create 2GB swap file? (recommended for production) [y/N]: " CREATE_SWAP
  if [ "${CREATE_SWAP,,}" = "y" ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
    echo "  2GB swap file created."
  fi
else
  echo "Swap file already exists, skipping."
fi

# 20. Start infrastructure
echo ""
echo "--- Starting Infrastructure ---"
cd "$DEPLOY_PATH"
docker compose -f docker-compose.yml -f "docker-compose.${ENVIRONMENT}.yml" up -d postgres redis rabbitmq caddy

echo ""
echo "Waiting for postgres to be healthy..."
for i in $(seq 1 30); do
  if docker compose -f docker-compose.yml -f "docker-compose.${ENVIRONMENT}.yml" ps postgres | grep -q "healthy"; then
    echo "  Postgres is healthy."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "WARNING: Postgres health check timed out. Check logs."
  fi
  sleep 2
done

# 21. Get SSH fingerprint for GitHub secrets
# Must be the ECDSA host key, NOT ed25519. The deploy workflows use appleboy/scp-action
# and ssh-action, whose Go x/crypto/ssh client negotiates ecdsa-sha2-nistp256, while
# OpenSSH negotiates ed25519 against the same host. Pinning the ed25519 fingerprint makes
# every deploy fail with "ssh: handshake failed: ssh: host key fingerprint mismatch" —
# which reads as an auth problem but is purely a wrong pin. Keep the SHA256: prefix.
# Verified by running the real appleboy/drone-scp image against a host with each candidate:
# ed25519 (with and without prefix) and rsa all MISMATCH; ecdsa ACCEPTED. See SPI-5745.
SSH_FINGERPRINT=$(ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null | awk '{print $2}') || SSH_FINGERPRINT="(could not read - run: ssh-keyscan -t ecdsa <this-ip> | ssh-keygen -lf -)"

# 22. Print summary
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================"
echo "  Setup Complete ($ENVIRONMENT)"
echo "============================================"
echo ""
echo "Environment files: $DEPLOY_PATH/.env.*"
echo "Compose command:   docker compose -f docker-compose.yml -f docker-compose.${ENVIRONMENT}.yml"
echo ""
echo "Configure these GitHub secrets in the '${ENVIRONMENT}' environment"
echo "for each service repo (Settings → Environments → ${ENVIRONMENT}):"
echo ""
echo "  SSH_HOST:        $SERVER_IP"
echo "  SSH_USER:        $(whoami)"
echo "  SSH_KEY:         <paste your SSH private key>"
echo "  SSH_FINGERPRINT: $SSH_FINGERPRINT"
echo "  TELEGRAM_BOT_TOKEN: <your bot token>"
echo "  TELEGRAM_CHAT_ID:   <your chat ID>"
echo ""
echo "After configuring secrets, push to '$([ "$ENVIRONMENT" = "staging" ] && echo "development" || echo "main")' branch to trigger deploy."
