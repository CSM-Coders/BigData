#!/usr/bin/env bash
# corre hive/catalogo.hql en emr: cataloga raw y crea las tablas de refined
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
aws glue get-database --name "$BD_TRUSTED" >/dev/null 2>&1 ||
  falla "No existe la base $BD_TRUSTED. Ejecuta primero 00_crear_crawler.sh."
emr_activo
SCRIPT="s3://$BUCKET_ARTEFACTOS/emr/catalogo.hql"

info "Subiendo el script a $SCRIPT"
aws s3 cp --only-show-errors "$DIR_CATALOGO/hive/catalogo.hql" "$SCRIPT"

# el jsonserde de hcatalog lee los json de open-meteo, athena también lo entiende
info "Corriendo el catálogo en Hive"
ejecutar_paso "Catálogo de Hive" \
  "aws s3 cp $SCRIPT /tmp/catalogo.hql && JAR=\$(find /usr/lib -name 'hive-hcatalog-core*.jar' 2>/dev/null | head -n 1) && test -n \"\$JAR\" && hive --hivevar datalake=$BUCKET_DATALAKE --hivevar jar_json=\$JAR -f /tmp/catalogo.hql"

info "Salida de Hive"
ver_log_paso stdout

for base in "$BD_RAW" "$BD_REFINED"; do
  info "Tablas que Hive dejó en el catálogo de Glue: $base"
  aws glue get-tables --database-name "$base" --output table \
    --query 'TableList[].{Tabla:Name, Tipo:TableType, Formato:StorageDescriptor.SerdeInfo.SerializationLibrary, Particion:join(`, `, PartitionKeys[].Name)}'
done
