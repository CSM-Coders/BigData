#!/usr/bin/env bash
# corre la ingesta ya, sin esperar al cron
# rds y archivos terminan aquí, open-meteo sigue en segundo plano en la ec2
source "$(dirname "$0")/comun.sh"

verificar_sesion
ip_ec2_encendida
ssh_ec2 'test -x ~/ingesta/ingestar.sh' || falla "Falta instalar la ingesta. Ejecuta 01_instalar_ingesta.sh."
[ "$(rds_estado)" = "available" ] || falla "RDS no está disponible. Enciéndela con encender_apagar.sh iniciar."

info "Ingestando RDS y archivos de la EC2"
ssh_ec2 '~/ingesta/ingestar.sh rds && ~/ingesta/ingestar.sh archivos' ||
  falla "La ingesta de RDS o de archivos falló."

info "Iniciando Open-Meteo en segundo plano"
ssh_ec2 'nohup ~/ingesta/ingestar.sh api >> ~/ingesta/logs/ingesta.log 2>&1 < /dev/null &'
sleep 20
ssh_ec2 'tail -n 5 ~/ingesta/logs/ingesta.log'

echo
echo "Open-Meteo puede tardar entre minutos y horas por los límites de la API."
echo "Revisa el avance con ./punto3-ingesta/03_ver_datalake.sh"
