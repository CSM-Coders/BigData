#!/usr/bin/env bash
# revisa el catálogo de glue y cuenta las filas de cada tabla con athena
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
FALLAS=0

revisar() {
  local nombre="$1" base="$2" sql="$3" esperado="$4" valor
  valor="$(athena_valor "$sql" "$base")"
  if [ "$valor" = "$esperado" ]; then
    printf 'OK     %-42s esperado %9s  athena %9s\n' "$nombre" "$esperado" "$valor"
  else
    printf 'FALLA  %-42s esperado %9s  athena %9s\n' "$nombre" "$esperado" "$valor"
    FALLAS=$((FALLAS + 1))
  fi
}

info "Bases del proyecto en el catálogo de Glue"
aws glue get-databases --output table \
  --query 'DatabaseList[?starts_with(Name, `dengue_`)].{Base:Name, Ubicacion:LocationUri, Descripcion:Description}'

info "Tablas por base"
for base in "$BD_RAW" "$BD_TRUSTED" "$BD_REFINED"; do
  tablas="$(aws glue get-tables --database-name "$base" --query 'TableList[].Name' --output text 2>/dev/null || true)"
  printf '%-16s %s\n' "$base" "${tablas:-sin tablas}"
done

info "Conteos con Athena"
revisar "trusted.casos_dengue" "$BD_TRUSTED" "SELECT count(*) FROM casos_dengue" 60747
revisar "trusted.poblacion" "$BD_TRUSTED" "SELECT count(*) FROM poblacion" 28046
revisar "trusted.municipios" "$BD_TRUSTED" "SELECT count(*) FROM municipios" 1122
revisar "trusted.clima_diario" "$BD_TRUSTED" "SELECT count(*) FROM clima_diario" 347100
revisar "raw.sivigila, ingesta reciente" "$BD_RAW" \
  "SELECT count(*) FROM sivigila WHERE fecha_ingesta = (SELECT max(fecha_ingesta) FROM sivigila)" 61234
revisar "raw.divipola, ingesta reciente" "$BD_RAW" \
  "SELECT count(*) FROM divipola WHERE fecha_ingesta = (SELECT max(fecha_ingesta) FROM divipola)" 1122
revisar "raw.openmeteo_altitud" "$BD_RAW" "SELECT count(*) FROM openmeteo_altitud" 1122
revisar "raw.openmeteo_clima, municipios" "$BD_RAW" "SELECT count(*) FROM openmeteo_clima" 300
revisar "raw.openmeteo_clima, valores diarios" "$BD_RAW" \
  "SELECT sum(cardinality(daily.temperature_2m_mean)) FROM openmeteo_clima" 347100
revisar "tablas en refined" "$BD_RAW" \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$BD_REFINED'" 7

info "Ejemplo: una tabla de raw leída con el esquema que definió Hive"
athena "SELECT ano, cod_eve, nombre_evento, count(*) AS filas, sum(conteo) AS total
FROM sivigila WHERE fecha_ingesta = (SELECT max(fecha_ingesta) FROM sivigila)
GROUP BY ano, cod_eve, nombre_evento ORDER BY ano, cod_eve" "$BD_RAW"
athena_mostrar 10
athena_estadisticas

echo
[ "$FALLAS" -eq 0 ] || falla "$FALLAS conteos no coinciden."
echo "OK: las tres zonas están catalogadas y Athena las puede leer."
