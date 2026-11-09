#!/usr/bin/env bash
# crea la rds mariadb privada, tarda unos 10 min
source "$(dirname "$0")/comun.sh"

verificar_sesion
cargar_env

if existe "$(rds_estado)"; then
  info "La instancia $RDS_ID ya existe, estado: $(rds_estado)"
else
  VPC="$(vpc_id)"
  ID_RDS="$(sg_id "$SG_RDS")"
  existe "$ID_RDS" || falla "No existe $SG_RDS. Ejecuta primero 01_crear_red.sh."

  if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$RDS_SUBNETS" >/dev/null 2>&1; then
    info "Creando el grupo de subredes"
    aws rds create-db-subnet-group --db-subnet-group-name "$RDS_SUBNETS" \
      --db-subnet-group-description "Subredes para la base de datos del proyecto" \
      --subnet-ids $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
        --query 'Subnets[].SubnetId' --output text) >/dev/null
  fi

  VERSION="$(aws rds describe-db-engine-versions --engine mariadb \
    --query "DBEngineVersions[?starts_with(EngineVersion,'$RDS_VERSION_BASE')].EngineVersion | [-1]" \
    --output text)"
  existe "$VERSION" || falla "No hay versión $RDS_VERSION_BASE de MariaDB disponible."

  info "Creando $RDS_ID con MariaDB $VERSION en $RDS_CLASE"
  aws rds create-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --engine mariadb --engine-version "$VERSION" \
    --db-instance-class "$RDS_CLASE" \
    --allocated-storage "$RDS_DISCO_GB" --storage-type gp2 \
    --master-username "$DB_USUARIO" --master-user-password "$DB_PASSWORD" \
    --vpc-security-group-ids "$ID_RDS" \
    --db-subnet-group-name "$RDS_SUBNETS" \
    --no-publicly-accessible --no-multi-az \
    --backup-retention-period 0 \
    --tags "Key=Proyecto,Value=$PROYECTO" >/dev/null
fi

info "Esperando a que quede disponible"
aws rds wait db-instance-available --db-instance-identifier "$RDS_ID"
printf '\nListo. Endpoint: %s\n' "$(rds_host)"
