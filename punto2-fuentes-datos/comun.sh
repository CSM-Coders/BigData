#!/usr/bin/env bash
# variables y funciones que usan los demás scripts
set -euo pipefail

export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$AQUI")"
ARCHIVO_ENV="$AQUI/.env"
DATOS_PUNTO1="$RAIZ/punto1-caso-estudio/datos"
CONTROL="$RAIZ/punto1-caso-estudio/resultados/valores_control.json"

PROYECTO="dengue-bigdata"
SG_EC2="dengue-ec2-sg"
SG_RDS="dengue-rds-sg"

RDS_ID="dengue-mariadb"
RDS_SUBNETS="dengue-rds-subnets"
RDS_CLASE="db.t3.micro"
RDS_VERSION_BASE="10.11"
RDS_DISCO_GB=20
DB_USUARIO="admin"

EC2_NOMBRE="dengue-fuentes"
EC2_TIPO="t3.micro"
EC2_LLAVE="vockey"
EC2_PERFIL="LabInstanceProfile"
LLAVE_SSH="${LLAVE_SSH:-$HOME/.ssh/labsuser.pem}"
HOSTS_SSH="$HOME/.ssh/known_hosts_dengue"

info() { printf '\n> %s\n' "$*"; }
falla() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# la cli devuelve None si no encuentra nada
existe() { [ -n "${1:-}" ] && [ "$1" != "None" ]; }

verificar_sesion() {
  aws sts get-caller-identity >/dev/null 2>&1 ||
    falla "Credenciales de AWS inválidas. Inicia el lab y actualiza ~/.aws/credentials."
}

cargar_env() {
  [ -f "$ARCHIVO_ENV" ] || falla "No existe $ARCHIVO_ENV. Ejecuta primero 01_crear_red.sh."
  . "$ARCHIVO_ENV"
}

vpc_id() {
  aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text
}

sg_id() {
  aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text
}

ec2_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$EC2_NOMBRE" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

ec2_ip() {
  aws ec2 describe-instances --instance-ids "$(ec2_id)" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

rds_estado() {
  aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo None
}

rds_host() {
  aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
    --query 'DBInstances[0].Endpoint.Address' --output text
}

opciones_ssh() {
  printf '%s\n' -i "$LLAVE_SSH" -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$HOSTS_SSH" -o ConnectTimeout=15
}

ssh_ec2() {
  local opciones=()
  while IFS= read -r linea; do opciones+=("$linea"); done < <(opciones_ssh)
  ssh "${opciones[@]}" "ec2-user@$IP_EC2" "$@"
}

scp_ec2() {
  local destino="$1"
  shift
  local opciones=()
  while IFS= read -r linea; do opciones+=("$linea"); done < <(opciones_ssh)
  scp -q "${opciones[@]}" "$@" "ec2-user@$IP_EC2:$destino"
}

etiquetas() {
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Proyecto,Value=%s}]' \
    "$1" "$2" "$PROYECTO"
}
