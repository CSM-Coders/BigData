#!/usr/bin/env bash
# prende o apaga la ec2 y la rds
# uso: ./encender_apagar.sh iniciar|detener|estado
source "$(dirname "$0")/comun.sh"

verificar_sesion
ACCION="${1:-estado}"
ID="$(ec2_id)"
ESTADO_RDS="$(rds_estado)"

case "$ACCION" in
  iniciar)
    existe "$ID" && aws ec2 start-instances --instance-ids "$ID" >/dev/null
    if [ "$ESTADO_RDS" = "stopped" ]; then
      aws rds start-db-instance --db-instance-identifier "$RDS_ID" >/dev/null
    fi
    info "Esperando a que EC2 y RDS queden disponibles"
    existe "$ID" && aws ec2 wait instance-running --instance-ids "$ID"
    existe "$ESTADO_RDS" && aws rds wait db-instance-available --db-instance-identifier "$RDS_ID"
    ;;
  detener)
    existe "$ID" && aws ec2 stop-instances --instance-ids "$ID" >/dev/null
    if [ "$ESTADO_RDS" = "available" ]; then
      aws rds stop-db-instance --db-instance-identifier "$RDS_ID" >/dev/null
    fi
    ;;
  estado) ;;
  *) falla "Uso: $0 iniciar|detener|estado" ;;
esac

EC2_ESTADO="None"
if existe "$ID"; then
  EC2_ESTADO="$(aws ec2 describe-instances --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)"
fi
printf '\nEC2: %s\nRDS: %s\n' "$EC2_ESTADO" "$(rds_estado)"
