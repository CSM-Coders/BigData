#!/usr/bin/env bash
# corre las mismas consultas en hive y guarda las respuestas en las tablas de refined
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
aws glue get-database --name "$BD_REFINED" >/dev/null 2>&1 ||
  falla "No existe la base $BD_REFINED. Ejecuta primero punto5-catalogacion/02_catalogar_hive.sh."
emr_activo
SCRIPT="s3://$BUCKET_ARTEFACTOS/emr/consultas_hive.hql"
TEMPORAL="$(mktemp)"
trap 'rm -f "$TEMPORAL"' EXIT

info "Armando el script de Hive con las $(archivos_sql | wc -l | tr -d ' ') consultas"
generar_hive > "$TEMPORAL"
aws s3 cp --only-show-errors "$TEMPORAL" "$SCRIPT"
echo "$SCRIPT"

info "Corriendo las consultas en Hive"
ejecutar_paso "Consultas en Hive" \
  "aws s3 cp $SCRIPT /tmp/consultas_hive.hql && hive -f /tmp/consultas_hive.hql"

info "Salida de Hive"
ver_log_paso stdout

info "Zona refined"
aws s3 ls "s3://$BUCKET_DATALAKE/refined/" --recursive --summarize --human-readable | grep -v '\$folder\$' | tail -n 2
aws s3 ls "s3://$BUCKET_DATALAKE/refined/" | grep -v '\$folder\$'
