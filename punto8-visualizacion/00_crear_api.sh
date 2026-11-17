#!/usr/bin/env bash
# crea o actualiza la lambda y la api http de api gateway que la expone
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
CUENTA="$(aws sts get-caller-identity --query Account --output text)"
for tabla in $TABLAS_PUNTO6 $TABLAS_PYSPARK; do
  aws glue get-table --database-name "$BD_REFINED" --name "$tabla" >/dev/null 2>&1 ||
    falla "No existe $BD_REFINED.$tabla. Ejecuta primero los puntos 6 y 7."
done
ROL_ARN="$(aws iam get-role --role-name "$LAMBDA_ROL" --query Role.Arn --output text 2>/dev/null)" ||
  falla "No existe el rol $LAMBDA_ROL del lab."
ENTORNO="Variables={BASE=$BD_REFINED,SALIDA=s3://$BUCKET_ARTEFACTOS/athena-api/,GRUPO=primary}"
ZIP="$(mktemp -d)/lambda.zip"
trap 'rm -rf "$(dirname "$ZIP")"' EXIT
(cd "$DIR_VISUALIZACION/api" && zip -q "$ZIP" lambda_function.py)

if aws lambda get-function --function-name "$LAMBDA" >/dev/null 2>&1; then
  info "Actualizando la Lambda $LAMBDA"
  aws lambda update-function-code --function-name "$LAMBDA" --zip-file "fileb://$ZIP" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$LAMBDA"
  aws lambda update-function-configuration --function-name "$LAMBDA" --environment "$ENTORNO" >/dev/null
else
  info "Creando la Lambda $LAMBDA con el rol $LAMBDA_ROL"
  aws lambda create-function --function-name "$LAMBDA" --runtime "$LAMBDA_RUNTIME" \
    --role "$ROL_ARN" --handler lambda_function.handler --zip-file "fileb://$ZIP" \
    --timeout 29 --memory-size 256 --environment "$ENTORNO" \
    --description "api de solo lectura sobre dengue_refined" \
    --tags "Proyecto=$PROYECTO" >/dev/null
  aws lambda wait function-active-v2 --function-name "$LAMBDA"
fi
aws lambda wait function-updated-v2 --function-name "$LAMBDA"
LAMBDA_ARN="$(aws lambda get-function --function-name "$LAMBDA" --query Configuration.FunctionArn --output text)"
echo "$LAMBDA_ARN"

API_ID="$(aws apigatewayv2 get-apis --output text --query "Items[?Name=='$API_NOMBRE'] | [0].ApiId")"
if existe "$API_ID"; then
  info "La API $API_NOMBRE ya existe: $API_ID"
else
  # la creación rápida deja la ruta $default y la etapa $default con despliegue automático
  info "Creando la API HTTP $API_NOMBRE en API Gateway"
  API_ID="$(aws apigatewayv2 create-api --name "$API_NOMBRE" --protocol-type HTTP \
    --target "$LAMBDA_ARN" --description "dengue en colombia, datos de dengue_refined" \
    --cors-configuration 'AllowOrigins=*,AllowMethods=GET' --tags "Proyecto=$PROYECTO" \
    --query ApiId --output text)"
  echo "$API_ID"
fi

FUENTE="arn:aws:execute-api:$AWS_DEFAULT_REGION:$CUENTA:$API_ID/*"
if aws lambda get-policy --function-name "$LAMBDA" --query Policy --output text 2>/dev/null | grep -q "$API_ID"; then
  echo "API Gateway ya puede invocar la Lambda"
else
  aws lambda add-permission --function-name "$LAMBDA" --statement-id "apigateway-$API_ID" \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "$FUENTE" >/dev/null
  echo "Permiso para que API Gateway invoque la Lambda"
fi

info "API lista"
aws apigatewayv2 get-api --api-id "$API_ID" --output table \
  --query '{Nombre:Name, Id:ApiId, Protocolo:ProtocolType, Url:ApiEndpoint}'
API_URL="$(api_url)"

info "Primera consulta: GET $API_URL/tablas/incidencia_departamento?ano=2024&limite=3"
for _ in 1 2 3 4 5; do
  # la primera llamada puede fallar mientras se propaga el permiso
  if RESPUESTA="$(curl -fsS "$API_URL/tablas/incidencia_departamento?ano=2024&limite=3")"; then
    echo "$RESPUESTA" | python3 -m json.tool --no-ensure-ascii
    echo
    echo "OK: la API responde en $API_URL"
    exit 0
  fi
  sleep 5
done
falla "La API no respondió. Revisa los logs de la Lambda en CloudWatch."
