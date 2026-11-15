# raw/openmeteo/clima a trusted/clima_diario
# pasa cada respuesta de la api a una fila por municipio y día, con su semana epidemiológica
from pyspark.sql import functions as F

from utilidades import Contexto, ano_epi, semana_epi

VARIABLES = {
    "temperature_2m_mean": "temperatura_media_c",
    "precipitation_sum": "precipitacion_mm",
    "relative_humidity_2m_mean": "humedad_relativa_pct",
}
# valores imposibles en colombia se dejan como nulos
RANGOS = {
    "temperatura_media_c": (-10, 45),
    "precipitacion_mm": (0, 500),
    "humedad_relativa_pct": (0, 100),
}

ctx = Contexto("trusted_clima")

raw = ctx.spark.read.option("multiLine", True).json(f"{ctx.raw}/openmeteo/clima/*.json")
raw = raw.select(
    F.regexp_extract(F.input_file_name(), r"(\d{5})\.json$", 1).alias("cod_mpio"),
    F.col("daily").alias("d"),
)
ctx.metrica("municipios_raw", raw.count())

# las variables vienen como listas paralelas a la lista de fechas
df = raw.select("cod_mpio", "d", F.posexplode("d.time").alias("i", "fecha")).select(
    "cod_mpio",
    F.to_date("fecha").alias("fecha"),
    *[F.expr(f"element_at(d.{api}, i + 1)").cast("double").alias(col) for api, col in VARIABLES.items()],
)
ctx.metrica("filas_raw", df.count())

for columna, (minimo, maximo) in RANGOS.items():
    fuera = ~F.col(columna).between(minimo, maximo)
    ctx.metrica(f"fuera_de_rango_{columna}", df.where(fuera).count())
    df = df.withColumn(columna, F.when(fuera, None).otherwise(F.col(columna)))

sin_datos = F.col("fecha").isNull() | (
    F.col("temperatura_media_c").isNull()
    & F.col("precipitacion_mm").isNull()
    & F.col("humedad_relativa_pct").isNull()
)
ctx.metrica("filas_sin_datos", df.where(sin_datos).count())
df = df.where(~sin_datos)

antes = df.count()
df = df.dropDuplicates(["cod_mpio", "fecha"])
ctx.metrica("filas_duplicadas", antes - df.count())

df = (
    df.withColumn("ano_epi", ano_epi("fecha"))
    .withColumn("semana_epi", semana_epi("fecha", "ano_epi"))
    .withColumn("ano", F.year("fecha"))
    .select(
        "cod_mpio", "fecha", "ano_epi", "semana_epi", *VARIABLES.values(), "ano",
    )
    .cache()
)
ctx.metrica("filas_trusted", df.count())
ctx.metrica("municipios", df.select("cod_mpio").distinct().count())
rango = df.agg(F.min("fecha"), F.max("fecha")).first()
ctx.metrica("fechas", f"{rango[0]} a {rango[1]}")
for columna in VARIABLES.values():
    ctx.metrica(f"nulos_{columna}", df.where(F.col(columna).isNull()).count())

ctx.escribir(df, "clima_diario", particion="ano")
ctx.terminar()
