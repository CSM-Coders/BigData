#!/usr/bin/env bash
# variables del análisis con pyspark, reusa las del punto 5
DIR_PYSPARK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR_PYSPARK/../punto5-catalogacion/comun.sh"

JOB_LOCAL="$DIR_PYSPARK/pyspark/analisis_dengue.py"
TABLAS_PYSPARK="municipio_anual serie_semanal_departamento estadisticas_incidencia"
# tablas del punto 6 contra las que compara el job
TABLAS_PUNTO6="incidencia_departamento incidencia_municipio estacionalidad_departamento brote_2024_departamento clima_rezago gravedad_departamento incidencia_altitud"
