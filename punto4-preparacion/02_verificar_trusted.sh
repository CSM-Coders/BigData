#!/usr/bin/env bash
# baja la zona trusted y la compara con los datos del punto 1, solo lee en aws
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
LOCAL="$DIR_PREPARACION/datos/trusted"

info "Tablas en s3://$BUCKET_DATALAKE/trusted/"
aws s3 ls "s3://$BUCKET_DATALAKE/trusted/" --recursive --summarize --human-readable | tail -n 2
aws s3 ls "s3://$BUCKET_DATALAKE/trusted/"

info "Descargando trusted para revisarla"
mkdir -p "$LOCAL"
aws s3 sync --only-show-errors --delete "s3://$BUCKET_DATALAKE/trusted/" "$LOCAL/"

# usa el entorno del punto 1, que ya tiene pandas
PYTHON="$RAIZ/.venv/bin/python"
[ -x "$PYTHON" ] || PYTHON="python3"
"$PYTHON" -c 'import pandas, pyarrow' 2>/dev/null ||
  falla "Faltan pandas o pyarrow. Activa .venv y corre pip install -r requirements.txt."

info "Comparando con el punto 1"
"$PYTHON" "$DIR_PREPARACION/verificar_trusted.py" "$LOCAL"
