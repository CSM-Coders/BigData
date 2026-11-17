#!/bin/bash
# corre en la ec2 con sudo: instala la app de streamlit como servicio de systemd
# uso: sudo bash instalar_app.sh <url de api gateway>
set -euo pipefail

API_URL="$1"
ORIGEN="$(cd "$(dirname "$0")" && pwd)"
DESTINO="/opt/dengue-app"
PUERTO=8501

# streamlit 1.40 pide python 3.9 o más, amazon linux 2023 trae 3.9 y ofrece 3.11
dnf install -y -q python3.11 python3.11-pip >/dev/null 2>&1 || true
PYTHON="$(command -v python3.11 || command -v python3)"
echo "Python: $($PYTHON --version)"

mkdir -p "$DESTINO"
cp "$ORIGEN/app.py" "$ORIGEN/requirements.txt" "$DESTINO/"
[ -x "$DESTINO/venv/bin/python" ] || "$PYTHON" -m venv "$DESTINO/venv"
"$DESTINO/venv/bin/pip" install -q --upgrade pip
echo "Instalando dependencias, la primera vez tarda unos 2 minutos"
"$DESTINO/venv/bin/pip" install -q -r "$DESTINO/requirements.txt"
chown -R ec2-user:ec2-user "$DESTINO"

cat > /etc/systemd/system/dengue-app.service <<EOF
[Unit]
Description=tablero de streamlit del dengue
After=network-online.target

[Service]
User=ec2-user
WorkingDirectory=$DESTINO
Environment=API_URL=$API_URL
ExecStart=$DESTINO/venv/bin/streamlit run app.py --server.port $PUERTO --server.address 0.0.0.0 --server.headless true --browser.gatherUsageStats false
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q dengue-app
systemctl restart dengue-app

for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:$PUERTO/_stcore/health" >/dev/null 2>&1; then
    echo "Streamlit responde en el puerto $PUERTO"
    systemctl --no-pager --lines=0 status dengue-app | head -n 3 || true
    exit 0
  fi
  sleep 2
done
journalctl -u dengue-app --no-pager -n 30
echo "ERROR: Streamlit no arrancó" >&2
exit 1
