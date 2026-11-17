#!/usr/bin/env bash
# prueba las rutas de la api con curl, también las que deben dar error, solo lee en aws
source "$(dirname "$0")/comun.sh"

verificar_sesion
api_existente
FALLAS=0

# pide una ruta, muestra las primeras filas y revisa el código http
pedir() {
  local ruta="$1" esperado="$2" filas="${3:-5}" salida codigo tiempo
  info "GET $ruta"
  salida="$(curl -sS -w '\n%{http_code} %{time_total}' "$API_URL$ruta")"
  read -r codigo tiempo <<< "$(tail -n 1 <<< "$salida")"
  sed '$d' <<< "$salida" | python3 "$DIR_VISUALIZACION/api/mostrar_respuesta.py" "$filas"
  if [ "$codigo" = "$esperado" ]; then
    printf 'OK     HTTP %s en %s s\n' "$codigo" "$tiempo"
  else
    printf 'FALLA  HTTP %s, se esperaba %s\n' "$codigo" "$esperado"
    FALLAS=$((FALLAS + 1))
  fi
}

echo "API: $API_URL"
pedir "/" 200
pedir "/tablas/incidencia_departamento?ano=2024&limite=5" 200
pedir "/tablas/municipio_anual?cod_mpio=76001" 200 3
pedir "/tablas/clima_rezago" 200
pedir "/tablas/estadisticas_incidencia" 200
pedir "/tablas/brote_2024_departamento?cod_dpto=76" 200
pedir "/tablas/incidencia_departamento?ano=2024&limite=5" 200 1
pedir "/tablas/no_existe" 404
pedir "/tablas/incidencia_departamento?ano=dos" 400
pedir "/tablas/clima_rezago?ano=2024" 400

echo
[ "$FALLAS" -eq 0 ] || falla "$FALLAS rutas no respondieron lo esperado."
echo "OK: la API responde las 10 tablas de dengue_refined y rechaza las rutas y filtros inválidos."
