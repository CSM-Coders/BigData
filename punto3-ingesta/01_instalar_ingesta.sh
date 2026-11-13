#!/usr/bin/env bash
# instala la ingesta en la ec2 y la programa con cron
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
aws s3api head-bucket --bucket "$BUCKET_DATALAKE" >/dev/null 2>&1 ||
  falla "No existe s3://$BUCKET_DATALAKE. Ejecuta primero 00_crear_buckets.sh."
ip_ec2_encendida

info "Instalando cron en la EC2"
ssh_ec2 'sudo dnf install -y -q cronie >/dev/null && sudo systemctl enable --now crond >/dev/null 2>&1'
ssh_ec2 'systemctl is-active crond'

info "Copiando la ingesta a la EC2"
ssh_ec2 'mkdir -p ~/ingesta/logs'
scp_ec2 ingesta/ "$DIR_INGESTA/ec2/ingestar.sh" "$DIR_INGESTA/ec2/openmeteo.py" \
  "$RESULTADOS_PUNTO1/municipios_altitud.csv" "$RESULTADOS_PUNTO1/municipios_clima_top300.csv"
ssh_ec2 "chmod +x ~/ingesta/ingestar.sh && printf 'BUCKET=%s\n' '$BUCKET_DATALAKE' > ~/ingesta/config.env"

# la ec2 escribe en s3 con el rol del lab, sin llaves guardadas
info "Probando el acceso de la EC2 al bucket"
ssh_ec2 "aws s3 ls s3://$BUCKET_DATALAKE/ >/dev/null && echo 'OK: la EC2 puede usar el datalake'" ||
  falla "La EC2 no tiene acceso a s3://$BUCKET_DATALAKE. Revisa el perfil LabInstanceProfile."

info "Programando la ingesta"
ssh_ec2 'crontab -' < "$DIR_INGESTA/ec2/crontab.txt"
ssh_ec2 'crontab -l'
