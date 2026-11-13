#!/usr/bin/env bash
# variables del datalake, reusa las funciones del punto 2
DIR_INGESTA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR_INGESTA/../punto2-fuentes-datos/comun.sh"

RESULTADOS_PUNTO1="$RAIZ/punto1-caso-estudio/resultados"
ZONAS="raw trusted refined"

# los nombres de bucket son globales, por eso llevan el id de la cuenta
nombres_buckets() {
  local cuenta
  cuenta="$(aws sts get-caller-identity --query Account --output text)"
  BUCKET_DATALAKE="dengue-datalake-$cuenta"
  BUCKET_ARTEFACTOS="dengue-artefactos-$cuenta"
}

ip_ec2_encendida() {
  IP_EC2="$(ec2_ip)"
  existe "$IP_EC2" || falla "La EC2 no tiene IP pública. Enciéndela con encender_apagar.sh iniciar."
}
