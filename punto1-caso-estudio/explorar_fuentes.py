#!/usr/bin/env python3
# perfila las fuentes de dengue, población y clima, no usa aws
# uso: python punto1-caso-estudio/explorar_fuentes.py [--top 300]
import argparse
import json
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pandas as pd
import requests

AQUI = Path(__file__).resolve().parent
DATOS = AQUI / "datos"
RESULTADOS = AQUI / "resultados"

URL_SIVIGILA = "https://www.datos.gov.co/resource/wns8-p38i.json"
URL_DIVIPOLA = "https://www.datos.gov.co/resource/gdxc-w37w.json"
URL_DANE = (
    "https://www.dane.gov.co/files/censo2018/proyecciones-de-poblacion/"
    "Municipal/PPED-AreaMun-2018-2042_VP.xlsx"
)
URL_ELEVACION = "https://api.open-meteo.com/v1/elevation"
URL_CLIMA = "https://archive-api.open-meteo.com/v1/archive"

EVENTO_DENGUE, EVENTO_GRAVE, EVENTO_MUERTE = 210, 220, 580
ANIOS = (2022, 2023, 2024)
TAM_PAGINA = 50_000
TAM_LOTE_ELEVACION = 100
CABECERAS = {"User-Agent": "proyecto-academico-bigdata/1.0"}
# open-meteo cuenta cada coordenada en su límite por minuto
ESPERA_LIMITE_S = 65
MAX_REINTENTOS = 5


def get_open_meteo(url: str, params: dict) -> dict:
    # si open-meteo responde 429 espera y reintenta
    for _ in range(MAX_REINTENTOS):
        respuesta = requests.get(url, params=params, headers=CABECERAS, timeout=60)
        if respuesta.status_code != 429:
            respuesta.raise_for_status()
            return respuesta.json()
        print(f"  Límite de Open-Meteo alcanzado, esperando {ESPERA_LIMITE_S} s...")
        time.sleep(ESPERA_LIMITE_S)
    raise RuntimeError(f"Open-Meteo siguió respondiendo 429 tras {MAX_REINTENTOS} intentos")


def inicio_semana_epi(anio: int, semana: int) -> date:
    # domingo en que empieza la semana, la semana 1 tiene al menos 4 días del año
    primero = date(anio, 1, 1)
    dias_desde_domingo = (primero.weekday() + 1) % 7
    domingo = primero - timedelta(days=dias_desde_domingo)
    if dias_desde_domingo > 3:
        domingo += timedelta(days=7)
    return domingo + timedelta(weeks=semana - 1)


def descargar_sivigila() -> pd.DataFrame:
    # baja los eventos paginando siempre en el mismo orden
    eventos = ",".join(f"'{e}'" for e in (EVENTO_DENGUE, EVENTO_GRAVE, EVENTO_MUERTE))
    filas, offset = [], 0
    while True:
        respuesta = requests.get(
            URL_SIVIGILA,
            params={
                "$where": f"cod_eve in({eventos})",
                "$order": ":id",
                "$limit": TAM_PAGINA,
                "$offset": offset,
            },
            headers=CABECERAS,
            timeout=120,
        )
        respuesta.raise_for_status()
        pagina = respuesta.json()
        filas.extend(pagina)
        if len(pagina) < TAM_PAGINA:
            break
        offset += TAM_PAGINA

    df = pd.DataFrame(filas)
    for columna in ("cod_eve", "semana", "ano", "conteo"):
        df[columna] = pd.to_numeric(df[columna]).astype(int)
    # el código llega sin el cero inicial
    df["cod_mpio"] = df["cod_mun_o"].astype(str).str.zfill(5)
    return df


def descargar_divipola() -> pd.DataFrame:
    respuesta = requests.get(
        URL_DIVIPOLA, params={"$limit": 2000}, headers=CABECERAS, timeout=60
    )
    respuesta.raise_for_status()
    df = pd.DataFrame(respuesta.json())
    # divipola usa coma decimal
    for columna in ("latitud", "longitud"):
        df[columna] = pd.to_numeric(df[columna].str.replace(",", ".", regex=False))
    return df


def descargar_poblacion() -> pd.DataFrame:
    # población total por municipio y año
    archivo = DATOS / "PPED-AreaMun-2018-2042_VP.xlsx"
    if not archivo.exists():
        respuesta = requests.get(URL_DANE, headers=CABECERAS, timeout=180)
        respuesta.raise_for_status()
        archivo.write_bytes(respuesta.content)

    df = pd.read_excel(
        archivo, sheet_name="PobMunicipalxÁrea", header=7, dtype={"DP": str, "MPIO": str}
    ).dropna(subset=["MPIO", "AÑO"])
    df = df[df["ÁREA GEOGRÁFICA"] == "Total"]
    return df.rename(
        columns={
            "DP": "cod_dpto",
            "DPNOM": "departamento",
            "MPIO": "cod_mpio",
            "DPMP": "municipio",
            "AÑO": "ano",
            "TOTAL": "poblacion",
        }
    )[["cod_dpto", "departamento", "cod_mpio", "municipio", "ano", "poblacion"]].astype(
        {"ano": int, "poblacion": int}
    )


