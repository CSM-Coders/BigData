#!/usr/bin/env bash
# sube el código de los jobs y crea los jobs y el workflow de glue
# se puede repetir, si ya existen los actualiza
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
aws s3api head-bucket --bucket "$BUCKET_ARTEFACTOS" >/dev/null 2>&1 ||
  falla "No existe s3://$BUCKET_ARTEFACTOS. Ejecuta primero punto3-ingesta/00_crear_buckets.sh."
ROL="$(aws iam get-role --role-name LabRole --query 'Role.Arn' --output text)"
CODIGO="s3://$BUCKET_ARTEFACTOS/glue"
TEMPORAL="$(mktemp -d)"
trap 'rm -rf "$TEMPORAL"' EXIT

info "Subiendo el código a $CODIGO"
aws s3 sync --only-show-errors --delete --exclude '*' --include '*.py' \
  "$DIR_PREPARACION/jobs/" "$CODIGO/"
aws s3 ls "$CODIGO/"

# arma la definición del job en json, así no hay que escapar comillas en bash
definicion_job() {
  python3 - "$@" <<'PY'
import json
import sys

job, rol, codigo, datalake, artefactos, version, worker, workers, timeout, modulos = sys.argv[1:]
argumentos = {
    "--job-language": "python",
    "--RAW": f"s3://{datalake}/raw",
    "--TRUSTED": f"s3://{datalake}/trusted",
    "--METRICAS": f"s3://{artefactos}/metricas",
    "--extra-py-files": f"{codigo}/utilidades.py",
    "--TempDir": f"s3://{artefactos}/glue-temporal/",
    "--enable-metrics": "true",
    "--enable-continuous-cloudwatch-log": "true",
    "--enable-glue-datacatalog": "true",
}
if modulos:
    argumentos["--additional-python-modules"] = modulos
print(json.dumps({
    "Role": rol,
    "Description": f"raw a trusted: {job}",
    "Command": {
        "Name": "glueetl",
        "ScriptLocation": f"{codigo}/trusted_{job}.py",
        "PythonVersion": "3",
    },
    "DefaultArguments": argumentos,
    "GlueVersion": version,
    "WorkerType": worker,
    "NumberOfWorkers": int(workers),
    "Timeout": int(timeout),
    "ExecutionProperty": {"MaxConcurrentRuns": 1},
}))
PY
}

info "Creando los jobs"
ACCIONES=()
for job in $JOBS; do
  nombre="$PREFIJO_JOB-$job"
  modulos=""
  [ "$job" = "poblacion" ] && modulos="$MODULOS_POBLACION"
  definicion="$(definicion_job "$job" "$ROL" "$CODIGO" "$BUCKET_DATALAKE" "$BUCKET_ARTEFACTOS" \
    "$GLUE_VERSION" "$GLUE_WORKER" "$GLUE_WORKERS" "$GLUE_TIMEOUT_MIN" "$modulos")"

  if existe "$(aws glue get-job --job-name "$nombre" --query 'Job.Name' --output text 2>/dev/null)"; then
    printf '%s' "$definicion" > "$TEMPORAL/job.json"
    aws glue update-job --job-name "$nombre" --job-update "file://$TEMPORAL/job.json" >/dev/null
    echo "Actualizado $nombre"
  else
    printf '%s' "$definicion" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); d['Name']=sys.argv[1]; d['Tags']={'Proyecto': sys.argv[2]}; print(json.dumps(d))" \
      "$nombre" "$PROYECTO" > "$TEMPORAL/job.json"
    aws glue create-job --cli-input-json "file://$TEMPORAL/job.json" >/dev/null
    echo "Creado $nombre"
  fi
  ACCIONES+=("JobName=$nombre")
done

# los cuatro jobs no dependen entre sí, el workflow los lanza en paralelo
info "Creando el workflow $WORKFLOW"
if existe "$(aws glue get-workflow --name "$WORKFLOW" --query 'Workflow.Name' --output text 2>/dev/null)"; then
  echo "Ya existe $WORKFLOW"
else
  aws glue create-workflow --name "$WORKFLOW" \
    --description "Preparación de raw a trusted del datalake de dengue" \
    --tags "Proyecto=$PROYECTO" >/dev/null
  echo "Creado $WORKFLOW"
fi

if existe "$(aws glue get-trigger --name "$TRIGGER_INICIO" --query 'Trigger.Name' --output text 2>/dev/null)"; then
  python3 -c "import json,sys; print(json.dumps({'Actions': [{'JobName': a.split('=', 1)[1]} for a in sys.argv[1:]]}))" \
    "${ACCIONES[@]}" > "$TEMPORAL/trigger.json"
  aws glue update-trigger --name "$TRIGGER_INICIO" --trigger-update "file://$TEMPORAL/trigger.json" >/dev/null
  echo "Actualizado $TRIGGER_INICIO"
else
  aws glue create-trigger --name "$TRIGGER_INICIO" --workflow-name "$WORKFLOW" \
    --type ON_DEMAND --actions "${ACCIONES[@]}" --tags "Proyecto=$PROYECTO" >/dev/null
  echo "Creado $TRIGGER_INICIO"
fi

info "Jobs de glue del proyecto"
aws glue list-jobs --tags "Proyecto=$PROYECTO" --query 'JobNames' --output table
