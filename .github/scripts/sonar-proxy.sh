#!/usr/bin/env bash
# Proxy local qui ajoute les en-têtes Cloudflare Access à chaque requête du scanner
# Sonar (même principe que dans develop.yml). Le scanner parle à http://127.0.0.1:9000.
#
# Usage : sonar-proxy.sh start | stop
# Variables attendues pour start : SONAR_UPSTREAM, CF_ID, CF_SECRET
set -euo pipefail

case "${1:-}" in
  start)
    SONAR_UPSTREAM="${SONAR_UPSTREAM%/}"          # retire un éventuel / final
    SONAR_HOSTNAME="${SONAR_UPSTREAM#https://}"
    SONAR_HOSTNAME="${SONAR_HOSTNAME%%/*}"

    umask 077                                     # config lisible uniquement par le runner
    mkdir -p "$RUNNER_TEMP/cfproxy"
    cat > "$RUNNER_TEMP/cfproxy/nginx.conf" <<EOF
events {}
http {
  server {
    listen 127.0.0.1:9000;
    client_max_body_size 100m;
    location / {
      proxy_pass ${SONAR_UPSTREAM};
      proxy_ssl_server_name on;
      proxy_http_version 1.1;
      proxy_set_header Host ${SONAR_HOSTNAME};
      proxy_set_header CF-Access-Client-Id ${CF_ID};
      proxy_set_header CF-Access-Client-Secret ${CF_SECRET};
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    }
  }
}
EOF
    docker run -d --name cfproxy --network host \
      -v "$RUNNER_TEMP/cfproxy/nginx.conf:/etc/nginx/nginx.conf:ro" \
      nginx:1.30.6-alpine >/dev/null

    # Vérifie que Access laisse passer (sinon on récupère la page de login HTML)
    for i in $(seq 1 15); do
      if curl -sS http://127.0.0.1:9000/api/system/status | grep -q '"status":"UP"'; then
        echo "Sonar joignable via Cloudflare Access"
        exit 0
      fi
      sleep 2
    done
    echo "::error::Sonar injoignable via le proxy (token Access refusé ou Sonar down)"
    curl -sS -o /dev/null -w "Code HTTP reçu : %{http_code}\n" http://127.0.0.1:9000/api/system/status || true
    docker logs cfproxy || true
    exit 1
    ;;
  stop)
    docker rm -f cfproxy >/dev/null 2>&1 || true
    rm -rf "$RUNNER_TEMP/cfproxy"
    ;;
  *)
    echo "Usage : $0 start | stop"; exit 2 ;;
esac