def consultar_elevacion(municipios: pd.DataFrame) -> pd.Series:
    # altitud por lotes, se guarda en caché
    cache = DATOS / "elevacion.csv"
    if cache.exists():
        guardada = pd.read_csv(cache, dtype={"cod_mpio": str}).set_index("cod_mpio")
        return municipios["cod_mpio"].map(guardada["elevacion_m"]).rename("elevacion_m")

    elevaciones = []
    for inicio in range(0, len(municipios), TAM_LOTE_ELEVACION):
        lote = municipios.iloc[inicio : inicio + TAM_LOTE_ELEVACION]
        datos = get_open_meteo(
            URL_ELEVACION,
            {
                "latitude": ",".join(lote["latitud"].astype(str)),
                "longitude": ",".join(lote["longitud"].astype(str)),
            },
        )
        elevaciones.extend(datos["elevation"])
    serie = pd.Series(elevaciones, index=municipios.index, name="elevacion_m")
    municipios[["cod_mpio"]].assign(elevacion_m=serie).to_csv(cache, index=False)
    return serie


def probar_clima(municipio: pd.Series) -> dict:
    # pide todo el rango de clima de un municipio y lo resume
    diario = get_open_meteo(
        URL_CLIMA,
        {
            "latitude": municipio["latitud"],
            "longitude": municipio["longitud"],
            "start_date": "2021-11-01",
            "end_date": "2024-12-31",
            "daily": "temperature_2m_mean,precipitation_sum,relative_humidity_2m_mean",
            "timezone": "America/Bogota",
        },
    )["daily"]
    return {
        "municipio": municipio["nom_mpio"],
        "dias": len(diario["time"]),
        "nulos_temperatura": sum(v is None for v in diario["temperature_2m_mean"]),
        "nulos_lluvia": sum(v is None for v in diario["precipitation_sum"]),
    }


def tabla_md(df: pd.DataFrame) -> str:
    encabezado = "| " + " | ".join(map(str, df.columns)) + " |"
    separador = "|" + "---|" * len(df.columns)
    filas = ["| " + " | ".join(map(str, fila)) + " |" for fila in df.itertuples(index=False)]
    return "\n".join([encabezado, separador, *filas])


