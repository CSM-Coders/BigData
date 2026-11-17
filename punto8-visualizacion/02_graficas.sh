#!/usr/bin/env bash
# hace las gráficas de matplotlib con los datos de la api, solo lee en aws
source "$(dirname "$0")/comun.sh"

verificar_sesion
api_existente
PYTHON="$RAIZ/.venv/bin/python"
[ -x "$PYTHON" ] || PYTHON="python3"
"$PYTHON" -c 'import matplotlib, pandas, requests' 2>/dev/null ||
  falla "Faltan matplotlib, pandas o requests. Activa .venv y corre pip install -r requirements.txt."

info "Gráficas con los datos de $API_URL"
"$PYTHON" "$DIR_VISUALIZACION/graficas.py" --api "$API_URL" --salida "$DIR_GRAFICAS"
