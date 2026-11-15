#!/usr/bin/env python3
# compara la zona trusted con los datos del punto 1, limpiados aquí con pandas
# así spark y pandas se revisan entre sí
import sys
from pathlib import Path

import pandas as pd

RAIZ = Path(__file__).resolve().parents[1]
DATOS_P1 = RAIZ / "punto1-caso-estudio" / "datos"
RESULTADOS_P1 = RAIZ / "punto1-caso-estudio" / "resultados"
DIAS_CLIMA = (pd.Timestamp("2024-12-31") - pd.Timestamp("2021-11-01")).days + 1

# fechas conocidas del calendario epidemiológico: (fecha, año, semana)
SEMANAS = [
    ("2022-01-01", 2021, 52),
    ("2022-01-02", 2022, 1),
    ("2023-01-01", 2023, 1),
    ("2023-12-30", 2023, 52),
    ("2023-12-31", 2024, 1),
    ("2024-04-07", 2024, 15),
    ("2024-04-13", 2024, 15),
    ("2024-12-29", 2025, 1),
]

resultados = []


def revisar(nombre, esperado, obtenido):
    estado = "OK" if esperado == obtenido else "FALLA"
    resultados.append(estado)
    print(f"{estado:6} {nombre:42} esperado {esperado!s:>14}   trusted {obtenido!s:>14}")


def leer(carpeta, tabla):
    ruta = carpeta / tabla
    if not ruta.exists():
        sys.exit(f"No existe {ruta}. Corre primero los jobs de glue.")
    df = pd.read_parquet(ruta)
    if "ano" in df.columns:
        df["ano"] = df["ano"].astype(int)
    return df


def casos(carpeta):
    print("\ncasos_dengue")
    trusted = leer(carpeta, "casos_dengue")
    p1 = pd.read_csv(DATOS_P1 / "sivigila_dengue.csv", dtype={"cod_mpio": str})
    p1 = p1[p1["cod_dpto_o"] != 1]
    p1["tipo"] = p1["cod_eve"].map({210: "caso", 220: "caso", 580: "muerte"})
    t_tipo = trusted.groupby(["ano", "tipo_evento"])["conteo"].sum()
    p_tipo = p1.groupby(["ano", "tipo"])["conteo"].sum()

    revisar("filas", len(p1), len(trusted))
    for ano in sorted(p1["ano"].unique()):
        for tipo in ("caso", "muerte"):
            revisar(f"{tipo}s {ano}", int(p_tipo[(ano, tipo)]), int(t_tipo.get((ano, tipo), 0)))
    revisar(
        "municipios con casos",
        p1.loc[p1["tipo"] == "caso", "cod_mpio"].nunique(),
        trusted.loc[trusted["tipo_evento"] == "caso", "cod_mpio"].nunique(),
    )
    revisar("códigos de 5 dígitos", True, bool(trusted["cod_mpio"].str.fullmatch(r"\d{5}").all()))
    revisar("sin exterior", 0, int((trusted["cod_dpto"] == "01").sum()))
    revisar(
        "duplicados por llave", 0,
        int(trusted.duplicated(["ano", "semana", "cod_mpio", "cod_evento"]).sum()),
    )
    semana_15 = trusted[(trusted["ano"] == 2024) & (trusted["semana"] == 15)].iloc[0]
    revisar(
        "semana 15 de 2024",
        "2024-04-07 a 2024-04-13",
        f"{semana_15['fecha_inicio_semana']} a {semana_15['fecha_fin_semana']}",
    )


def poblacion(carpeta):
    print("\npoblacion")
    trusted = leer(carpeta, "poblacion")
    p1 = pd.read_excel(
        DATOS_P1 / "PPED-AreaMun-2018-2042_VP.xlsx",
        sheet_name="PobMunicipalxÁrea", header=7, dtype={"DP": str, "MPIO": str},
    ).dropna(subset=["MPIO", "AÑO"])
    p1 = p1[(p1["ÁREA GEOGRÁFICA"] == "Total") & (p1["TOTAL"] > 0)]
    revisar("filas", len(p1), len(trusted))
    revisar("municipios", p1["MPIO"].nunique(), trusted["cod_mpio"].nunique())
    for ano in (2022, 2023, 2024):
        revisar(
            f"población total {ano}",
            int(p1.loc[p1["AÑO"] == ano, "TOTAL"].sum()),
            int(trusted.loc[trusted["ano"] == ano, "poblacion"].sum()),
        )
    revisar("duplicados por llave", 0, int(trusted.duplicated(["cod_mpio", "ano"]).sum()))


def municipios(carpeta):
    print("\nmunicipios")
    trusted = leer(carpeta, "municipios").set_index("cod_mpio")
    p1 = pd.read_csv(RESULTADOS_P1 / "municipios_altitud.csv", dtype={"cod_mpio": str})
    p1 = p1.set_index("cod_mpio")
    revisar("filas", len(p1), len(trusted))
    comunes = p1.index.intersection(trusted.index)
    for columna in ("latitud", "longitud"):
        diferencia = (trusted.loc[comunes, columna] - p1.loc[comunes, columna]).abs().max()
        revisar(f"{columna} igual al punto 1", True, bool(diferencia < 1e-6))
    revisar("sin altitud", 0, int(trusted["altitud_m"].isna().sum()))
    diferencia = (trusted.loc[comunes, "altitud_m"] - p1.loc[comunes, "elevacion_m"]).abs()
    revisar("altitud igual al punto 1", True, bool((diferencia.dropna() < 1).all()))


def clima(carpeta):
    print("\nclima_diario")
    trusted = leer(carpeta, "clima_diario")
    esperados = pd.read_csv(RESULTADOS_P1 / "municipios_clima_top300.csv", dtype={"cod_mpio": str})
    revisar("municipios", len(esperados), trusted["cod_mpio"].nunique())
    revisar("filas", len(esperados) * DIAS_CLIMA, len(trusted))
    revisar("duplicados por llave", 0, int(trusted.duplicated(["cod_mpio", "fecha"]).sum()))
    for columna in ("temperatura_media_c", "precipitacion_mm", "humedad_relativa_pct"):
        revisar(f"nulos en {columna}", 0, int(trusted[columna].isna().sum()))
    fechas = trusted.drop_duplicates("fecha").assign(fecha=lambda d: d["fecha"].astype(str))
    fechas = fechas.set_index("fecha")
    for fecha, ano, semana in SEMANAS:
        if fecha in fechas.index:
            fila = fechas.loc[fecha]
            revisar(f"semana epi de {fecha}", (ano, semana), (int(fila["ano_epi"]), int(fila["semana_epi"])))


def main():
    if len(sys.argv) != 2:
        sys.exit("Uso: verificar_trusted.py <carpeta con trusted>")
    carpeta = Path(sys.argv[1])
    casos(carpeta)
    poblacion(carpeta)
    municipios(carpeta)
    clima(carpeta)

    fallas = resultados.count("FALLA")
    print()
    if fallas:
        sys.exit(f"ERROR: {fallas} de {len(resultados)} revisiones no coinciden.")
    print(f"OK: las {len(resultados)} revisiones coinciden con el punto 1.")


if __name__ == "__main__":
    main()
