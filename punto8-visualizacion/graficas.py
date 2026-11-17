#!/usr/bin/env python3
# una gráfica por pregunta de negocio, con los datos que entrega la api
import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import pandas as pd
import requests

# solo guarda archivos, no abre ventanas
plt.switch_backend("Agg")

COLORES = {2022: "#9ecae1", 2023: "#4292c6", 2024: "#08306b"}
ROJO = "#c0392b"
plt.rcParams.update({"figure.dpi": 120, "axes.spines.top": False, "axes.spines.right": False,
                     "axes.titleweight": "bold", "axes.titlesize": 12, "font.size": 9})


class Api:
    def __init__(self, url):
        self.url = url.rstrip("/")

    def tabla(self, nombre, **filtros):
        r = requests.get(f"{self.url}/tablas/{nombre}", params=filtros, timeout=60)
        r.raise_for_status()
        cuerpo = r.json()
        print(f"{nombre:<30}{cuerpo['filas']:>6} filas  {cuerpo['segundos']:>5.2f} s")
        return pd.DataFrame(cuerpo["datos"], columns=cuerpo["columnas"])


# números con punto de miles y coma decimal
def es(numero, decimales=0):
    return f"{numero:,.{decimales}f}".replace(",", "_").replace(".", ",").replace("_", ".")


def eje_es(decimales=0):
    return mtick.FuncFormatter(lambda x, _: es(x, decimales))


def titulo_dpto(nombre):
    if nombre.startswith("ARCHIPIÉLAGO"):
        return "San Andrés y Providencia"
    return nombre.title().replace(" De ", " de ").replace(" Del ", " del ").replace(" Y ", " y ")


def p1_incidencia(api, salida):
    df = api.tabla("incidencia_departamento")
    top = df[df["ano"] == 2024].nsmallest(10, "puesto")["cod_dpto"]
    df = df[df["cod_dpto"].isin(top)]
    orden = df[df["ano"] == 2024].sort_values("incidencia_100k")["departamento"].tolist()
    ancho = pd.DataFrame(df.pivot(index="departamento", columns="ano", values="incidencia_100k")).loc[orden]
    fig, ax = plt.subplots(figsize=(8, 5))
    alto = 0.27
    for i, ano in enumerate([2022, 2023, 2024]):
        ax.barh([y + (i - 1) * alto for y in range(len(ancho))], ancho[ano], height=alto,
                color=COLORES[ano], label=str(ano))
    ax.set_yticks(range(len(ancho)), [titulo_dpto(d) for d in ancho.index])
    ax.set_xlabel("casos por 100.000 habitantes")
    ax.set_title("1. Departamentos con mayor incidencia en 2024")
    ax.legend(frameon=False, loc="lower right")
    ax.xaxis.set_major_formatter(eje_es())
    return guardar(fig, salida, "p1_incidencia_departamento.png")


def p2_serie(api, salida):
    df = api.tabla("serie_semanal_departamento")
    df["fecha_inicio_semana"] = pd.to_datetime(df["fecha_inicio_semana"])
    pais = df.groupby("fecha_inicio_semana")["casos"].sum()
    principales = df.groupby("departamento")["casos"].sum().nlargest(3).index
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.fill_between(pais.index, pais.values, color="#d9d9d9", label="Colombia")
    for dpto, color in zip(principales, ["#08306b", ROJO, "#e67e22"]):
        serie = df[df["departamento"] == dpto].groupby("fecha_inicio_semana")["casos"].sum()
        ax.plot(serie.index, serie.values, color=color, linewidth=1.4, label=titulo_dpto(dpto))
    pico = pais.idxmax()
    ax.annotate(f"pico: {es(pais.max())} casos\nsemana del {pico:%d-%m-%Y}", xy=(pico, pais.max()),
                xytext=(-150, -10), textcoords="offset points", arrowprops={"arrowstyle": "->"})
    ax.set_ylabel("casos por semana epidemiológica")
    ax.set_title("2. Casos semanales de dengue, 2022 a 2024")
    ax.legend(frameon=False, loc="upper left")
    ax.yaxis.set_major_formatter(eje_es())
    return guardar(fig, salida, "p2_serie_semanal.png")


def p3_brote(api, salida):
    df = api.tabla("brote_2024_departamento").sort_values("aumento", ascending=False)
    top = df.head(10)
    fig, ax = plt.subplots(figsize=(9, 4.8))
    ax.bar(range(len(top)), top["aumento"], color="#4292c6")
    ax.set_xticks(range(len(top)), [titulo_dpto(d) for d in top["departamento"]], rotation=35, ha="right")
    ax.set_ylabel("casos más en 2024 que en 2023")
    ax.yaxis.set_major_formatter(eje_es())
    acumulado = top["pct_del_aumento"].cumsum()
    eje = ax.twinx()
    eje.plot(range(len(top)), acumulado, color=ROJO, marker="o")
    eje.set_ylim(0, 100)
    eje.yaxis.set_major_formatter(mtick.FuncFormatter(lambda x, _: f"{x:.0f} %"))
    eje.set_ylabel("parte acumulada del aumento", color=ROJO)
    eje.spines["right"].set_visible(True)
    for x, y in list(enumerate(acumulado))[:5]:
        eje.annotate(f"{y:.0f} %", (x, y), xytext=(0, 7), textcoords="offset points", ha="center", color=ROJO)
    ax.set_title(f"3. Departamentos que explican el brote: {es(df['aumento'].sum())} casos más en 2024")
    return guardar(fig, salida, "p3_brote_2024.png")


