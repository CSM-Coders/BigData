#!/usr/bin/env bash
# lleva las fuentes a la zona raw del datalake, corre en la ec2
# uso: ingestar.sh todo|rds|archivos|api
set -euo pipefail

AQUI="$(cd "$(dirname "$0")" && pwd)"
source "$AQUI/config.env"
RAW="s3://$BUCKET/raw"
HOY="$(date -u +%F)"
TRABAJO="$AQUI/trabajo"
MODO="${1:-todo}"

log() { printf '%s %s\n' "$(date -u '+%F %T')" "$*"; }

for comando in aws mariadb python3 flock; do
  command -v "$comando" >/dev/null || { log "Falta el comando $comando"; exit 1; }
done

ingestar_rds() {
  local archivo="$TRABAJO/eventos_dengue.tsv"
  local destino="$RAW/sivigila/fecha_ingesta=$HOY/eventos_dengue.tsv"
  mkdir -p "$TRABAJO"
  log "RDS: exportando sivigila.eventos_dengue"
  mariadb -B -e "SELECT * FROM sivigila.eventos_dengue ORDER BY ano, semana, cod_mun_o, cod_eve" \
    > "$archivo"

  # se compara contra la tabla para no subir una exportación incompleta
  local filas esperadas
  filas=$(( $(wc -l < "$archivo") - 1 ))
  esperadas="$(mariadb -N -B -e 'SELECT COUNT(*) FROM sivigila.eventos_dengue')"
  if [ "$filas" -ne "$esperadas" ]; then
    log "RDS: ERROR, se exportaron $filas de $esperadas filas"
    return 1
  fi
  aws s3 cp --only-show-errors "$archivo" "$destino"
  log "RDS: $filas filas en $destino"
}

ingestar_archivos() {
  local fuente destino
  for fuente in poblacion divipola; do
    destino="$RAW/$fuente/fecha_ingesta=$HOY/"
    aws s3 cp --only-show-errors --recursive "$HOME/fuentes/$fuente/" "$destino"
    log "Archivos: $(ls "$HOME/fuentes/$fuente" | tr '\n' ' ')en $destino"
  done
}

ingestar_api() {
  python3 "$AQUI/openmeteo.py" --bucket "$BUCKET" --carpeta "$AQUI/openmeteo"
}

# un candado por paso, así el cron de cada hora no choca con el diario
con_candado() {
  local paso="$1"
  (
    flock -n 9 || { log "$paso: ya hay una corrida en curso, se omite"; exit 0; }
    "ingestar_$paso"
  ) 9>"$AQUI/.candado-$paso"
}

log "Inicio: $MODO"
case "$MODO" in
  todo) con_candado rds; con_candado archivos; con_candado api ;;
  rds | archivos | api) con_candado "$MODO" ;;
  *) echo "Uso: $0 todo|rds|archivos|api" >&2; exit 1 ;;
esac
log "Fin: $MODO"
