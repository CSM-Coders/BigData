#!/usr/bin/env python3
# compara las respuestas de athena, hive y spark sql con un cálculo propio en pandas
# así los tres motores y pandas se revisan entre sí
import sys
from pathlib import Path

import pandas as pd

ANOS = [2022, 2023, 2024]
CODIGOS = {"cod_dpto": str, "cod_mpio": str}

# llave de cada tabla y decimales con que la redondea el sql
TABLAS = {
    "incidencia_departamento": (["ano", "cod_dpto"], {"incidencia_100k": 2}),
    "incidencia_municipio": (["ano", "cod_mpio"], {"incidencia_100k": 2}),
    "estacionalidad_departamento": (["ano", "cod_dpto"], {"pct_del_ano": 2}),
    "brote_2024_departamento": (["cod_dpto"], {"pct_del_aumento": 2, "variacion_pct": 2}),
    "clima_rezago": (["rezago_semanas"], {"corr_lluvia": 4, "corr_temperatura": 4, "corr_humedad": 4,
                                          "pct_lluvia_positiva": 1, "pct_temperatura_positiva": 1,
                                          "pct_humedad_positiva": 1}),
    "gravedad_departamento": (["cod_dpto"], {"pct_gravedad": 2, "letalidad_pct": 3}),
    "incidencia_altitud": (["ano", "orden_rango"], {"incidencia_100k": 2}),
}

# columnas en el orden en que las devuelve el sql
COLUMNAS = {
    "incidencia_departamento": "ano cod_dpto departamento casos poblacion incidencia_100k puesto",
    "incidencia_municipio": "ano cod_mpio municipio cod_dpto departamento casos poblacion incidencia_100k puesto",
    "estacionalidad_departamento": "ano cod_dpto departamento semana_pico inicio_semana_pico "
                                   "casos_semana_pico casos_ano pct_del_ano",
    "brote_2024_departamento": "cod_dpto departamento casos_2023 casos_2024 aumento pct_del_aumento "
                               "variacion_pct puesto",
    "clima_rezago": "rezago_semanas municipios corr_lluvia corr_temperatura corr_humedad "
                    "pct_lluvia_positiva pct_temperatura_positiva pct_humedad_positiva",
    "gravedad_departamento": "cod_dpto departamento casos dengue_grave muertes pct_gravedad letalidad_pct "
                             "puesto_gravedad puesto_letalidad",
    "incidencia_altitud": "ano orden_rango rango_altitud municipios poblacion casos incidencia_100k",
}
COLUMNAS = {tabla: columnas.split() for tabla, columnas in COLUMNAS.items()}

# valor publicado en el punto 1, resultados/perfil_fuentes.md
VALLE_2024 = 1890.7


def leer_trusted(carpeta):
    def tabla(nombre):
        return pd.read_parquet(Path(carpeta) / nombre)

    casos = tabla("casos_dengue")
    casos["ano"] = casos["ano"].astype(int)
    return casos, tabla("poblacion"), tabla("municipios"), tabla("clima_diario")


def puesto(serie):
    return serie.rank(method="min", ascending=False).astype(int)


def nombres_dpto(poblacion):
    return poblacion.groupby("cod_dpto", as_index=False)["departamento"].max()


def casos_mpio(casos):
    solo = casos[casos["tipo_evento"] == "caso"]
    return solo.groupby(["ano", "cod_mpio"], as_index=False)["conteo"].sum().rename(columns={"conteo": "casos"})


def poblacion_con_casos(casos, poblacion):
    pob = poblacion[poblacion["ano"].isin(ANOS)]
    df = pob.merge(casos_mpio(casos), on=["ano", "cod_mpio"], how="left")
    df["casos"] = df["casos"].fillna(0).astype(int)
    return df


def incidencia_departamento(casos, poblacion, **_):
    df = poblacion_con_casos(casos, poblacion)
    df = df.groupby(["ano", "cod_dpto"], as_index=False).agg(
        departamento=("departamento", "max"), casos=("casos", "sum"), poblacion=("poblacion", "sum"))
    df["incidencia_100k"] = df["casos"] * 100000 / df["poblacion"]
    df["puesto"] = df.groupby("ano")["incidencia_100k"].transform(puesto)
    return df


def incidencia_municipio(casos, poblacion, **_):
    df = poblacion_con_casos(casos, poblacion)
    df["incidencia_100k"] = df["casos"] * 100000 / df["poblacion"]
    df["puesto"] = df.groupby("ano")["incidencia_100k"].transform(puesto)
    return df[["ano", "cod_mpio", "municipio", "cod_dpto", "departamento",
               "casos", "poblacion", "incidencia_100k", "puesto"]]


