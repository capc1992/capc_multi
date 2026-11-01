#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly domain="${CAPC_DOMAIN:-api.capcmultiservicios.site}"
readonly expected_ip="${CAPC_EXPECTED_IP:-2.25.80.190}"
readonly certificate_email="${CAPC_CERT_EMAIL:-nicolasperdomoliz@gmail.com}"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_dir="$(cd -- "${script_dir}/../.." && pwd)"
readonly server_dir="${repository_dir}/server"
readonly environment_dir='/etc/capc-sync'
readonly environment_file="${environment_dir}/capc-sync.env"
readonly nginx_source="${repository_dir}/deploy/nginx/api.capcmultiservicios.site.conf"
readonly nginx_site='/etc/nginx/sites-available/api.capcmultiservicios.site.conf'

trap 'echo "ERROR: el despliegue se detuvo en la línea ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo 'Ejecuta este archivo como root.' >&2
  exit 1
fi

for required_file in "$server_dir/package-lock.json" "$nginx_source"; do
  if [[ ! -f "$required_file" ]]; then
    echo "No se encontró $required_file. Ejecuta el script dentro del repositorio CAPC." >&2
    exit 1
  fi
done

resolved_ips="$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u || true)"
if ! grep -Fxq "$expected_ip" <<<"$resolved_ips"; then
  echo "$domain todavía no resuelve hacia $expected_ip." >&2
  echo 'Crea el registro DNS tipo A, espera su propagación y vuelve a ejecutar el script.' >&2
  exit 1
fi

if ! command -v node >/dev/null || [[ "$(node --version | sed 's/^v//' | cut -d. -f1)" -lt 22 ]]; then
  echo 'Se requiere Node.js 22 o posterior.' >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx postgresql postgresql-contrib certbot python3-certbot-nginx openssl curl

if ! command -v pm2 >/dev/null; then
  npm install --global pm2@7
fi

systemctl enable --now postgresql nginx
install -d -m 0750 "$environment_dir"

if [[ ! -s "$environment_file" ]]; then
  database_password="$(openssl rand -hex 32)"
  token_pepper="$(openssl rand -hex 32)"

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='capc_sync'" | grep -qx 1; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c 'CREATE ROLE capc_sync LOGIN'
  fi
  printf "ALTER ROLE capc_sync WITH LOGIN PASSWORD '%s';\n" "$database_password" \
    | runuser -u postgres -- psql -v ON_ERROR_STOP=1

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='capc_sync'" | grep -qx 1; then
    runuser -u postgres -- createdb -O capc_sync capc_sync
  fi
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c 'ALTER DATABASE capc_sync OWNER TO capc_sync'

  temporary_environment="$(mktemp)"
  printf '%s\n' \
    'NODE_ENV=production' \
    'HOST=127.0.0.1' \
    'PORT=3100' \
    "DATABASE_URL=postgresql://capc_sync:${database_password}@127.0.0.1:5432/capc_sync" \
    "AUTH_TOKEN_PEPPER=${token_pepper}" \
    'ACCESS_TOKEN_TTL_MINUTES=15' \
    'REFRESH_TOKEN_TTL_DAYS=30' \
    'LOG_LEVEL=info' > "$temporary_environment"
  install -o root -g root -m 0600 "$temporary_environment" "$environment_file"
  rm -f "$temporary_environment"
  unset database_password token_pepper
else
  echo "Se conservará la configuración existente en $environment_file."
fi

set -a
# shellcheck disable=SC1090
source "$environment_file"
set +a

cd "$server_dir"
npm ci --include=dev
npm run build
npm run migrate
npm prune --omit=dev

pm2 startOrReload ecosystem.config.cjs --update-env
pm2 save
if [[ ! -f /etc/systemd/system/pm2-root.service ]]; then
  pm2 startup systemd -u root --hp /root
fi

for _ in {1..15}; do
  if curl --fail --silent --show-error http://127.0.0.1:3100/health >/dev/null; then
    break
  fi
  sleep 2
done
curl --fail --silent --show-error http://127.0.0.1:3100/health
echo

install -o root -g root -m 0644 "$nginx_source" "$nginx_site"
ln -sfn "$nginx_site" /etc/nginx/sites-enabled/api.capcmultiservicios.site.conf
nginx -t
systemctl reload nginx

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

certbot --nginx \
  --non-interactive \
  --agree-tos \
  --no-eff-email \
  --redirect \
  --email "$certificate_email" \
  --domains "$domain"

install -o root -g root -m 0750 "$script_dir/capc-sync-backup.sh" /usr/local/sbin/capc-sync-backup
printf '%s\n' '20 3 * * * root /usr/local/sbin/capc-sync-backup >> /var/log/capc-sync-backup.log 2>&1' \
  > /etc/cron.d/capc-sync-backup
chmod 0644 /etc/cron.d/capc-sync-backup
/usr/local/sbin/capc-sync-backup

curl --fail --silent --show-error "https://${domain}/health"
echo
curl --fail --silent --show-error "https://${domain}/privacidad" >/dev/null
curl --fail --silent --show-error "https://${domain}/eliminar-cuenta" >/dev/null

echo
echo 'CAPC quedó desplegado en producción.'
echo "API: https://${domain}"
echo "Privacidad: https://${domain}/privacidad"
echo "Eliminación: https://${domain}/eliminar-cuenta"