def main() -> None:
    parser = argparse.ArgumentParser(description="perfila las fuentes del caso de estudio")
    parser.add_argument(
        "--top", type=int, default=300, help="municipios con más casos para el clima"
    )
    args = parser.parse_args()
    DATOS.mkdir(exist_ok=True)
    RESULTADOS.mkdir(exist_ok=True)

    print("Descargando SIVIGILA...")
    sivigila = descargar_sivigila()
    print("Descargando DIVIPOLA...")
    divipola = descargar_divipola()
    print("Descargando población del DANE...")
    poblacion = descargar_poblacion()

    sivigila.to_csv(DATOS / "sivigila_dengue.csv", index=False)
    divipola.to_csv(DATOS / "divipola.csv", index=False)

    # casos son 210 y 220, las muertes (580) van aparte para no contar doble
    casos = sivigila[sivigila["cod_eve"].isin((EVENTO_DENGUE, EVENTO_GRAVE))]

    por_anio = (
        sivigila.pivot_table(
            index="ano", columns="cod_eve", values="conteo", aggfunc="sum", fill_value=0
        )
        .rename(
            columns={
                EVENTO_DENGUE: "dengue",
                EVENTO_GRAVE: "dengue_grave",
                EVENTO_MUERTE: "mortalidad",
            }
        )
        .reset_index()
    )
    por_anio["casos"] = por_anio["dengue"] + por_anio["dengue_grave"]

    # cruce de códigos
    en_dane = set(poblacion["cod_mpio"])
    en_divipola = set(divipola["cod_mpio"])
    casos_mpio = casos.groupby("cod_mpio", as_index=False)["conteo"].sum()
    total_casos = int(casos_mpio["conteo"].sum())
    sin_cruce = (
        casos[~casos["cod_mpio"].isin(en_dane)]
        .groupby(["cod_mpio", "departamento_ocurrencia", "municipio_ocurrencia"], as_index=False)[
            "conteo"
        ]
        .sum()
        .sort_values("conteo", ascending=False)
    )
    casos_sin_cruce = int(sin_cruce["conteo"].sum())

    # incidencia por departamento, para comparar con aws
    pob_dpto = poblacion.groupby(["cod_dpto", "departamento", "ano"], as_index=False)[
        "poblacion"
    ].sum()
    validos = casos[casos["cod_mpio"].isin(en_dane)].merge(
        poblacion[["cod_mpio", "cod_dpto", "ano"]], on=["cod_mpio", "ano"]
    )
    casos_dpto = validos.groupby(["cod_dpto", "ano"], as_index=False)["conteo"].sum()
    incidencia = casos_dpto.merge(pob_dpto, on=["cod_dpto", "ano"])
    incidencia["incidencia_100k"] = (
        incidencia["conteo"] / incidencia["poblacion"] * 100_000
    ).round(1)
    top_incidencia = (
        incidencia[incidencia["ano"] == max(ANIOS)]
        .sort_values("incidencia_100k", ascending=False)
        .head(5)[["departamento", "conteo", "poblacion", "incidencia_100k"]]
        .rename(columns={"conteo": "casos"})
    )

    pico = casos.groupby(["ano", "semana"], as_index=False)["conteo"].sum()
    pico = pico.loc[pico.groupby("ano")["conteo"].idxmax()].rename(columns={"conteo": "casos"})

    # top de municipios para clima, altitud para todos
    print("Consultando altitud de todos los municipios...")
    divipola = divipola.assign(elevacion_m=consultar_elevacion(divipola))
    seleccion = (
        casos_mpio[casos_mpio["cod_mpio"].isin(en_divipola)]
        .sort_values("conteo", ascending=False)
        .head(args.top)
        .merge(divipola, on="cod_mpio")
        .rename(columns={"conteo": "casos_2022_2024"})
    )
    columnas = ["cod_mpio", "nom_mpio", "dpto", "latitud", "longitud", "elevacion_m"]
    seleccion[columnas + ["casos_2022_2024"]].to_csv(
        RESULTADOS / f"municipios_clima_top{args.top}.csv", index=False
    )
    divipola[columnas].to_csv(RESULTADOS / "municipios_altitud.csv", index=False)
    cobertura = seleccion["casos_2022_2024"].sum() / total_casos * 100

    print("Probando el rango de clima...")
    prueba_clima = probar_clima(seleccion.iloc[0])

    duplicados = int(sivigila.duplicated(["ano", "semana", "cod_mpio", "cod_eve"]).sum())
    semanas = [
        {
            "ano": a,
            "semana_1": inicio_semana_epi(a, 1).isoformat(),
            "semana_52_termina": (inicio_semana_epi(a, 52) + timedelta(days=6)).isoformat(),
        }
        for a in ANIOS
    ]

    control = {
        "extraido_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "filas_sivigila_dengue": len(sivigila),
        "duplicados_por_llave": duplicados,
        "semana_max": int(sivigila["semana"].max()),
        "total_casos": total_casos,
        "total_muertes": int(sivigila.loc[sivigila["cod_eve"] == EVENTO_MUERTE, "conteo"].sum()),
        "codigos_con_casos": len(casos_mpio),
        "municipios_dane": len(en_dane),
        "municipios_divipola": len(en_divipola),
        "solo_en_dane": sorted(en_dane - en_divipola),
        "solo_en_divipola": sorted(en_divipola - en_dane),
        "casos_sin_cruce": casos_sin_cruce,
        "pct_casos_sin_cruce": round(casos_sin_cruce / total_casos * 100, 2),
        "municipios_clima": len(seleccion),
        "pct_casos_cubiertos_clima": round(float(cobertura), 1),
        "altitud_nula": int(divipola["elevacion_m"].isna().sum()),
        "prueba_clima": prueba_clima,
        "calendario_epi": semanas,
    }
    (RESULTADOS / "valores_control.json").write_text(
        json.dumps(control, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    reporte = f"""# Perfil de las fuentes

Generado por `explorar_fuentes.py` el {control['extraido_utc']}.

## Casos por año

{tabla_md(por_anio)}

Filas de dengue en SIVIGILA: {len(sivigila):,}. Duplicados por año, semana, municipio y evento: {duplicados}.

## Cruce de códigos de municipio

- Casos totales: {total_casos:,}
- Casos sin municipio en el DANE: {casos_sin_cruce:,} ({control['pct_casos_sin_cruce']} %)
- Municipios en el DANE: {len(en_dane):,}. En DIVIPOLA: {len(en_divipola):,}.
- Solo en el DANE: {control['solo_en_dane']}. Solo en DIVIPOLA: {control['solo_en_divipola']}.

{tabla_md(sin_cruce.head(15))}

## Departamentos con mayor incidencia en {max(ANIOS)}

{tabla_md(top_incidencia)}

## Semana con más casos por año

{tabla_md(pico)}

## Clima

- Municipios seleccionados: {len(seleccion)}, que cubren el {cobertura:.1f} % de los casos.
- Prueba del rango 2021-11-01 a 2024-12-31 en {prueba_clima['municipio']}: {prueba_clima['dias']} días, {prueba_clima['nulos_temperatura']} nulos de temperatura y {prueba_clima['nulos_lluvia']} de lluvia.
- Municipios sin altitud: {control['altitud_nula']}.
"""
    (RESULTADOS / "perfil_fuentes.md").write_text(reporte, encoding="utf-8")
    print(reporte)


if __name__ == "__main__":
    main()
