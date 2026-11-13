#!/usr/bin/env bash
# muestra qué hay en la zona raw y cómo va open-meteo, solo lee
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets
RAW="s3://$BUCKET_DATALAKE/raw"

contar_json() {
  aws s3 ls "$1/" 2>/dev/null | grep -c '\.json$' || true
}

info "Zona raw por fuente"
for fuente in sivigila poblacion divipola; do
  echo "$fuente:"
  aws s3 ls "$RAW/$fuente/" --recursive --human-readable | sed 's/^/  /' || echo "  sin datos"
done

info "Open-Meteo"
ALTITUD="$(contar_json "$RAW/openmeteo/altitud")"
CLIMA="$(contar_json "$RAW/openmeteo/clima")"
ESPERADO_ALTITUD=$(( $(wc -l < "$RESULTADOS_PUNTO1/municipios_altitud.csv") - 1 ))
ESPERADO_CLIMA=$(( $(wc -l < "$RESULTADOS_PUNTO1/municipios_clima_top300.csv") - 1 ))
printf 'altitud: %s de %s municipios\n' "$ALTITUD" "$ESPERADO_ALTITUD"
printf 'clima:   %s de %s municipios\n' "$CLIMA" "$ESPERADO_CLIMA"

info "Total en raw"
aws s3 ls "$RAW/" --recursive --summarize --human-readable | tail -n 2

# el log solo se puede leer si la ec2 está encendida
IP_EC2="$(ec2_ip)"
if existe "$IP_EC2"; then
  info "Últimas líneas del log de la EC2"
  ssh_ec2 'tail -n 8 ~/ingesta/logs/ingesta.log 2>/dev/null || echo "Todavía no hay log"'
fi

if [ "$ALTITUD" -eq "$ESPERADO_ALTITUD" ] && [ "$CLIMA" -eq "$ESPERADO_CLIMA" ]; then
  echo
  echo "OK: la zona raw está completa."
fi
