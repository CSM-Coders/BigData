#!/usr/bin/env bash
# crea la contraseña de la bd y los grupos de seguridad
# se puede repetir, si cambia la ip actualiza la regla de ssh
source "$(dirname "$0")/comun.sh"

crear_sg() {
  local nombre="$1" descripcion="$2" id
  id="$(sg_id "$nombre")"
  if ! existe "$id"; then
    id="$(aws ec2 create-security-group --group-name "$nombre" \
      --description "$descripcion" --vpc-id "$VPC" \
      --tag-specifications "$(etiquetas security-group "$nombre")" \
      --query GroupId --output text)"
  fi
  printf '%s' "$id"
}

verificar_sesion

if [ ! -f "$ARCHIVO_ENV" ]; then
  info "Generando la contraseña de la base de datos en .env"
  (umask 077; printf 'DB_PASSWORD=%s\n' "$(openssl rand -hex 16)" >"$ARCHIVO_ENV")
fi

VPC="$(vpc_id)"
existe "$VPC" || falla "La cuenta no tiene VPC por defecto."

info "Creando grupos de seguridad"
ID_EC2="$(crear_sg "$SG_EC2" "SSH hacia la EC2 de fuentes")"
ID_RDS="$(crear_sg "$SG_RDS" "MariaDB solo desde la EC2 de fuentes")"

MI_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
info "Permitiendo SSH solo desde $MI_IP"
ACTUALES="$(aws ec2 describe-security-groups --group-ids "$ID_EC2" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text)"
for cidr in $ACTUALES; do
  if [ "$cidr" != "$MI_IP" ]; then
    aws ec2 revoke-security-group-ingress --group-id "$ID_EC2" \
      --protocol tcp --port 22 --cidr "$cidr" >/dev/null
  fi
done
case " $ACTUALES " in
  *" $MI_IP "*) ;;
  *) aws ec2 authorize-security-group-ingress --group-id "$ID_EC2" \
      --protocol tcp --port 22 --cidr "$MI_IP" >/dev/null ;;
esac

info "Permitiendo MariaDB solo desde la EC2"
REGLA_RDS="$(aws ec2 describe-security-groups --group-ids "$ID_RDS" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`3306\`].UserIdGroupPairs[] | [?GroupId=='$ID_EC2'] | [0].GroupId" \
  --output text)"
if ! existe "$REGLA_RDS"; then
  aws ec2 authorize-security-group-ingress --group-id "$ID_RDS" \
    --protocol tcp --port 3306 --source-group "$ID_EC2" >/dev/null
fi

printf '\nListo. EC2: %s  RDS: %s\n' "$ID_EC2" "$ID_RDS"
