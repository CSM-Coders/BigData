#!/usr/bin/env bash
# variables del catálogo, emr y athena, reusa las del punto 4
DIR_CATALOGO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR_CATALOGO/../punto4-preparacion/comun.sh"

BD_TRUSTED="dengue_trusted"
BD_RAW="dengue_raw"
BD_REFINED="dengue_refined"
CRAWLER="dengue-crawler-trusted"
TABLAS_TRUSTED="casos_dengue poblacion municipios clima_diario"

EMR_NOMBRE="dengue-emr"
EMR_VERSION="${EMR_VERSION:-emr-7.5.0}"
EMR_TIPO="${EMR_TIPO:-m5.xlarge}"
EMR_NUCLEOS="${EMR_NUCLEOS:-2}"
EMR_ROL="EMR_DefaultRole"
EMR_PERFIL="EMR_EC2_DefaultRole"
# se apaga solo si pasa una hora sin trabajo
EMR_INACTIVO_S=3600

ESPERA_S=15

emr_id() {
  aws emr list-clusters --active --output text \
    --query "Clusters[?Name=='$EMR_NOMBRE'] | [0].Id"
}

emr_activo() {
  ID_EMR="$(emr_id)"
  existe "$ID_EMR" || falla "No hay un cluster $EMR_NOMBRE activo. Créalo con punto5-catalogacion/01_crear_emr.sh."
  local estado
  estado="$(aws emr describe-cluster --cluster-id "$ID_EMR" --query 'Cluster.Status.State' --output text)"
  [ "$estado" = "WAITING" ] || [ "$estado" = "RUNNING" ] ||
    falla "El cluster $ID_EMR está en $estado. Espera a que quede en WAITING."
}

# corre un comando de bash en el nodo maestro como paso de emr y espera a que termine
ejecutar_paso() {
  local nombre="$1" comando="$2" pasos estado inicio minutos
  pasos="$(python3 -c 'import json,sys; print(json.dumps([{"Type": "CUSTOM_JAR", "Name": sys.argv[1], "ActionOnFailure": "CONTINUE", "Jar": "command-runner.jar", "Args": ["bash", "-c", sys.argv[2]]}]))' "$nombre" "$comando")"
  PASO="$(aws emr add-steps --cluster-id "$ID_EMR" --steps "$pasos" --query 'StepIds[0]' --output text)"
  echo "Paso: $PASO"
  inicio="$(date +%s)"
  while true; do
    estado="$(aws emr describe-step --cluster-id "$ID_EMR" --step-id "$PASO" --query 'Step.Status.State' --output text)"
    minutos=$(( ($(date +%s) - inicio) / 60 ))
    printf '%s  min %s  estado %s\n' "$(date '+%H:%M:%S')" "$minutos" "$estado"
    case "$estado" in
      COMPLETED) return 0 ;;
      FAILED|CANCELLED|INTERRUPTED)
        ver_log_paso stderr 40 || true
        falla "El paso $nombre terminó en $estado." ;;
    esac
    [ "$minutos" -ge 40 ] && falla "El paso lleva más de 40 minutos."
    sleep "$ESPERA_S"
  done
}

# fecha iso a segundos, sin decimales para que sirva en cualquier python 3
a_segundos() {
  python3 -c 'import re, sys, datetime
t = re.sub(r"\.\d+", "", sys.argv[1]).replace("Z", "+00:00")
print(int(datetime.datetime.fromisoformat(t).timestamp()))' "$1"
}

# emr sube los logs de cada paso a s3 unos minutos después de terminar
# mientras corre puede subir uno parcial, por eso se espera uno posterior al fin del paso
ver_log_paso() {
  local tipo="$1" lineas="${2:-0}" clave ruta intento fin subido
  clave="emr-logs/$ID_EMR/steps/$PASO/$tipo.gz"
  ruta="s3://$BUCKET_ARTEFACTOS/$clave"
  fin="$(aws emr describe-step --cluster-id "$ID_EMR" --step-id "$PASO" \
    --query 'Step.Status.Timeline.EndDateTime' --output text)"
  for intento in $(seq 1 40); do
    subido="$(aws s3api head-object --bucket "$BUCKET_ARTEFACTOS" --key "$clave" \
      --query LastModified --output text 2>/dev/null || true)"
    if [ -n "$subido" ] && { [ "$fin" = "None" ] || [ "$(a_segundos "$subido")" -gt "$(a_segundos "$fin")" ]; }; then
      if [ "$lineas" -gt 0 ]; then
        aws s3 cp --only-show-errors "$ruta" - | gunzip | tail -n "$lineas"
      else
        aws s3 cp --only-show-errors "$ruta" - | gunzip
      fi
      return 0
    fi
    [ "$intento" = 1 ] && echo "Esperando a que emr suba el log $tipo del paso, puede tardar unos 5 minutos..."
    sleep 15
  done
  echo "No apareció $ruta. Revisa el paso en la consola de EMR."
  return 1
}

# corre una consulta en athena y deja su id en ID_ATHENA
athena() {
  local sql="$1" base="$2" estado motivo
  ID_ATHENA="$(aws athena start-query-execution --work-group primary \
    --query-string "$sql" --query-execution-context "Database=$base" \
    --result-configuration "OutputLocation=s3://$BUCKET_ARTEFACTOS/athena/" \
    --query QueryExecutionId --output text)"
  while true; do
    estado="$(aws athena get-query-execution --query-execution-id "$ID_ATHENA" \
      --query 'QueryExecution.Status.State' --output text)"
    case "$estado" in
      SUCCEEDED) return 0 ;;
      FAILED|CANCELLED)
        motivo="$(aws athena get-query-execution --query-execution-id "$ID_ATHENA" \
          --query 'QueryExecution.Status.StateChangeReason' --output text)"
        falla "Athena: $motivo" ;;
    esac
    sleep 2
  done
}

# primer valor del resultado
athena_valor() {
  athena "$1" "$2"
  aws athena get-query-results --query-execution-id "$ID_ATHENA" \
    --query 'ResultSet.Rows[1].Data[0].VarCharValue' --output text
}

# imprime las primeras filas como tabla
athena_mostrar() {
  aws athena get-query-results --query-execution-id "$ID_ATHENA" --max-items "$(( ${1:-10} + 1 ))" --output json |
    python3 -c '
import json, sys
filas = [[c.get("VarCharValue", "") for c in f["Data"]] for f in json.load(sys.stdin)["ResultSet"]["Rows"]]
anchos = [max(len(f[i]) for f in filas) for i in range(len(filas[0]))]
for f in filas:
    print("  ".join(v.ljust(a) for v, a in zip(f, anchos)).rstrip())'
}

athena_estadisticas() {
  aws athena get-query-execution --query-execution-id "$ID_ATHENA" --output text \
    --query 'QueryExecution.Statistics.[EngineExecutionTimeInMillis, DataScannedInBytes]' |
    awk '{printf "Tiempo: %.1f s  Datos leídos: %.1f MB\n", $1 / 1000, $2 / 1048576}'
}
