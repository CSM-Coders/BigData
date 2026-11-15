# raw/sivigila a trusted/casos_dengue
# arregla códigos, quita el exterior, valida y agrega las fechas de cada semana
from pyspark.sql import functions as F

from utilidades import Contexto, inicio_semana, ultima_ingesta

EVENTOS = {210: "caso", 220: "caso", 580: "muerte"}
LLAVE = ["ano", "semana", "cod_mpio", "cod_evento"]

ctx = Contexto("trusted_casos")

raw = ctx.spark.read.option("header", True).option("sep", "\t").csv(f"{ctx.raw}/sivigila/")
raw, fecha = ultima_ingesta(raw)
ctx.metrica("fecha_ingesta", fecha)
ctx.metrica("filas_raw", raw.count())

tipos = F.create_map(*[x for cod, tipo in EVENTOS.items() for x in (F.lit(cod), F.lit(tipo))])

df = raw.select(
    F.col("cod_eve").cast("int").alias("cod_evento"),
    F.upper(F.trim("nombre_evento")).alias("evento"),
    F.col("ano").cast("int").alias("ano"),
    F.col("semana").cast("int").alias("semana"),
    # el origen guarda los códigos como número y pierde el cero inicial
    F.lpad(F.col("cod_dpto_o").cast("int").cast("string"), 2, "0").alias("cod_dpto"),
    F.lpad(F.col("cod_mun_o").cast("int").cast("string"), 5, "0").alias("cod_mpio"),
    F.upper(F.trim("departamento_ocurrencia")).alias("departamento"),
    F.upper(F.trim("municipio_ocurrencia")).alias("municipio"),
    F.col("conteo").cast("int").alias("conteo"),
    F.col("fecha_ingesta"),
).withColumn("tipo_evento", tipos[F.col("cod_evento")])

# casos fuera de colombia, no tienen municipio
exterior = F.col("cod_dpto") == "01"
ctx.metrica("filas_exterior", df.where(exterior).count())
ctx.metrica(
    "casos_exterior",
    df.where(exterior & (F.col("tipo_evento") == "caso")).agg(F.sum("conteo")).first()[0] or 0,
)
df = df.where(~exterior)

valida = (
    F.col("cod_evento").isNotNull()
    & F.col("tipo_evento").isNotNull()
    & F.col("ano").between(2000, 2100)
    & F.col("semana").between(1, 53)
    & F.col("conteo").isNotNull()
    & (F.col("conteo") > 0)
    & (F.substring("cod_mpio", 1, 2) == F.col("cod_dpto"))
)
ctx.metrica("filas_invalidas", df.where(~valida).count())
df = df.where(valida)

antes = df.count()
df = df.dropDuplicates(LLAVE)
ctx.metrica("filas_duplicadas", antes - df.count())

df = df.withColumn("fecha_inicio_semana", inicio_semana("ano", "semana")).withColumn(
    "fecha_fin_semana", F.date_add("fecha_inicio_semana", 6)
)

df = df.select(
    "cod_evento", "evento", "tipo_evento", "semana", "fecha_inicio_semana",
    "fecha_fin_semana", "cod_dpto", "departamento", "cod_mpio", "municipio",
    "conteo", "fecha_ingesta", "ano",
).cache()

totales = df.groupBy("tipo_evento").agg(F.sum("conteo").alias("total")).collect()
ctx.metrica("filas_trusted", df.count())
for fila in totales:
    ctx.metrica(f"total_{fila['tipo_evento']}s", fila["total"])
ctx.metrica(
    "municipios_con_casos",
    df.where(F.col("tipo_evento") == "caso").select("cod_mpio").distinct().count(),
)

ctx.escribir(df, "casos_dengue", particion="ano")
ctx.terminar()
