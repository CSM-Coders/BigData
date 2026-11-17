#!/usr/bin/env bash
# lee con athena las tablas que escribió pyspark y las cruza con trusted y refined, solo lee en aws
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
FALLAS=0

revisar() {
  local nombre="$1" esperado="$2" valor="$3"
  if [ "$valor" = "$esperado" ]; then
    printf 'OK     %-46s esperado %9s  athena %9s\n' "$nombre" "$esperado" "$valor"
  else
    printf 'FALLA  %-46s esperado %9s  athena %9s\n' "$nombre" "$esperado" "$valor"
    FALLAS=$((FALLAS + 1))
  fi
}

info "Filas de las tablas que escribió PySpark"
revisar "refined.municipio_anual" 3364 "$(athena_valor "SELECT count(*) FROM municipio_anual" "$BD_REFINED")"
revisar "refined.serie_semanal_departamento" 4802 "$(athena_valor "SELECT count(*) FROM serie_semanal_departamento" "$BD_REFINED")"
revisar "refined.estadisticas_incidencia" 3 "$(athena_valor "SELECT count(*) FROM estadisticas_incidencia" "$BD_REFINED")"

info "Totales cruzados con las otras tablas"
revisar "casos de la serie semanal y de trusted" \
  "$(athena_valor "SELECT sum(conteo) FROM casos_dengue WHERE tipo_evento = 'caso'" "$BD_TRUSTED")" \
  "$(athena_valor "SELECT sum(casos) FROM serie_semanal_departamento" "$BD_REFINED")"
revisar "muertes de la serie semanal y de trusted" \
  "$(athena_valor "SELECT sum(conteo) FROM casos_dengue WHERE tipo_evento = 'muerte'" "$BD_TRUSTED")" \
  "$(athena_valor "SELECT sum(muertes) FROM serie_semanal_departamento" "$BD_REFINED")"
revisar "casos por municipio y por departamento, 2024" \
  "$(athena_valor "SELECT sum(casos) FROM incidencia_departamento WHERE ano = 2024" "$BD_REFINED")" \
  "$(athena_valor "SELECT sum(casos) FROM municipio_anual WHERE ano = 2024" "$BD_REFINED")"
revisar "municipios con clima en 2024" 300 \
  "$(athena_valor "SELECT count(*) FROM municipio_anual WHERE ano = 2024 AND temperatura_media_c IS NOT NULL" "$BD_REFINED")"

info "Estadísticas de la incidencia municipal, leídas con Athena"
athena "SELECT ano, municipios_con_casos, media, mediana, p90, maximo, municipios_mitad_casos,
       pct_casos_10pct_municipios
FROM estadisticas_incidencia ORDER BY ano" "$BD_REFINED"
athena_mostrar 3

info "Ejemplo: municipios del Valle del Cauca con más casos en 2024"
athena "SELECT municipio, altitud_m, poblacion, casos, incidencia_100k, temperatura_media_c, lluvia_anual_mm
FROM municipio_anual WHERE ano = 2024 AND cod_dpto = '76'
ORDER BY casos DESC LIMIT 5" "$BD_REFINED"
athena_mostrar 5
athena_estadisticas

echo
[ "$FALLAS" -eq 0 ] || falla "$FALLAS revisiones no coinciden."
echo "OK: Athena lee las 3 tablas de PySpark y cuadran con trusted y refined."
