#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly domain="${CAPC_PILOT_DOMAIN:-api-test.capcmultiservicios.site}"
readonly expected_ip="${CAPC_EXPECTED_IP:-2.25.80.190}"
readonly certificate_email="${CAPC_CERT_EMAIL:-nicolasperdomoliz@gmail.com}"
readonly publish_public="${CAPC_PILOT_PUBLISH_PUBLIC:-true}"
readonly canonical_repository="${CAPC_PILOT_REPOSITORY_DIR:-/opt/capc-sync-pilot/repository}"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_dir="$(cd -- "${script_dir}/../.." && pwd)"
readonly server_dir="${repository_dir}/server"
readonly environment_dir='/etc/capc-sync-pilot'
readonly environment_file="${environment_dir}/capc-sync.env"
readonly nginx_source="${repository_dir}/deploy/nginx/api-test.capcmultiservicios.site.conf"
readonly nginx_site='/etc/nginx/sites-available/api-test.capcmultiservicios.site.conf'
readonly backup_script_source="${script_dir}/capc-sync-pilot-backup.sh"
readonly backup_script_target='/usr/local/sbin/capc-sync-pilot-backup'

restore_database=''
cleanup() {
  if [[ -n "$restore_database" ]]; then
    runuser -u postgres -- dropdb --if-exists "$restore_database" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'echo "ERROR: el despliegue piloto se detuvo en la linea ${LINENO}." >&2' ERR

if [[ "${EUID}" -ne 0 ]]; then
  echo 'Ejecuta este archivo como root.' >&2
  exit 1
fi

if [[ "$publish_public" != 'true' && "$publish_public" != 'false' ]]; then
  echo 'CAPC_PILOT_PUBLISH_PUBLIC debe ser true o false.' >&2
  exit 1
fi

if [[ "$repository_dir" != "$canonical_repository" ]]; then
  echo 'El piloto debe ejecutarse desde un clon separado para no alterar los archivos de produccion.' >&2
  echo "Ruta esperada: $canonical_repository" >&2
  echo "Ruta recibida: $repository_dir" >&2
  exit 1
fi

for required_file in \
  "$server_dir/package-lock.json" \
  "$server_dir/ecosystem.pilot.config.cjs" \
  "$nginx_source" \
  "$backup_script_source"; do
  if [[ ! -f "$required_file" ]]; then
    echo "No se encontro $required_file." >&2
    exit 1
  fi
done

for command_name in node npm pm2 nginx certbot curl openssl psql pg_dump pg_restore; do
  if ! command -v "$command_name" >/dev/null; then
    echo "Falta el comando requerido: $command_name" >&2
    exit 1
  fi
done

if [[ "$(node --version | sed 's/^v//' | cut -d. -f1)" -lt 22 ]]; then
  echo 'Se requiere Node.js 22 o posterior.' >&2
  exit 1
fi

if [[ "$publish_public" == 'true' ]]; then
  resolved_ips="$({
    getent ahostsv4 "$domain" || true
    if command -v dig >/dev/null; then
      dig +short @1.1.1.1 "$domain" A || true
    fi
  } | awk '{print $1}' | sort -u)"
  if ! grep -Fxq "$expected_ip" <<<"$resolved_ips"; then
    echo "$domain todavia no resuelve hacia $expected_ip." >&2
    echo 'Configura primero el registro DNS tipo A y espera su propagacion.' >&2
    exit 1
  fi
fi

if ! systemctl is-active --quiet postgresql || ! systemctl is-active --quiet nginx; then
  echo 'PostgreSQL y Nginx deben estar activos antes de instalar el piloto.' >&2
  exit 1
fi

install -d -m 0750 "$environment_dir"
if [[ ! -s "$environment_file" ]]; then
  database_password="$(openssl rand -hex 32)"
  token_pepper="$(openssl rand -hex 32)"

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='capc_sync_pilot'" | grep -qx 1; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c 'CREATE ROLE capc_sync_pilot LOGIN'
  fi
  printf "ALTER ROLE capc_sync_pilot WITH LOGIN PASSWORD '%s';\n" "$database_password" \
    | runuser -u postgres -- psql -v ON_ERROR_STOP=1

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='capc_sync_pilot'" | grep -qx 1; then
    runuser -u postgres -- createdb -O capc_sync_pilot capc_sync_pilot
  fi
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
    -c 'ALTER DATABASE capc_sync_pilot OWNER TO capc_sync_pilot'

  temporary_environment="$(mktemp)"
  printf '%s\n' \
    'NODE_ENV=production' \
    'HOST=127.0.0.1' \
    'PORT=3101' \
    "DATABASE_URL=postgresql://capc_sync_pilot:${database_password}@127.0.0.1:5432/capc_sync_pilot" \
    "AUTH_TOKEN_PEPPER=${token_pepper}" \
    'ACCESS_TOKEN_TTL_MINUTES=15' \
    'REFRESH_TOKEN_TTL_DAYS=30' \
    'LOG_LEVEL=info' > "$temporary_environment"
  install -o root -g root -m 0600 "$temporary_environment" "$environment_file"
  rm -f "$temporary_environment"
  unset database_password token_pepper