def p4_clima(api, salida):
    df = api.tabla("clima_rezago")
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for variable, color, nombre in [("temperatura", ROJO, "Temperatura"), ("lluvia", "#2171b5", "Lluvia"),
                                    ("humedad", "#41ab5d", "Humedad")]:
        ax.plot(df["rezago_semanas"], df[f"corr_{variable}"], marker="o", color=color, label=nombre)
    ax.axhline(0, color="black", linewidth=0.6)
    ax.set_xticks(df["rezago_semanas"], [f"{r} semanas" for r in df["rezago_semanas"]])
    ax.set_ylabel("correlación promedio por municipio")
    ax.set_xlabel("clima de cuántas semanas antes")
    ax.set_title("4. Clima e incidencia en los 300 municipios con clima")
    ax.yaxis.set_major_formatter(eje_es(2))
    ax.margins(x=0.08)
    ax.legend(frameon=False)
    return guardar(fig, salida, "p4_clima_rezago.png")


def p5_gravedad(api, salida):
    df = api.tabla("gravedad_departamento")
    df = df[df["casos"] >= 500]
    fig, ax = plt.subplots(figsize=(8, 5.2))
    ax.scatter(df["pct_gravedad"], df["letalidad_pct"], s=df["casos"] / 250 + 10, color="#4292c6",
               alpha=0.6, edgecolor="white")
    nombres = pd.concat([df.nsmallest(5, "puesto_letalidad"), df.nsmallest(3, "puesto_gravedad"),
                         df.nlargest(2, "casos")]).drop_duplicates("cod_dpto")
    for _, f in nombres.iterrows():
        ax.annotate(titulo_dpto(f["departamento"]), (f["pct_gravedad"], f["letalidad_pct"]),
                    xytext=(5, 4), textcoords="offset points", fontsize=8)
    ax.set_xlabel("dengue grave por cada 100 casos")
    ax.set_ylabel("muertes por cada 100 casos")
    ax.set_title("5. Gravedad y letalidad por departamento, 2022 a 2024")
    ax.xaxis.set_major_formatter(eje_es(1))
    ax.yaxis.set_major_formatter(eje_es(2))
    ax.text(0.99, 0.02, "tamaño del punto: casos. solo departamentos con 500 casos o más",
            transform=ax.transAxes, ha="right", fontsize=7, color="gray")
    return guardar(fig, salida, "p5_gravedad_letalidad.png")


def p6_altitud(api, salida):
    df = api.tabla("incidencia_altitud").sort_values("orden_rango")
    rangos = df.drop_duplicates("orden_rango")["rango_altitud"].tolist()
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ancho = 0.27
    for i, ano in enumerate([2022, 2023, 2024]):
        datos = df[df["ano"] == ano]
        ax.bar([x + (i - 1) * ancho for x in range(len(datos))], datos["incidencia_100k"], width=ancho,
               color=COLORES[ano], label=str(ano))
    ax.set_xticks(range(len(rangos)), rangos)
    ax.set_ylabel("casos por 100.000 habitantes")
    ax.set_xlabel("altitud del municipio")
    ax.set_title("6. Incidencia según la altitud del municipio")
    ax.legend(frameon=False)
    ax.yaxis.set_major_formatter(eje_es())
    return guardar(fig, salida, "p6_incidencia_altitud.png")


def p7_distribucion(api, salida):
    df = api.tabla("municipio_anual")
    fig, ax = plt.subplots(figsize=(8, 4.5))
    datos = [df[(df["ano"] == ano) & (df["casos"] > 0)]["incidencia_100k"] for ano in [2022, 2023, 2024]]
    caja = ax.boxplot(datos, tick_labels=["2022", "2023", "2024"], showfliers=False, patch_artist=True,
                      medianprops={"color": "black"})
    for parte, ano in zip(caja["boxes"], [2022, 2023, 2024]):
        parte.set_facecolor(COLORES[ano])
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(mtick.FuncFormatter(lambda x, _: es(x, 0 if x >= 1 else 1)))
    ax.set_ylabel("casos por 100.000 habitantes, escala logarítmica")
    ax.set_title("Distribución de la incidencia en los municipios con casos")
    return guardar(fig, salida, "p7_distribucion_municipios.png")


def guardar(fig, salida, nombre):
    fig.tight_layout()
    ruta = Path(salida) / nombre
    fig.savefig(ruta)
    plt.close(fig)
    return ruta


def main():
    parser = argparse.ArgumentParser(description="gráficas del dengue con datos de la api")
    parser.add_argument("--api", required=True, help="url de api gateway")
    parser.add_argument("--salida", default=Path(__file__).parent / "graficas")
    args = parser.parse_args()
    Path(args.salida).mkdir(parents=True, exist_ok=True)

    api = Api(args.api)
    print("Datos pedidos a la API:")
    rutas = [f(api, args.salida) for f in (p1_incidencia, p2_serie, p3_brote, p4_clima,
                                           p5_gravedad, p6_altitud, p7_distribucion)]
    print("\nGráficas:")
    for ruta in rutas:
        print(f"  {ruta}")
    print(f"\nOK: {len(rutas)} gráficas hechas con los datos de la API.")


if __name__ == "__main__":
    main()
