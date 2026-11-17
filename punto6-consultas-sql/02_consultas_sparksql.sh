#!/usr/bin/env bash
# corre las mismas consultas en spark sql y deja cada respuesta en csv
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
emr_activo
SCRIPT="s3://$BUCKET_ARTEFACTOS/emr/consultas_sparksql.sql"
DESTINO="s3://$BUCKET_ARTEFACTOS/resultados/sparksql"
TEMPORAL="$(mktemp)"
trap 'rm -f "$TEMPORAL"' EXIT

info "Armando el script de Spark SQL con las $(archivos_sql | wc -l | tr -d ' ') consultas"
generar_sparksql "$DESTINO" > "$TEMPORAL"
aws s3 cp --only-show-errors "$TEMPORAL" "$SCRIPT"
echo "$SCRIPT"

info "Corriendo las consultas en Spark SQL"
ejecutar_paso "Consultas en Spark SQL" \
  "aws s3 cp $SCRIPT /tmp/consultas_sparksql.sql && spark-sql --conf spark.hadoop.hive.cli.print.header=true -f /tmp/consultas_sparksql.sql"

info "Salida de Spark SQL"
ver_log_paso stdout

info "Resultados en $DESTINO"
aws s3 ls "$DESTINO/" | grep -v '\$folder\$'
