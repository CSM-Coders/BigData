#!/usr/bin/env bash
# abre ssh en la ec2, la ip cambia cada vez que se reinicia
source "$(dirname "$0")/comun.sh"

verificar_sesion
IP_EC2="$(ec2_ip)"
existe "$IP_EC2" || falla "La EC2 no tiene IP pública. Revisa que esté encendida."
ssh_ec2
