#!/usr/bin/env bash
# crea la base dengue_trusted en el catálogo de glue y el crawler que descubre sus tablas
# se puede repetir, si ya existen los actualiza y vuelve a correr el crawler
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
aws s3 ls "s3://$BUCKET_DATALAKE/trusted/casos_dengue/" >/dev/null 2>&1 ||
  falla "La zona trusted está vacía. Termina primero el punto 4."
ROL="$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text)"
TEMPORAL="$(mktemp -d)"
trap 'rm -rf "$TEMPORAL"' EXIT

info "Creando la base $BD_TRUSTED en el catálogo de Glue"
if aws glue get-database --name "$BD_TRUSTED" >/dev/null 2>&1; then
  echo "Ya existe $BD_TRUSTED"
else
  aws glue create-database --database-input "{\"Name\": \"$BD_TRUSTED\",
    \"Description\": \"zona trusted: datos limpios en parquet, catalogados por el crawler\",
    \"LocationUri\": \"s3://$BUCKET_DATALAKE/trusted/\"}"
  echo "Creada $BD_TRUSTED"
fi

# una ruta por tabla, así cada carpeta queda como una tabla con su nombre
python3 - "$BUCKET_DATALAKE" $TABLAS_TRUSTED > "$TEMPORAL/objetivos.json" <<'PY'
import json
import sys

bucket, tablas = sys.argv[1], sys.argv[2:]
print(json.dumps({"S3Targets": [
    {"Path": f"s3://{bucket}/trusted/{tabla}/", "Exclusions": ["**/_SUCCESS", "**/_temporary/**"]}
    for tabla in tablas
]}))
PY
CONFIGURACION='{"Version": 1.0, "CrawlerOutput": {"Partitions": {"AddOrUpdateBehavior": "InheritFromTable"}}}'

info "Creando el crawler $CRAWLER"
if aws glue get-crawler --name "$CRAWLER" >/dev/null 2>&1; then
  aws glue update-crawler --name "$CRAWLER" --role "$ROL" --database-name "$BD_TRUSTED" \
    --targets "file://$TEMPORAL/objetivos.json" --configuration "$CONFIGURACION" \
    --schema-change-policy UpdateBehavior=UPDATE_IN_DATABASE,DeleteBehavior=LOG \
    --recrawl-policy RecrawlBehavior=CRAWL_EVERYTHING
  echo "Actualizado $CRAWLER"
else
  aws glue create-crawler --name "$CRAWLER" --role "$ROL" --database-name "$BD_TRUSTED" \
    --description "descubre las tablas de la zona trusted" \
    --targets "file://$TEMPORAL/objetivos.json" --configuration "$CONFIGURACION" \
    --schema-change-policy UpdateBehavior=UPDATE_IN_DATABASE,DeleteBehavior=LOG \
    --recrawl-policy RecrawlBehavior=CRAWL_EVERYTHING --tags "Proyecto=$PROYECTO"
  echo "Creado $CRAWLER"
fi

info "Corriendo el crawler, tarda 1 o 2 minutos"
aws glue start-crawler --name "$CRAWLER"
sleep 10
inicio="$(date +%s)"
while true; do
  estado="$(aws glue get-crawler --name "$CRAWLER" --query 'Crawler.State' --output text)"
  printf '%s  min %s  estado %s\n' "$(date '+%H:%M:%S')" "$(( ($(date +%s) - inicio) / 60 ))" "$estado"
  [ "$estado" = "READY" ] && break
  sleep "$ESPERA_S"
done

read -r resultado error < <(aws glue get-crawler --name "$CRAWLER" --output text \
  --query 'Crawler.LastCrawl.[Status, ErrorMessage]')
[ "$resultado" = "SUCCEEDED" ] || falla "El crawler terminó en $resultado: $error"
aws glue get-crawler-metrics --crawler-name-list "$CRAWLER" --output table \
  --query 'CrawlerMetricsList[0].{Creadas:TablesCreated, Actualizadas:TablesUpdated, Borradas:TablesDeleted, Segundos:LastRuntimeSeconds}'

info "Tablas de $BD_TRUSTED"
aws glue get-tables --database-name "$BD_TRUSTED" --output table \
  --query 'TableList[].{Tabla:Name, Formato:Parameters.classification, Columnas:length(StorageDescriptor.Columns), Particion:join(`, `, PartitionKeys[].Name), Ubicacion:StorageDescriptor.Location}'

info "Esquema que encontró el crawler para casos_dengue"
aws glue get-table --database-name "$BD_TRUSTED" --name casos_dengue --output text \
  --query 'Table.[StorageDescriptor.Columns[].[Name, Type], PartitionKeys[].[Name, Type]][]' |
  awk '{printf "  %-22s %s\n", $1, $2}'

for tabla in $TABLAS_TRUSTED; do
  existe "$(aws glue get-table --database-name "$BD_TRUSTED" --name "$tabla" --query 'Table.Name' --output text 2>/dev/null)" ||
    falla "El crawler no creó la tabla $tabla."
done
echo
echo "OK: el crawler catalogó las $(wc -w <<<"$TABLAS_TRUSTED" | tr -d ' ') tablas de trusted."
