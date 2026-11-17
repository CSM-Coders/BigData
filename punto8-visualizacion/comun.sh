#!/usr/bin/env bash
# variables de la api y la app, reusa las del punto 7
DIR_VISUALIZACION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR_VISUALIZACION/../punto7-pyspark/comun.sh"

LAMBDA="dengue-api"
LAMBDA_ROL="LabRole"
LAMBDA_RUNTIME="python3.12"
API_NOMBRE="dengue-api"
PUERTO_APP=8501
DIR_GRAFICAS="$DIR_VISUALIZACION/graficas"

# url pública de la api, vacía si no existe
api_url() {
  aws apigatewayv2 get-apis --output text \
    --query "Items[?Name=='$API_NOMBRE'] | [0].ApiEndpoint"
}

api_existente() {
  # la url se puede pasar a mano en API_URL, por ejemplo para probar contra otra api
  [ -n "${API_URL:-}" ] && return 0
  API_URL="$(api_url)"
  existe "$API_URL" || falla "No existe la API $API_NOMBRE. Créala con 00_crear_api.sh."
}

# abre un puerto del grupo de la ec2 solo para tu ip, si no estaba abierto
permitir_puerto() {
  local puerto="$1" sg actuales
  sg="$(sg_id "$SG_EC2")"
  MI_IP="${MI_IP:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
  actuales="$(aws ec2 describe-security-groups --group-ids "$sg" --output text \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`$puerto\`].IpRanges[].CidrIp")"
  case " $actuales " in
    *" $MI_IP "*) echo "El puerto $puerto ya está abierto para $MI_IP" ;;
    *)
      aws ec2 authorize-security-group-ingress --group-id "$sg" \
        --protocol tcp --port "$puerto" --cidr "$MI_IP" >/dev/null
      echo "Puerto $puerto abierto para $MI_IP" ;;
  esac
}