else
  echo "Se conservara la configuracion existente en $environment_file."
fi

set -a
# shellcheck disable=SC1090
source "$environment_file"
set +a

if [[ "${HOST:-}" != '127.0.0.1' || "${PORT:-}" != '3101' ]]; then
  echo 'El piloto debe escuchar exclusivamente en 127.0.0.1:3101.' >&2
  exit 1
fi
if [[ "${DATABASE_URL:-}" != *'/capc_sync_pilot' ]]; then
  echo 'DATABASE_URL no apunta a la base exclusiva capc_sync_pilot.' >&2
  exit 1
fi

cd "$server_dir"
npm ci --include=dev
npm audit --omit=dev --audit-level=high
npm run check
# Sin DATABASE_URL, Vitest omite la suite PostgreSQL que limpia tablas.
env -u DATABASE_URL npm test
npm run build
npm run migrate
npm run migrate

migration_versions="$(runuser -u postgres -- psql -d capc_sync_pilot -Atc \
  "SELECT string_agg(version::text, ',' ORDER BY version) FROM schema_migrations")"
if [[ "$migration_versions" != '1,2,3,4,5' ]]; then
  echo "Migraciones inesperadas en el piloto: $migration_versions" >&2
  exit 1
fi

npm prune --omit=dev --package-lock=false
pm2 startOrReload ecosystem.pilot.config.cjs --only capc-sync-pilot --update-env
pm2 save

for _ in {1..15}; do
  if curl --fail --silent --show-error http://127.0.0.1:3101/health >/dev/null; then
    break
  fi
  sleep 2
done
curl --fail --silent --show-error http://127.0.0.1:3101/health
echo

if [[ "$publish_public" == 'true' ]]; then
  install -o root -g root -m 0644 "$nginx_source" "$nginx_site"
  ln -sfn "$nginx_site" /etc/nginx/sites-enabled/api-test.capcmultiservicios.site.conf
  nginx -t
  systemctl reload nginx

  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --no-eff-email \
    --redirect \
    --email "$certificate_email" \
    --domains "$domain"
fi

install -o root -g root -m 0750 "$backup_script_source" "$backup_script_target"
printf '%s\n' '40 3 * * * root /usr/local/sbin/capc-sync-pilot-backup >> /var/log/capc-sync-pilot-backup.log 2>&1' \
  > /etc/cron.d/capc-sync-pilot-backup
chmod 0644 /etc/cron.d/capc-sync-pilot-backup
"$backup_script_target"

backup_file="$(find /var/backups/capc-sync-pilot -maxdepth 1 -type f \
  -name 'capc-sync-pilot-*.dump' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
if [[ -z "$backup_file" || ! -s "$backup_file" ]]; then
  echo 'No se encontro el respaldo del piloto.' >&2
  exit 1
fi

restore_database="capc_sync_pilot_restore_$(date -u +%Y%m%d%H%M%S)"
runuser -u postgres -- createdb -O capc_sync_pilot "$restore_database"
runuser -u postgres -- pg_restore --exit-on-error --no-owner \
  --role=capc_sync_pilot --dbname="$restore_database" "$backup_file"
restored_versions="$(runuser -u postgres -- psql -d "$restore_database" -Atc \
  "SELECT string_agg(version::text, ',' ORDER BY version) FROM schema_migrations")"
if [[ "$restored_versions" != '1,2,3,4,5' ]]; then
  echo "La restauracion de ensayo tiene migraciones inesperadas: $restored_versions" >&2
  exit 1
fi
runuser -u postgres -- dropdb "$restore_database"
restore_database=''

if [[ "$publish_public" == 'true' ]]; then
  curl --fail --silent --show-error \
    --resolve "${domain}:443:${expected_ip}" \
    "https://${domain}/health"
  echo
fi

echo 'Piloto CAPC desplegado y restauracion de respaldo verificada.'
if [[ "$publish_public" == 'true' ]]; then
  echo "API piloto: https://${domain}"
else
  echo 'API piloto disponible solo en http://127.0.0.1:3101 hasta configurar DNS y TLS.'
fi
echo 'Produccion no fue modificada.'
