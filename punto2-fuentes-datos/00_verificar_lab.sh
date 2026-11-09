#!/usr/bin/env bash
# revisa que el lab tenga todo, solo lee
source "$(dirname "$0")/comun.sh"

revisar() {
  local nombre="$1"
  shift
  local salida
  if salida="$("$@" 2>&1)" && existe "$salida"; then
    printf 'OK     %-24s %s\n' "$nombre" "$salida"
  else
    printf 'FALTA  %-24s %s\n' "$nombre" "$(printf '%s' "$salida" | tail -1 | cut -c1-90)"
  fi
}

verificar_sesion
VPC="$(vpc_id)"

info "Cuenta y red"
revisar "Identidad" aws sts get-caller-identity --query 'Arn' --output text
revisar "VPC por defecto" echo "$VPC"
revisar "Subredes" aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query 'length(Subnets)' --output text

info "EC2"
revisar "Llave $EC2_LLAVE" aws ec2 describe-key-pairs --key-names "$EC2_LLAVE" \
  --query 'KeyPairs[0].KeyName' --output text
revisar "Perfil $EC2_PERFIL" aws iam get-instance-profile \
  --instance-profile-name "$EC2_PERFIL" --query 'InstanceProfile.InstanceProfileName' --output text
revisar "AMI Amazon Linux 2023" aws ec2 describe-images --owners amazon \
  --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' Name=state,Values=available \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text

info "RDS"
revisar "MariaDB $RDS_VERSION_BASE" aws rds describe-db-engine-versions --engine mariadb \
  --query "DBEngineVersions[?starts_with(EngineVersion,'$RDS_VERSION_BASE')].EngineVersion | [-1]" \
  --output text
revisar "Clase $RDS_CLASE" aws rds describe-orderable-db-instance-options --engine mariadb \
  --db-instance-class "$RDS_CLASE" --no-paginate \
  --query 'OrderableDBInstanceOptions[0].DBInstanceClass' --output text

info "Archivos locales"
revisar "Llave SSH" ls "$LLAVE_SSH"
revisar "SIVIGILA del punto 1" ls "$DATOS_PUNTO1/sivigila_dengue.csv"
revisar "Población del punto 1" ls "$DATOS_PUNTO1/PPED-AreaMun-2018-2042_VP.xlsx"
