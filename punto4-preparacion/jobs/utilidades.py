# funciones comunes de los jobs de raw a trusted
# corren en aws glue y también con spark-submit, en emr o en local
import argparse
import json
import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

try:
    from awsglue.context import GlueContext
    from awsglue.job import Job
    from awsglue.utils import getResolvedOptions

    EN_GLUE = True
except ImportError:
    EN_GLUE = False

PARAMETROS = ["RAW", "TRUSTED", "METRICAS"]


class Contexto:
    def __init__(self, nombre):
        if EN_GLUE:
            from pyspark.context import SparkContext

            args = getResolvedOptions(sys.argv, ["JOB_NAME"] + PARAMETROS)
            glue = GlueContext(SparkContext.getOrCreate())
            self.spark = glue.spark_session
            self.job = Job(glue)
            self.job.init(args["JOB_NAME"], args)
        else:
            parser = argparse.ArgumentParser(description=nombre)
            for parametro in PARAMETROS:
                parser.add_argument("--" + parametro, required=True)
            args = vars(parser.parse_known_args()[0])
            self.spark = SparkSession.builder.appName(nombre).getOrCreate()
            self.job = None

        self.nombre = nombre
        self.raw = args["RAW"].rstrip("/")
        self.trusted = args["TRUSTED"].rstrip("/")
        self.metricas_dir = args["METRICAS"].rstrip("/")
        self.metricas = {}
        # las particiones fecha_ingesta=AAAA-MM-DD se leen como texto
        self.spark.conf.set("spark.sql.sources.partitionColumnTypeInference.enabled", "false")
        self.spark.conf.set("spark.sql.session.timeZone", "UTC")
        # sin archivos _SUCCESS, para que el catálogo solo vea parquet
        self.spark.sparkContext._jsc.hadoopConfiguration().set(
            "mapreduce.fileoutputcommitter.marksuccessfuljobs", "false"
        )

    def metrica(self, clave, valor):
        self.metricas[clave] = valor
        print(f"[{self.nombre}] {clave}: {valor}", flush=True)

    def escribir(self, df, tabla, particion=None, archivos=None):
        ruta = f"{self.trusted}/{tabla}"
        if archivos:
            df = df.coalesce(archivos)
        escritor = df.write.mode("overwrite").option("compression", "snappy")
        if particion:
            escritor = escritor.partitionBy(particion)
        escritor.parquet(ruta)
        self.metrica("destino", ruta)

    def terminar(self):
        guardar_metricas(f"{self.metricas_dir}/{self.nombre}.json", self.metricas)
        if self.job:
            self.job.commit()
        else:
            self.spark.stop()


def guardar_metricas(ruta, metricas):
    contenido = json.dumps(metricas, ensure_ascii=False, indent=2, default=str)
    if ruta.startswith("s3://"):
        import boto3

        bucket, clave = ruta[5:].split("/", 1)
        boto3.client("s3").put_object(
            Bucket=bucket, Key=clave, Body=contenido.encode("utf-8"),
            ContentType="application/json",
        )
    else:
        from pathlib import Path

        destino = Path(ruta.replace("file://", ""))
        destino.parent.mkdir(parents=True, exist_ok=True)
        destino.write_text(contenido, encoding="utf-8")


def ultima_ingesta(df):
    # cada corrida de la ingesta deja una partición, se usa la más reciente
    fecha = df.agg(F.max("fecha_ingesta")).first()[0]
    if fecha is None:
        raise RuntimeError("No hay datos en raw para esta fuente")
    return df.where(F.col("fecha_ingesta") == fecha), fecha


def sql_inicio_ano_epi(ano):
    # domingo en que empieza el año epidemiológico
    # la semana 1 es la primera de domingo a sábado con al menos 4 días del año
    primero = f"make_date({ano}, 1, 1)"
    dia = f"(dayofweek({primero}) - 1)"
    return f"date_add({primero}, CASE WHEN {dia} <= 3 THEN -{dia} ELSE 7 - {dia} END)"


def ano_epi(fecha):
    anio = f"year({fecha})"
    return F.expr(
        f"CASE WHEN {fecha} >= {sql_inicio_ano_epi(anio + ' + 1')} THEN {anio} + 1 "
        f"WHEN {fecha} >= {sql_inicio_ano_epi(anio)} THEN {anio} "
        f"ELSE {anio} - 1 END"
    )


def semana_epi(fecha, ano_epi_col):
    return F.expr(
        f"CAST(floor(datediff({fecha}, {sql_inicio_ano_epi(ano_epi_col)}) / 7) AS INT) + 1"
    )


def inicio_semana(ano, semana):
    return F.expr(f"date_add({sql_inicio_ano_epi(ano)}, ({semana} - 1) * 7)")
