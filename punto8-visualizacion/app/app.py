# tablero del dengue en colombia, todos los datos llegan por api gateway
import os

import altair as alt
import pandas as pd
import requests
import streamlit as st

API_URL = os.environ.get("API_URL", "").rstrip("/")
ANOS = [2024, 2023, 2022]
TODOS = "Todo el país"

st.set_page_config(page_title="Dengue en Colombia", page_icon="🦟", layout="wide")

# ejes con punto de miles, coma decimal y meses en español
LOCALE = {
    "number": {"decimal": ",", "thousands": ".", "grouping": [3], "currency": ["$", ""]},
    "time": {
        "dateTime": "%A, %e de %B de %Y, %X", "date": "%d/%m/%Y", "time": "%H:%M:%S",
        "periods": ["AM", "PM"],
        "days": ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"],
        "shortDays": ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"],
        "months": ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                   "septiembre", "octubre", "noviembre", "diciembre"],
        "shortMonths": ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"],
    },
}


def grafica(chart):
    st.altair_chart(chart.configure(locale=LOCALE), use_container_width=True)


@st.cache_data(ttl=3600, show_spinner="Consultando la API...")
def tabla(nombre):
    r = requests.get(f"{API_URL}/tablas/{nombre}", timeout=60)
    r.raise_for_status()
    cuerpo = r.json()
    return pd.DataFrame(cuerpo["datos"], columns=cuerpo["columnas"])


def es(numero, decimales=0):
    return f"{numero:,.{decimales}f}".replace(",", "_").replace(".", ",").replace("_", ".")


def nombre(texto):
    if texto.startswith("ARCHIPIÉLAGO"):
        return "San Andrés y Providencia"
    return texto.title().replace(" De ", " de ").replace(" Del ", " del ").replace(" Y ", " y ")


if not API_URL:
    st.error("Falta la variable API_URL con la dirección de API Gateway.")
    st.stop()

try:
    municipios = tabla("municipio_anual")
    serie = tabla("serie_semanal_departamento")
except requests.RequestException as error:
    st.error(f"No se pudo leer la API: {error}")
    st.stop()

dptos = (municipios[["cod_dpto", "departamento"]].drop_duplicates()
         .assign(nombre=lambda d: d["departamento"].map(nombre)).sort_values("nombre"))

with st.sidebar:
    st.header("Filtros")
    ano = st.selectbox("Año", ANOS)
    elegido = st.selectbox("Departamento", [TODOS] + dptos["nombre"].tolist())
    cod_dpto = None if elegido == TODOS else dptos.loc[dptos["nombre"] == elegido, "cod_dpto"].iloc[0]
    st.divider()
    st.caption("Datos de la zona refined del datalake, leídos con Athena a través de API Gateway.")
    st.code(API_URL, language=None)
    st.caption("Fuentes: SIVIGILA (INS), proyecciones de población (DANE), DIVIPOLA y Open-Meteo.")

lugar = municipios if cod_dpto is None else municipios[municipios["cod_dpto"] == cod_dpto]
actual = lugar[lugar["ano"] == ano]
anterior = lugar[lugar["ano"] == ano - 1]

st.title("Dengue en Colombia, 2022 a 2024")
st.caption(f"{elegido}, año {ano}")

casos = int(actual["casos"].sum())
poblacion = int(actual["poblacion"].sum())
c1, c2, c3, c4, c5 = st.columns(5)
c1.metric("Casos", es(casos),
          None if anterior.empty else f"{es((casos / anterior['casos'].sum() - 1) * 100, 1)} % frente a {ano - 1}",
          delta_color="inverse")
c2.metric("Incidencia por 100.000", es(casos * 100000 / poblacion, 1) if poblacion else "-")
c3.metric("Dengue grave", es(actual["dengue_grave"].sum()))
c4.metric("Muertes", es(actual["muertes"].sum()))
con_casos = int((actual["casos"] > 0).sum())
c5.metric("Municipios con casos", es(con_casos),
          f"{es(con_casos * 100 / len(actual), 1)} % de {es(len(actual))}" if len(actual) else None, delta_color="off")

mapa, semanas, incidencia, brote, clima, gravedad, altitud = st.tabs(
    ["Mapa", "Serie semanal", "Incidencia", "Brote 2024", "Clima", "Gravedad", "Altitud"])

with mapa:
    puntos = actual[(actual["casos"] > 0) & actual["latitud"].notna()].copy()
    # el radio crece con la raíz de los casos para que las ciudades no tapen todo
    puntos["radio"] = puntos["casos"] ** 0.5 * (200 if cod_dpto is None else 60)
    st.map(puntos, latitude="latitud", longitude="longitud", size="radio", color="#c0392bb0")
    st.caption("Cada círculo es un municipio con casos. El tamaño crece con el número de casos.")
    st.subheader("Municipios con más casos")
    st.dataframe(
        actual.nlargest(15, "casos")[["municipio", "departamento", "altitud_m", "poblacion", "casos",
                                       "incidencia_100k", "muertes"]],
        hide_index=True, use_container_width=True,
        column_config={"altitud_m": "Altitud (m)", "incidencia_100k": "Incidencia por 100.000"})

