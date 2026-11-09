#!/usr/bin/env bash
# crea la ec2 donde quedan los archivos fuente
source "$(dirname "$0")/comun.sh"

verificar_sesion

if existe "$(ec2_id)"; then
  info "La instancia $EC2_NOMBRE ya existe: $(ec2_id)"
else
  ID_EC2="$(sg_id "$SG_EC2")"
  existe "$ID_EC2" || falla "No existe $SG_EC2. Ejecuta primero 01_crear_red.sh."

  AMI="$(aws ec2 describe-images --owners amazon \
    --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' Name=state,Values=available \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
  SUBRED="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$(vpc_id)" \
    "Name=availability-zone,Values=${AWS_DEFAULT_REGION}a" \
    --query 'Subnets[0].SubnetId' --output text)"

  info "Creando $EC2_NOMBRE con $AMI en $SUBRED"
  aws ec2 run-instances \
    --image-id "$AMI" --instance-type "$EC2_TIPO" --key-name "$EC2_LLAVE" \
    --subnet-id "$SUBRED" --security-group-ids "$ID_EC2" \
    --iam-instance-profile "Name=$EC2_PERFIL" \
    --user-data "file://$AQUI/instalar_ec2.sh" \
    --tag-specifications "$(etiquetas instance "$EC2_NOMBRE")" >/dev/null
fi

info "Esperando a que la instancia esté lista"
aws ec2 wait instance-running --instance-ids "$(ec2_id)"
aws ec2 wait instance-status-ok --instance-ids "$(ec2_id)"
printf '\nListo. IP pública: %s\n' "$(ec2_ip)"
