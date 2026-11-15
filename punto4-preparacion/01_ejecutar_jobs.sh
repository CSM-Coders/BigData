#!/usr/bin/env bash
# corre el workflow de glue y espera a que terminen los cuatro jobs
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
ESPERA_S=20
MAX_ESPERA_MIN=40

info "Iniciando el workflow $WORKFLOW"
CORRIDA="$(aws glue start-workflow-run --name "$WORKFLOW" --query 'RunId' --output text)"
echo "Corrida: $CORRIDA"

inicio="$(date +%s)"
while true; do
  read -r estado total exitosas fallidas corriendo < <(aws glue get-workflow-run \
    --name "$WORKFLOW" --run-id "$CORRIDA" --output text --query \
    'Run.[Status, Statistics.TotalActions, Statistics.SucceededActions, Statistics.FailedActions, Statistics.RunningActions]')
  minutos=$(( ($(date +%s) - inicio) / 60 ))
  printf '%s  min %s  estado %s  exitosos %s de %s  fallidos %s  corriendo %s\n' \
    "$(date '+%H:%M:%S')" "$minutos" "$estado" "$exitosas" "$total" "$fallidas" "$corriendo"
  [ "$estado" = "COMPLETED" ] || [ "$estado" = "STOPPED" ] || [ "$estado" = "ERROR" ] && break
  [ "$minutos" -ge "$MAX_ESPERA_MIN" ] && falla "El workflow lleva más de $MAX_ESPERA_MIN minutos."
  sleep "$ESPERA_S"
done

info "Resultado de cada job"
aws glue get-workflow-run --name "$WORKFLOW" --run-id "$CORRIDA" --include-graph --output table \
  --query 'Run.Graph.Nodes[?Type==`JOB`].{Job:Name, Estado:JobDetails.JobRuns[0].JobRunState, Segundos:JobDetails.JobRuns[0].ExecutionTime, Error:JobDetails.JobRuns[0].ErrorMessage}'

# cada job deja sus conteos en el bucket de artefactos
info "Métricas de los jobs"
for job in $JOBS; do
  echo "trusted_$job:"
  aws s3 cp --only-show-errors "s3://$BUCKET_ARTEFACTOS/metricas/trusted_$job.json" - 2>/dev/null |
    sed 's/^/  /' || echo "  sin métricas"
done

[ "$estado" = "COMPLETED" ] && [ "$fallidas" = "0" ] && [ "$exitosas" = "$total" ] ||
  falla "Algún job falló. Revisa el error arriba o los logs en CloudWatch (/aws-glue/jobs/error)."
echo
echo "OK: los $total jobs terminaron bien."