with semanas:
    datos = serie if cod_dpto is None else serie[serie["cod_dpto"] == cod_dpto]
    datos = (datos.groupby("fecha_inicio_semana", as_index=False)[["casos", "dengue_grave", "muertes"]].sum()
             .assign(fecha_inicio_semana=lambda d: pd.to_datetime(d["fecha_inicio_semana"])))
    st.subheader(f"Casos por semana epidemiológica, {elegido.lower() if cod_dpto is None else elegido}")
    linea = alt.Chart(datos).mark_line(color="#c0392b").encode(
        x=alt.X("fecha_inicio_semana:T", title="inicio de la semana", axis=alt.Axis(format="%b %Y")),
        y=alt.Y("casos:Q", title="casos"),
        tooltip=[alt.Tooltip("fecha_inicio_semana:T", title="semana", format="%d-%m-%Y"),
                 "casos", "dengue_grave", "muertes"])
    grafica(linea)
    pico = datos.loc[datos["casos"].idxmax()]
    st.write(f"La semana con más casos empezó el **{pico['fecha_inicio_semana']:%d-%m-%Y}**, "
             f"con **{es(pico['casos'])}** casos.")

with incidencia:
    if cod_dpto is None:
        datos = tabla("incidencia_departamento")
        datos = datos[datos["ano"] == ano].assign(nombre=lambda d: d["departamento"].map(nombre))
        st.subheader(f"Incidencia por departamento en {ano}")
        eje = "nombre:N"
    else:
        datos = actual.nlargest(25, "incidencia_100k").assign(nombre=lambda d: d["municipio"].map(nombre))
        st.subheader(f"Municipios de {elegido} con mayor incidencia en {ano}")
        eje = "nombre:N"
    barras = alt.Chart(datos).mark_bar(color="#08306b").encode(
        x=alt.X("incidencia_100k:Q", title="casos por 100.000 habitantes"),
        y=alt.Y(eje, sort="-x", title=None),
        tooltip=["nombre", "casos", "poblacion", "incidencia_100k"])
    grafica(barras)

with brote:
    datos = tabla("brote_2024_departamento").assign(nombre=lambda d: d["departamento"].map(nombre))
    st.subheader(f"{es(datos['aumento'].sum())} casos más en 2024 que en 2023")
    barras = alt.Chart(datos.nsmallest(12, "puesto")).mark_bar(color="#4292c6").encode(
        x=alt.X("aumento:Q", title="aumento de casos"),
        y=alt.Y("nombre:N", sort="-x", title=None),
        tooltip=["nombre", "casos_2023", "casos_2024", "aumento", "pct_del_aumento", "variacion_pct"])
    grafica(barras)
    top3 = datos.nsmallest(3, "puesto")
    st.write(f"{', '.join(top3['nombre'])} explican el **{es(top3['pct_del_aumento'].sum(), 1)} %** del aumento.")

with clima:
    datos = tabla("clima_rezago")
    largo = datos.melt(id_vars="rezago_semanas", value_vars=["corr_temperatura", "corr_lluvia", "corr_humedad"],
                       var_name="variable", value_name="correlacion")
    largo["variable"] = largo["variable"].str.replace("corr_", "")
    st.subheader("Correlación entre la incidencia y el clima de semanas antes")
    lineas = alt.Chart(largo).mark_line(point=True).encode(
        x=alt.X("rezago_semanas:O", title="semanas de rezago"),
        y=alt.Y("correlacion:Q", title="correlación promedio por municipio"),
        color=alt.Color("variable:N", scale=alt.Scale(domain=["temperatura", "lluvia", "humedad"],
                                                      range=["#c0392b", "#2171b5", "#41ab5d"])))
    grafica(lineas)
    st.caption("Se calcula una correlación por municipio, en los 300 con clima, y luego se promedian.")
    con_clima = actual[actual["temperatura_media_c"].notna() & (actual["casos"] > 0)]
    if not con_clima.empty:
        st.subheader(f"Temperatura media e incidencia por municipio en {ano}")
        puntos = alt.Chart(con_clima).mark_circle(opacity=0.6).encode(
            x=alt.X("temperatura_media_c:Q", title="temperatura media del año (°C)", scale=alt.Scale(zero=False)),
            y=alt.Y("incidencia_100k:Q", title="incidencia por 100.000, escala logarítmica",
                    scale=alt.Scale(type="log")),
            size=alt.Size("casos:Q", legend=None),
            tooltip=["municipio", "departamento", "temperatura_media_c", "lluvia_anual_mm", "incidencia_100k"])
        grafica(puntos)

with gravedad:
    datos = tabla("gravedad_departamento").assign(nombre=lambda d: d["departamento"].map(nombre))
    st.subheader("Gravedad y letalidad por departamento, 2022 a 2024")
    puntos = alt.Chart(datos[datos["casos"] >= 500]).mark_circle(opacity=0.7, color="#4292c6").encode(
        x=alt.X("pct_gravedad:Q", title="dengue grave por cada 100 casos"),
        y=alt.Y("letalidad_pct:Q", title="muertes por cada 100 casos"),
        size=alt.Size("casos:Q", legend=None),
        tooltip=["nombre", "casos", "dengue_grave", "muertes", "pct_gravedad", "letalidad_pct"])
    grafica(puntos)
    st.dataframe(datos.sort_values("puesto_letalidad")[["nombre", "casos", "dengue_grave", "muertes",
                                                         "pct_gravedad", "letalidad_pct"]],
                 hide_index=True, use_container_width=True)

with altitud:
    datos = tabla("incidencia_altitud")
    datos["ano"] = datos["ano"].astype(str)
    st.subheader("Incidencia por rango de altitud del municipio")
    barras = alt.Chart(datos).mark_bar().encode(
        x=alt.X("rango_altitud:N", sort=alt.SortField("orden_rango"), title="altitud del municipio",
                axis=alt.Axis(labelAngle=0)),
        xOffset="ano:N",
        y=alt.Y("incidencia_100k:Q", title="casos por 100.000 habitantes"),
        color=alt.Color("ano:N", title="año", scale=alt.Scale(range=["#9ecae1", "#4292c6", "#08306b"])),
        tooltip=["ano", "rango_altitud", "municipios", "casos", "incidencia_100k"])
    grafica(barras)
