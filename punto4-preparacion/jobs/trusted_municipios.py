# raw/divipola y raw/openmeteo/altitud a trusted/municipios
# corrige la coma decimal de las coordenadas y agrega la altitud de cada municipio
from pyspark.sql import functions as F

from utilidades import Contexto, ultima_ingesta

ctx = Contexto("trusted_municipios")

divipola = ctx.spark.read.option("header", True).csv(f"{ctx.raw}/divipola/")
divipola, fecha = ultima_ingesta(divipola)
ctx.metrica("fecha_ingesta", fecha)
ctx.metrica("filas_raw", divipola.count())


def decimal(columna):
    return F.regexp_replace(F.trim(columna), ",", ".").cast("double")


df = divipola.select(
    F.lpad(F.trim("cod_dpto"), 2, "0").alias("cod_dpto"),
    F.upper(F.trim("dpto")).alias("departamento"),
    F.lpad(F.trim("cod_mpio"), 5, "0").alias("cod_mpio"),
    F.upper(F.trim("nom_mpio")).alias("municipio"),
    F.trim("tipo_municipio").alias("tipo_municipio"),
    decimal("latitud").alias("latitud"),
    decimal("longitud").alias("longitud"),
    F.col("fecha_ingesta"),
)

# cajas que cubren colombia, incluyendo san andrés
valida = (
    F.col("latitud").between(-5, 14)
    & F.col("longitud").between(-82, -66)
    & (F.substring("cod_mpio", 1, 2) == F.col("cod_dpto"))
)
ctx.metrica("filas_invalidas", df.where(~valida).count())
df = df.where(valida)

antes = df.count()
df = df.dropDuplicates(["cod_mpio"])
ctx.metrica("filas_duplicadas", antes - df.count())

# cada respuesta de open-meteo se guardó como <cod_mpio>.json
altitud = (
    ctx.spark.read.option("multiLine", True)
    .json(f"{ctx.raw}/openmeteo/altitud/*.json")
    .select(
        F.regexp_extract(F.input_file_name(), r"(\d{5})\.json$", 1).alias("cod_mpio"),
        F.col("elevation")[0].cast("double").alias("altitud_m"),
    )
)
ctx.metrica("respuestas_altitud", altitud.count())

df = df.join(altitud, "cod_mpio", "left").select(
    "cod_dpto", "departamento", "cod_mpio", "municipio", "tipo_municipio",
    "latitud", "longitud", "altitud_m", "fecha_ingesta",
).cache()
ctx.metrica("filas_trusted", df.count())
ctx.metrica("sin_altitud", df.where(F.col("altitud_m").isNull()).count())

ctx.escribir(df, "municipios", archivos=1)
ctx.terminar()
