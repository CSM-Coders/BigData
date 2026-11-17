#!/usr/bin/env bash
# corre pyspark/analisis_dengue.py con spark-submit como paso de emr
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
for tabla in $TABLAS_PUNTO6; do
  archivos="$(aws s3 ls "s3://$BUCKET_DATALAKE/refined/$tabla/" 2>/dev/null | grep -vc '\$folder\$' || true)"
  [ "${archivos:-0}" -gt 0 ] || falla "refined/$tabla está vacía. Ejecuta primero el punto 6."
done
emr_activo
SCRIPT="s3://$BUCKET_ARTEFACTOS/emr/analisis_dengue.py"

info "Subiendo el job a $SCRIPT"
aws s3 cp --only-show-errors "$JOB_LOCAL" "$SCRIPT"

info "Corriendo el análisis con PySpark"
ejecutar_paso "Análisis con PySpark" \
  "aws s3 cp $SCRIPT /tmp/analisis_dengue.py && spark-submit --deploy-mode client /tmp/analisis_dengue.py --datalake $BUCKET_DATALAKE"

info "Salida de PySpark"
ver_log_paso stdout

info "Tablas de $BD_REFINED en el catálogo de Glue"
aws glue get-tables --database-name "$BD_REFINED" --output table \
  --query 'TableList[].{Tabla:Name, Columnas:length(StorageDescriptor.Columns), Ubicacion:StorageDescriptor.Location}'
