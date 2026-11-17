#!/usr/bin/env bash
# lee refined desde athena y compara las respuestas de los tres motores, solo lee en aws
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
TRUSTED_LOCAL="$RAIZ/punto4-preparacion/datos/trusted"
FALLAS=0
for archivo in $(archivos_sql); do
  [ -f "$RESULTADOS_ATHENA/$(tabla_de "$archivo").csv" ] || falla "Faltan los resultados de Athena. Ejecuta primero 00_consultas_athena.sh."
done

info "Athena lee las tablas que llenó Hive en $BD_REFINED"
for archivo in $(archivos_sql); do
  tabla="$(tabla_de "$archivo")"
  esperado="$(( $(wc -l < "$RESULTADOS_ATHENA/$tabla.csv") - 1 ))"
  filas="$(athena_valor "SELECT count(*) FROM $tabla" "$BD_REFINED")"
  estado="OK"
  [ "$filas" = "$esperado" ] || { estado="FALLA"; FALLAS=$((FALLAS + 1)); }
  printf '%-7s%-44s %6s filas\n' "$estado" "$BD_REFINED.$tabla" "$filas"
done

info "Descargando refined, los csv de Spark SQL y trusted"
mkdir -p "$DATOS_CONSULTAS" "$TRUSTED_LOCAL"
aws s3 sync --only-show-errors --delete --exclude '*$folder$' \
  "s3://$BUCKET_DATALAKE/refined/" "$DATOS_CONSULTAS/refined/"
aws s3 sync --only-show-errors --delete --exclude '*$folder$' \
  "s3://$BUCKET_ARTEFACTOS/resultados/sparksql/" "$DATOS_CONSULTAS/sparksql/"
aws s3 sync --only-show-errors --delete "s3://$BUCKET_DATALAKE/trusted/" "$TRUSTED_LOCAL/"

PYTHON="$RAIZ/.venv/bin/python"
[ -x "$PYTHON" ] || PYTHON="python3"
"$PYTHON" -c 'import pandas, pyarrow' 2>/dev/null ||
  falla "Faltan pandas o pyarrow. Activa .venv y corre pip install -r requirements.txt."

info "Comparando Athena, Hive y Spark SQL con el cálculo en pandas"
"$PYTHON" "$DIR_CONSULTAS/comparar_motores.py" "$TRUSTED_LOCAL" "$RESULTADOS_ATHENA" \
  "$DATOS_CONSULTAS/refined" "$DATOS_CONSULTAS/sparksql"

[ "$FALLAS" -eq 0 ] || falla "$FALLAS tablas de refined no tienen las filas esperadas."
