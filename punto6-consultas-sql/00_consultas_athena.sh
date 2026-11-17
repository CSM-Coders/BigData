#!/usr/bin/env bash
# responde las preguntas con athena sobre dengue_trusted y guarda cada resultado en csv
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
for tabla in $TABLAS_TRUSTED; do
  aws glue get-table --database-name "$BD_TRUSTED" --name "$tabla" >/dev/null 2>&1 ||
    falla "No existe $BD_TRUSTED.$tabla. Termina primero el punto 5."
done
mkdir -p "$RESULTADOS_ATHENA"

for archivo in $(archivos_sql); do
  tabla="$(tabla_de "$archivo")"
  info "$(basename "$archivo"): $tabla"
  athena "$(cat "$archivo")" "$BD_TRUSTED"
  athena_mostrar "$FILAS_MUESTRA"
  salida="$(aws athena get-query-execution --query-execution-id "$ID_ATHENA" \
    --query 'QueryExecution.ResultConfiguration.OutputLocation' --output text)"
  aws s3 cp --only-show-errors "$salida" "$RESULTADOS_ATHENA/$tabla.csv"
  printf 'Filas: %s  ' "$(( $(wc -l < "$RESULTADOS_ATHENA/$tabla.csv") - 1 ))"
  athena_estadisticas
done

echo
echo "OK: las $(archivos_sql | wc -l | tr -d ' ') consultas terminaron. Resultados en ${RESULTADOS_ATHENA#"$RAIZ"/}/"
