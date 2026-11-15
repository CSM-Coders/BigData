#!/usr/bin/env bash
# variables de los jobs de glue, reusa las del punto 3
DIR_PREPARACION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR_PREPARACION/../punto3-ingesta/comun.sh"

JOBS="casos poblacion municipios clima"
PREFIJO_JOB="dengue-trusted"
WORKFLOW="dengue-raw-a-trusted"
TRIGGER_INICIO="dengue-inicio-trusted"
GLUE_VERSION="5.0"
GLUE_WORKER="G.1X"
GLUE_WORKERS=2
GLUE_TIMEOUT_MIN=30
# glue no trae openpyxl, se instala al arrancar el job de población
MODULOS_POBLACION="openpyxl==3.1.5"
