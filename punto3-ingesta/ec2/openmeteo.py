#!/usr/bin/env python3
# baja altitud y clima de open-meteo y los deja en raw tal como llegan
# si se acaba el cupo por hora o por día para, y la próxima corrida sigue donde iba
import argparse
import csv
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

AQUI = Path(__file__).resolve().parent
URL_ALTITUD = "https://api.open-meteo.com/v1/elevation"
URL_CLIMA = "https://archive-api.open-meteo.com/v1/archive"
PARAMS_CLIMA = {
    "start_date": "2021-11-01",
    "end_date": "2024-12-31",
    "daily": "temperature_2m_mean,precipitation_sum,relative_humidity_2m_mean",
    "timezone": "America/Bogota",
}
CABECERAS = {"User-Agent": "proyecto-academico-bigdata/1.0"}
ESPERA_MINUTO_S = 65
MAX_INTENTOS = 5
SUBIR_CADA = 25


class CupoAgotado(Exception):
    pass


def pedir(url, params):
    consulta = url + "?" + urllib.parse.urlencode(params)
    for _ in range(MAX_INTENTOS):
        try:
            peticion = urllib.request.Request(consulta, headers=CABECERAS)
            with urllib.request.urlopen(peticion, timeout=90) as respuesta:
                return respuesta.read()
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            razon = error.read().decode("utf-8", "replace")
            # el límite por minuto se espera, el de hora y día no
            if "hourly" in razon.lower() or "daily" in razon.lower():
                raise CupoAgotado(razon)
            print(f"  Límite por minuto, esperando {ESPERA_MINUTO_S} s", flush=True)
            time.sleep(ESPERA_MINUTO_S)
        except OSError as error:
            print(f"  Error de red ({error}), reintento en 15 s", flush=True)
            time.sleep(15)
    raise RuntimeError(f"Open-Meteo no respondió tras {MAX_INTENTOS} intentos")


def en_s3(destino):
    resultado = subprocess.run(
        ["aws", "s3", "ls", destino + "/"], capture_output=True, text=True
    )
    # aws s3 ls sale con 1 cuando la carpeta está vacía
    return {
        linea.split()[-1]
        for linea in resultado.stdout.splitlines()
        if linea.strip().endswith(".json")
    }


def subir(carpeta, destino):
    subprocess.run(
        ["aws", "s3", "sync", "--only-show-errors", str(carpeta), destino + "/"],
        check=True,
    )


def leer_municipios(nombre):
    with open(AQUI / nombre, encoding="utf-8") as archivo:
        return list(csv.DictReader(archivo))


def bajar(nombre, municipios, url, params_extra, carpeta, destino, pausa_s):
    carpeta.mkdir(parents=True, exist_ok=True)
    hechos = en_s3(destino)
    pendientes = [m for m in municipios if m["cod_mpio"] + ".json" not in hechos]
    print(f"{nombre}: {len(hechos)} en S3, {len(pendientes)} pendientes", flush=True)

    nuevos = 0
    try:
        for municipio in pendientes:
            archivo = carpeta / (municipio["cod_mpio"] + ".json")
            if not archivo.exists():
                params = {"latitude": municipio["latitud"], "longitude": municipio["longitud"]}
                params.update(params_extra)
                datos = pedir(url, params)
                json.loads(datos)
                archivo.write_bytes(datos)
                time.sleep(pausa_s)
            nuevos += 1
            if nuevos % SUBIR_CADA == 0:
                subir(carpeta, destino)
                print(f"  {nombre}: {nuevos} de {len(pendientes)}", flush=True)
    except CupoAgotado as error:
        subir(carpeta, destino)
        print(f"{nombre}: se acabó el cupo de Open-Meteo, faltan {len(pendientes) - nuevos}.")
        print(f"  Respuesta: {str(error)[:120]}")
        print("  La próxima corrida sigue desde aquí.", flush=True)
        return False

    subir(carpeta, destino)
    print(f"{nombre}: completo, {len(hechos) + nuevos} municipios en {destino}/", flush=True)
    return True


def main():
    parser = argparse.ArgumentParser(description="ingesta de open-meteo a raw")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--carpeta", required=True, help="caché local de respuestas")
    args = parser.parse_args()
    raw = f"s3://{args.bucket}/raw/openmeteo"
    carpeta = Path(args.carpeta)

    completo = bajar(
        "Altitud",
        leer_municipios("municipios_altitud.csv"),
        URL_ALTITUD,
        {},
        carpeta / "altitud",
        raw + "/altitud",
        0.15,
    )
    if completo:
        bajar(
            "Clima",
            leer_municipios("municipios_clima_top300.csv"),
            URL_CLIMA,
            PARAMS_CLIMA,
            carpeta / "clima",
            raw + "/clima",
            1.0,
        )


if __name__ == "__main__":
    sys.exit(main())
