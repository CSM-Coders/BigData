#!/usr/bin/env bash
# copia los archivos a la ec2 y desde ahí carga sivigila en rds
source "$(dirname "$0")/comun.sh"

URL_DIVIPOLA="https://www.datos.gov.co/resource/gdxc-w37w.csv"
SIVIGILA="$DATOS_PUNTO1/sivigila_dengue.csv"
POBLACION="$DATOS_PUNTO1/PPED-AreaMun-2018-2042_VP.xlsx"
ENCABEZADO="cod_eve,nombre_evento,semana,ano,cod_dpto_o,cod_mun_o,departamento_ocurrencia,municipio_ocurrencia,conteo,cod_mpio"

verificar_sesion
cargar_env

[ -f "$SIVIGILA" ] && [ -f "$POBLACION" ] ||
  falla "Faltan los datos del punto 1. Ejecuta explorar_fuentes.py."
[ -f "$LLAVE_SSH" ] || falla "No existe la llave $LLAVE_SSH."
[ "$(head -1 "$SIVIGILA" | tr -d '\r')" = "$ENCABEZADO" ] ||
  falla "Las columnas de sivigila_dengue.csv no son las esperadas."

IP_EC2="$(ec2_ip)"
existe "$IP_EC2" || falla "La EC2 no tiene IP pública. Revisa que esté encendida."
HOST_RDS="$(rds_host)"
existe "$HOST_RDS" || falla "RDS no tiene endpoint. Revisa que esté disponible."

# se baja otra vez porque el punto 1 ya corrigió las coordenadas
# y aquí se necesita la coma decimal original
info "Descargando DIVIPOLA sin modificar"
mkdir -p "$AQUI/datos"
curl -fsS -G "$URL_DIVIPOLA" --data-urlencode '$limit=2000' -o "$AQUI/datos/divipola.csv"

info "Esperando la instalación inicial de la EC2"
ssh_ec2 'cloud-init status --wait >/dev/null; command -v mariadb >/dev/null'

info "Copiando archivos a la EC2"
ssh_ec2 'mkdir -p ~/fuentes/poblacion ~/fuentes/divipola ~/carga'
scp_ec2 fuentes/poblacion/ "$POBLACION"
scp_ec2 fuentes/divipola/ "$AQUI/datos/divipola.csv"
scp_ec2 carga/ "$SIVIGILA" "$AQUI"/sql/*.sql

info "Configurando el acceso a RDS en la EC2"
ssh_ec2 'umask 077; cat > ~/.my.cnf' <<CONFIG
[client]
host=$HOST_RDS
user=$DB_USUARIO
password=$DB_PASSWORD
CONFIG

info "Cargando SIVIGILA en RDS"
ssh_ec2 'cd ~/carga && mariadb < esquema.sql && mariadb --local-infile=1 < cargar_sivigila.sql'

info "Resumen de la tabla en RDS"
ssh_ec2 'cd ~/carga && mariadb --table < verificar.sql'

info "Comparando con los valores de control del punto 1"
RESULTADO="$(ssh_ec2 'mariadb -N -B -e "SELECT COUNT(*), SUM(IF(cod_eve IN (210,220),conteo,0)), SUM(IF(cod_eve=580,conteo,0)) FROM sivigila.eventos_dengue"')"
python3 - "$CONTROL" "$RESULTADO" <<'PY'
import json
import sys

control = json.load(open(sys.argv[1], encoding="utf-8"))
filas, casos, muertes = (int(valor) for valor in sys.argv[2].split())
esperado = (control["filas_sivigila_dengue"], control["total_casos"], control["total_muertes"])
obtenido = (filas, casos, muertes)
print(f"Esperado (filas, casos, muertes): {esperado}")
print(f"En RDS   (filas, casos, muertes): {obtenido}")
if esperado != obtenido:
    sys.exit("ERROR: RDS no coincide con los valores de control.")
print("OK: RDS coincide con los valores de control.")
PY

info "Archivos en la EC2"
ssh_ec2 'ls -lh ~/fuentes/poblacion ~/fuentes/divipola'