def estacionalidad_departamento(casos, poblacion, **_):
    solo = casos[casos["tipo_evento"] == "caso"]
    semanas = solo.groupby(["ano", "cod_dpto", "semana", "fecha_inicio_semana"], as_index=False)["conteo"].sum()
    semanas["casos_ano"] = semanas.groupby(["ano", "cod_dpto"])["conteo"].transform("sum")
    pico = (semanas.sort_values(["conteo", "semana"], ascending=[False, True])
            .drop_duplicates(["ano", "cod_dpto"]))
    pico = pico.merge(nombres_dpto(poblacion), on="cod_dpto")
    pico = pico.rename(columns={"semana": "semana_pico", "fecha_inicio_semana": "inicio_semana_pico",
                                "conteo": "casos_semana_pico"})
    pico["pct_del_ano"] = pico["casos_semana_pico"] * 100 / pico["casos_ano"]
    return pico


def brote_2024_departamento(casos, poblacion, **_):
    solo = casos[casos["tipo_evento"] == "caso"]
    df = solo.pivot_table(index="cod_dpto", columns="ano", values="conteo", aggfunc="sum", fill_value=0)
    df = df.reindex(columns=ANOS, fill_value=0).reset_index()
    df = df.rename(columns={2023: "casos_2023", 2024: "casos_2024"}).merge(nombres_dpto(poblacion), on="cod_dpto")
    df["aumento"] = df["casos_2024"] - df["casos_2023"]
    df["pct_del_aumento"] = df["aumento"] * 100 / df["aumento"].sum()
    df["variacion_pct"] = (df["aumento"] * 100 / df["casos_2023"]).where(df["casos_2023"] > 0)
    df["puesto"] = puesto(df["aumento"])
    return df


def clima_rezago(casos, poblacion, clima, **_):
    semanas = clima.groupby(["cod_mpio", "ano_epi", "semana_epi"], as_index=False).agg(
        lluvia=("precipitacion_mm", "sum"), temperatura=("temperatura_media_c", "mean"),
        humedad=("humedad_relativa_pct", "mean"))
    semanas = semanas.sort_values(["cod_mpio", "ano_epi", "semana_epi"])
    for rezago in (2, 4, 6, 8):
        for variable in ("lluvia", "temperatura", "humedad"):
            semanas[f"{variable}_{rezago}"] = semanas.groupby("cod_mpio")[variable].shift(rezago)

    solo = casos[casos["tipo_evento"] == "caso"]
    casos_semana = solo.groupby(["ano", "semana", "cod_mpio"], as_index=False)["conteo"].sum()
    df = semanas.merge(poblacion, left_on=["cod_mpio", "ano_epi"], right_on=["cod_mpio", "ano"])
    df = df.drop(columns="ano").merge(casos_semana, left_on=["cod_mpio", "ano_epi", "semana_epi"],
                                      right_on=["cod_mpio", "ano", "semana"], how="left")
    df = df[df["ano_epi"].isin(ANOS)]
    df["incidencia"] = df["conteo"].fillna(0) * 100000 / df["poblacion"]

    # correlación dentro de cada municipio, sin los que no cambian de incidencia
    filas = []
    for rezago in (2, 4, 6, 8):
        por_municipio = []
        for _, grupo in df.groupby("cod_mpio"):
            if grupo["incidencia"].max() > grupo["incidencia"].min():
                por_municipio.append({v: grupo["incidencia"].corr(grupo[f"{v}_{rezago}"])
                                      for v in ("lluvia", "temperatura", "humedad")})
        m = pd.DataFrame(por_municipio)
        fila = {"rezago_semanas": rezago, "municipios": len(m)}
        for variable in ("lluvia", "temperatura", "humedad"):
            fila[f"corr_{variable}"] = m[variable].mean()
        for variable in ("lluvia", "temperatura", "humedad"):
            fila[f"pct_{variable}_positiva"] = (m[variable] > 0).mean() * 100
        filas.append(fila)
    return pd.DataFrame(filas)


def gravedad_departamento(casos, poblacion, **_):
    df = casos.assign(
        casos=casos["conteo"].where(casos["tipo_evento"] == "caso", 0),
        dengue_grave=casos["conteo"].where(casos["cod_evento"] == 220, 0),
        muertes=casos["conteo"].where(casos["tipo_evento"] == "muerte", 0),
    ).groupby("cod_dpto", as_index=False)[["casos", "dengue_grave", "muertes"]].sum()
    df = df.merge(nombres_dpto(poblacion), on="cod_dpto")
    df = df[df["casos"] > 0].copy()
    df["pct_gravedad"] = df["dengue_grave"] * 100 / df["casos"]
    df["letalidad_pct"] = df["muertes"] * 100 / df["casos"]
    df["puesto_gravedad"] = puesto(df["pct_gravedad"])
    df["puesto_letalidad"] = puesto(df["letalidad_pct"])
    return df


def incidencia_altitud(casos, poblacion, municipios, **_):
    df = municipios[["cod_mpio", "altitud_m"]].merge(poblacion_con_casos(casos, poblacion), on="cod_mpio")
    limites = [500, 1000, 1500, 2000]
    nombres = ["menos de 500 m", "500 a 999 m", "1.000 a 1.499 m", "1.500 a 1.999 m", "2.000 m o más"]
    df["orden_rango"] = df["altitud_m"].apply(lambda a: 1 + sum(a >= limite for limite in limites))
    df["rango_altitud"] = df["orden_rango"].map(lambda o: nombres[o - 1])
    df = df.groupby(["ano", "orden_rango", "rango_altitud"], as_index=False).agg(
        municipios=("cod_mpio", "count"), poblacion=("poblacion", "sum"), casos=("casos", "sum"))
    df["incidencia_100k"] = df["casos"] * 100000 / df["poblacion"]
    return df


