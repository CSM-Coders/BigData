#!/usr/bin/env bash
# copia la app de streamlit a la ec2 del punto 2 y la deja corriendo como servicio
source "$(dirname "$0")/comun.sh"

verificar_sesion
api_existente
ip_ec2_encendida
[ -f "$LLAVE_SSH" ] || falla "No existe la llave $LLAVE_SSH. Descárgala desde AWS Details en el lab."

info "Abriendo SSH y el puerto $PUERTO_APP de la EC2 solo para tu IP"
permitir_puerto 22
permitir_puerto "$PUERTO_APP"

info "Copiando la app a la EC2 $IP_EC2"
ssh_ec2 "rm -rf /tmp/dengue-app && mkdir -p /tmp/dengue-app"
scp_ec2 /tmp/dengue-app/ "$DIR_VISUALIZACION/app/app.py" "$DIR_VISUALIZACION/app/requirements.txt" \
  "$DIR_VISUALIZACION/app/instalar_app.sh"

info "Instalando Streamlit y el servicio dengue-app"
ssh_ec2 "sudo bash /tmp/dengue-app/instalar_app.sh '$API_URL'"

URL_APP="http://$IP_EC2:$PUERTO_APP"
info "Revisando la app desde tu equipo"
for _ in $(seq 1 10); do
  if [ "$(curl -fsS "$URL_APP/_stcore/health" 2>/dev/null)" = "ok" ]; then
    echo
    echo "OK: la app está en $URL_APP y lee los datos de $API_URL"
    exit 0
  fi
  sleep 3
done
falla "La app no responde en $URL_APP. Revisa con: ./punto2-fuentes-datos/conectar_ec2.sh y journalctl -u dengue-app"
