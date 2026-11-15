# raw/poblacion (excel del dane) a trusted/poblacion
# deja solo el área total, con códigos de 5 dígitos y una fila por municipio y año
import io
import re

import pandas as pd
from pyspark.sql import functions as F
from pyspark.sql.types import IntegerType, StringType, StructField, StructType

from utilidades import Contexto

HOJA = "PobMunicipalxÁrea"
FILA_ENCABEZADO = 7

ctx = Contexto("trusted_poblacion")

# spark no lee excel, se toma el archivo como binario y se abre con pandas
archivos = ctx.spark.sparkContext.binaryFiles(f"{ctx.raw}/poblacion/*/*.xlsx").collect()
if not archivos:
    raise RuntimeError("No hay archivos de población en raw")
fechas = {re.search(r"fecha_ingesta=([0-9-]+)", ruta).group(1): (ruta, datos) for ruta, datos in archivos}
fecha = max(fechas)
ruta, contenido = fechas[fecha]
ctx.metrica("fecha_ingesta", fecha)
ctx.metrica("archivo", ruta)

excel = pd.read_excel(
    io.BytesIO(contenido), sheet_name=HOJA, header=FILA_ENCABEZADO, dtype=str
)
ctx.metrica("filas_raw", len(excel))

# el excel trae filas de notas al final y tres áreas por municipio
excel = excel.dropna(subset=["MPIO", "AÑO", "TOTAL"])
excel = excel[excel["ÁREA GEOGRÁFICA"].str.strip() == "Total"]

pdf = pd.DataFrame(
    {
        "cod_dpto": excel["DP"].str.strip().str.zfill(2),
        "departamento": excel["DPNOM"].str.strip().str.upper(),
        "cod_mpio": excel["MPIO"].str.strip().str.zfill(5),
        "municipio": excel["DPMP"].str.strip().str.upper(),
        "ano": pd.to_numeric(excel["AÑO"]).astype(int),
        "poblacion": pd.to_numeric(excel["TOTAL"]).round().astype(int),
    }
)

esquema = StructType(
    [
        StructField("cod_dpto", StringType(), False),
        StructField("departamento", StringType(), False),
        StructField("cod_mpio", StringType(), False),
        StructField("municipio", StringType(), False),
        StructField("ano", IntegerType(), False),
        StructField("poblacion", IntegerType(), False),
    ]
)
df = ctx.spark.createDataFrame(pdf.to_dict("records"), schema=esquema)

valida = (F.col("poblacion") >= 0) & (F.substring("cod_mpio", 1, 2) == F.col("cod_dpto"))
ctx.metrica("filas_invalidas", df.where(~valida).count())
df = df.where(valida)

# municipios nuevos traen población 0 en los años antes de existir
# no sirven para calcular incidencia, así que se quitan
ctx.metrica("filas_poblacion_cero", df.where(F.col("poblacion") == 0).count())
df = df.where(F.col("poblacion") > 0)

antes = df.count()
df = df.dropDuplicates(["cod_mpio", "ano"]).withColumn("fecha_ingesta", F.lit(fecha)).cache()
ctx.metrica("filas_duplicadas", antes - df.count())
ctx.metrica("filas_trusted", df.count())
ctx.metrica("municipios", df.select("cod_mpio").distinct().count())
rango = df.agg(F.min("ano"), F.max("ano")).first()
ctx.metrica("anos", f"{rango[0]} a {rango[1]}")

ctx.escribir(df, "poblacion", archivos=1)
ctx.terminar()