def referencia(trusted):
    casos, poblacion, municipios, clima = leer_trusted(trusted)
    datos = {"casos": casos, "poblacion": poblacion, "municipios": municipios, "clima": clima}
    return {nombre: globals()[nombre](**datos)[COLUMNAS[nombre]] for nombre in TABLAS}


def leer_csv(carpeta, tabla):
    ruta = Path(carpeta) / tabla
    archivos = sorted(ruta.glob("part-*.csv")) if ruta.is_dir() else [Path(carpeta) / f"{tabla}.csv"]
    archivos = [a for a in archivos if a.exists()]
    if not archivos:
        return None
    return pd.concat([pd.read_csv(a, dtype=CODIGOS) for a in archivos], ignore_index=True)


def leer_parquet(carpeta, tabla):
    ruta = Path(carpeta) / tabla
    if not ruta.is_dir() or not any(ruta.iterdir()):
        return None
    return pd.read_parquet(ruta)


# lista de diferencias, vacía si todo coincide
def diferencias(esperado, obtenido, tabla):
    llave, decimales = TABLAS[tabla]
    if obtenido is None:
        return ["sin resultado"]
    obtenido = obtenido.rename(columns=str.lower)
    if list(obtenido.columns) != COLUMNAS[tabla]:
        return [f"columnas distintas: {list(obtenido.columns)}"]
    if len(obtenido) != len(esperado):
        return [f"{len(obtenido)} filas, se esperaban {len(esperado)}"]

    a = esperado.sort_values(llave).reset_index(drop=True)
    b = obtenido.sort_values(llave).reset_index(drop=True)
    problemas = []
    for columna in esperado.columns:
        x, y = a[columna], b[columna]
        if columna in decimales:
            tolerancia = 0.5 * 10 ** -decimales[columna] + 1e-9
            malas = ~(((x - y.astype(float)).abs() <= tolerancia) | (x.isna() & y.isna()))
        elif pd.api.types.is_numeric_dtype(x):
            malas = x.astype("int64") != pd.to_numeric(y).astype("int64")
        else:
            malas = x.astype(str).str[:10] != y.astype(str).str[:10]
        if malas.any():
            i = malas.idxmax()
            problemas.append(f"{columna}: {int(malas.sum())} distintos, por ejemplo {x[i]} contra {y[i]}")
    return problemas


USO = """Uso: python comparar_motores.py <trusted> <athena> <hive> <sparksql>
  trusted   copia local de la zona trusted
  athena    carpeta con los csv de 00_consultas_athena.sh
  hive      copia local de la zona refined, que llenó hive
  sparksql  carpeta con los csv de spark sql"""


def main():
    if len(sys.argv) != 5:
        sys.exit(USO)
    trusted, athena, hive, sparksql = sys.argv[1:]
    esperados = referencia(trusted)
    motores = {
        "athena": lambda t: leer_csv(athena, t),
        "hive": lambda t: leer_parquet(hive, t),
        "sparksql": lambda t: leer_csv(sparksql, t),
    }

    fallas = 0
    print(f"{'tabla':<30}{'filas':>7}  " + "".join(f"{m:<10}" for m in motores))
    detalles = []
    for tabla, esperado in esperados.items():
        estados = []
        for motor, leer in motores.items():
            problemas = diferencias(esperado, leer(tabla), tabla)
            estados.append("OK" if not problemas else "FALLA")
            detalles += [f"  {motor} {tabla}: {p}" for p in problemas]
        fallas += estados.count("FALLA")
        print(f"{tabla:<30}{len(esperado):>7}  " + "".join(f"{e:<10}" for e in estados))

    # control contra la cifra publicada en el punto 1
    print()
    for motor, leer in motores.items():
        df = leer("incidencia_departamento")
        valor = None
        if df is not None:
            fila = df[(df["ano"].astype(int) == 2024) & (df["cod_dpto"] == "76")]
            valor = round(float(fila["incidencia_100k"].iloc[0]), 1) if len(fila) else None
        bien = valor == VALLE_2024
        fallas += not bien
        print(f"{'OK' if bien else 'FALLA':<7}{motor}: incidencia del Valle del Cauca en 2024 = {valor}, punto 1 = {VALLE_2024}")

    if detalles:
        print("\nDiferencias:")
        print("\n".join(detalles))
    print()
    if fallas:
        sys.exit(f"FALLA: {fallas} comparaciones no coinciden.")
    print(f"OK: Athena, Hive y Spark SQL dan las mismas {len(esperados)} tablas que el cálculo en pandas.")


if __name__ == "__main__":
    main()
