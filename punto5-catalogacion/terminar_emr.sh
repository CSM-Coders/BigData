#!/usr/bin/env bash
# apaga el cluster de emr, el catálogo y los datos quedan en glue y s3
source "$(dirname "$0")/comun.sh"

verificar_sesion
ID_EMR="$(emr_id)"
if ! existe "$ID_EMR"; then
  echo "No hay un cluster $EMR_NOMBRE activo."
  exit 0
fi

info "Terminando el cluster $ID_EMR"
aws emr terminate-clusters --cluster-ids "$ID_EMR"
aws emr wait cluster-terminated --cluster-id "$ID_EMR"
aws emr describe-cluster --cluster-id "$ID_EMR" --query 'Cluster.Status.State' --output text
