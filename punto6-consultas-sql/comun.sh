#!/usr/bin/env bash
# variables y funciones de las consultas, reusa las del punto 5
DIR_CONSULTAS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR_CONSULTAS/../punto5-catalogacion/comun.sh"

CARPETA_SQL="$DIR_CONSULTAS/consultas"
RESULTADOS_ATHENA="$DIR_CONSULTAS/resultados/athena"
DATOS_CONSULTAS="$DIR_CONSULTAS/datos"
FILAS_MUESTRA=10

# un archivo por pregunta, en orden
archivos_sql() { find "$CARPETA_SQL" -name 'p*.sql' | sort; }

# p1_incidencia_departamento.sql escribe la tabla incidencia_departamento
tabla_de() { basename "$1" .sql | sed 's/^p[0-9]*_//'; }

# hive llena las tablas de refined que se crearon en el punto 5
generar_hive() {
  echo "SET hive.cli.print.header=true;"
  echo "SET hive.strict.checks.cartesian.product=false;"
  echo "USE $BD_TRUSTED;"
  local archivo tabla
  for archivo in $(archivos_sql); do
    tabla="$(tabla_de "$archivo")"
    printf '\nINSERT OVERWRITE TABLE %s.%s\n' "$BD_REFINED" "$tabla"
    cat "$archivo"
    printf ';\n\nSELECT * FROM %s.%s LIMIT %s;\n' "$BD_REFINED" "$tabla" "$FILAS_MUESTRA"
  done
}

# spark sql deja cada respuesta en csv dentro de $1
generar_sparksql() {
  local destino="$1" archivo tabla
  echo "USE $BD_TRUSTED;"
  for archivo in $(archivos_sql); do
    tabla="$(tabla_de "$archivo")"
    printf '\nCREATE OR REPLACE TEMPORARY VIEW %s AS\n' "$tabla"
    cat "$archivo"
    printf ';\n\nINSERT OVERWRITE DIRECTORY '"'"'%s/%s'"'"' USING csv OPTIONS (header '"'"'true'"'"')\n' "$destino" "$tabla"
    printf 'SELECT * FROM %s;\n\nSELECT * FROM %s LIMIT %s;\n' "$tabla" "$tabla" "$FILAS_MUESTRA"
  done
}
