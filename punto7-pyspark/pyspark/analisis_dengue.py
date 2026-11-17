#!/usr/bin/env python3
# análisis descriptivo con la api de dataframes de pyspark, sin sql
# repite las seis preguntas, las compara con lo que dejó hive en refined
# y escribe tres tablas nuevas en refined para el punto 8
import argparse
import sys

from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F

ANOS = [2022, 2023, 2024]
REZAGOS = [2, 4, 6, 8]
VARIABLES = ["lluvia", "temperatura", "humedad"]
RANGOS = [(500, "menos de 500 m"), (1000, "500 a 999 m"), (1500, "1.000 a 1.499 m"),
          (2000, "1.500 a 1.999 m"), (None, "2.000 m o más")]

# llave y columnas redondeadas de cada tabla del punto 6, con sus decimales
PREGUNTAS = {
    "incidencia_departamento": (["ano", "cod_dpto"], {"incidencia_100k": 2}),
    "incidencia_municipio": (["ano", "cod_mpio"], {"incidencia_100k": 2}),
    "estacionalidad_departamento": (["ano", "cod_dpto"], {"pct_del_ano": 2}),
    "brote_2024_departamento": (["cod_dpto"], {"pct_del_aumento": 2, "variacion_pct": 2}),
    "clima_rezago": (["rezago_semanas"], {f"corr_{v}": 4 for v in VARIABLES}
                     | {f"pct_{v}_positiva": 1 for v in VARIABLES}),
    "gravedad_departamento": (["cod_dpto"], {"pct_gravedad": 2, "letalidad_pct": 3}),
    "incidencia_altitud": (["ano", "orden_rango"], {"incidencia_100k": 2}),
}


def titulo(texto):
    print(f"\n> {texto}", flush=True)


def mostrar(df, filas=10):
    df.show(filas, truncate=False)
    sys.stdout.flush()


class Datos:
    # lee de glue en emr, o de carpetas parquet para probar en local
    def __init__(self, spark, args):
        self.spark = spark
        self.args = args

    def trusted(self, tabla):
        if self.args.trusted:
            return self.spark.read.parquet(f"{self.args.trusted}/{tabla}")
        return self.spark.table(f"dengue_trusted.{tabla}")

    def refined(self, tabla):
        if self.args.refined:
            return self.spark.read.parquet(f"{self.args.refined}/{tabla}")
        if self.args.trusted:
            return None
        return self.spark.table(f"dengue_refined.{tabla}")

    def escribir(self, df, tabla):
        if self.args.salida:
            df.coalesce(1).write.mode("overwrite").parquet(f"{self.args.salida}/{tabla}")
            return f"{self.args.salida}/{tabla}"
        ruta = f"s3://{self.args.datalake}/refined/{tabla}/"
        (df.coalesce(1).write.mode("overwrite").format("parquet")
         .option("path", ruta).saveAsTable(f"dengue_refined.{tabla}"))
        return ruta


def puesto(columna, particion=None):
    ventana = Window.orderBy(F.col(columna).desc())
    if particion:
        ventana = Window.partitionBy(particion).orderBy(F.col(columna).desc())
    return F.rank().over(ventana).cast("int")


def bases(datos):
    casos = datos.trusted("casos_dengue").withColumn("ano", F.col("ano").cast("int")).cache()
    poblacion_total = datos.trusted("poblacion").withColumn("ano", F.col("ano").cast("int"))
    municipios = datos.trusted("municipios").cache()
    clima = datos.trusted("clima_diario").cache()

    titulo("Tablas de trusted que lee PySpark")
    for nombre, df in [("casos_dengue", casos), ("poblacion", poblacion_total),
                       ("municipios", municipios), ("clima_diario", clima)]:
        print(f"{nombre:<14}{df.count():>8} filas", flush=True)

    poblacion = poblacion_total.where(F.col("ano").isin(ANOS)).cache()

    solo_casos = casos.where(F.col("tipo_evento") == "caso")
    casos_mpio = solo_casos.groupBy("ano", "cod_mpio").agg(F.sum("conteo").alias("casos"))
    # población de cada municipio con sus casos, cero si no tuvo
    pob_casos = (poblacion.join(casos_mpio, ["ano", "cod_mpio"], "left")
                 .withColumn("casos", F.coalesce("casos", F.lit(0)).cast("bigint"))
                 .withColumn("poblacion", F.col("poblacion").cast("bigint"))).cache()
    nombres = poblacion.groupBy("cod_dpto").agg(F.max("departamento").alias("departamento"))
    return {"casos": casos, "solo_casos": solo_casos, "poblacion": poblacion,
            "municipios": municipios, "clima": clima, "pob_casos": pob_casos, "nombres": nombres}


def incidencia_100k():
    return F.round(F.col("casos") * 100000 / F.col("poblacion"), 2)


def p1_departamento(b):
    df = (b["pob_casos"].groupBy("ano", "cod_dpto")
          .agg(F.max("departamento").alias("departamento"), F.sum("casos").alias("casos"),
               F.sum("poblacion").alias("poblacion"))
          .withColumn("tasa", F.col("casos") * 100000 / F.col("poblacion")))
    return (df.withColumn("puesto", puesto("tasa", "ano"))
            .select("ano", "cod_dpto", "departamento", "casos", "poblacion",
                    F.round("tasa", 2).alias("incidencia_100k"), "puesto"))


def p1_municipio(b):
    df = b["pob_casos"].withColumn("tasa", F.col("casos") * 100000 / F.col("poblacion"))
    return (df.withColumn("puesto", puesto("tasa", "ano"))
            .select("ano", "cod_mpio", "municipio", "cod_dpto", "departamento", "casos",
                    "poblacion", F.round("tasa", 2).alias("incidencia_100k"), "puesto"))


def p2_estacionalidad(b):
    semanas = (b["solo_casos"].groupBy("ano", "cod_dpto", "semana", "fecha_inicio_semana")
               .agg(F.sum("conteo").alias("casos_semana")))
    por_ano = Window.partitionBy("ano", "cod_dpto")
    # si dos semanas empatan, gana la primera
    orden = por_ano.orderBy(F.col("casos_semana").desc(), F.col("semana"))
    pico = (semanas.withColumn("casos_ano", F.sum("casos_semana").over(por_ano))
            .withColumn("n", F.row_number().over(orden)).where("n = 1"))
    return (pico.join(b["nombres"], "cod_dpto")
            .select("ano", "cod_dpto", "departamento",
                    F.col("semana").cast("int").alias("semana_pico"),
                    F.col("fecha_inicio_semana").alias("inicio_semana_pico"),
                    F.col("casos_semana").cast("bigint").alias("casos_semana_pico"),
                    F.col("casos_ano").cast("bigint").alias("casos_ano"),
                    F.round(F.col("casos_semana") * 100 / F.col("casos_ano"), 2).alias("pct_del_ano")))


def p3_brote(b):
    df = (b["solo_casos"].groupBy("cod_dpto").pivot("ano", ANOS).agg(F.sum("conteo"))
          .na.fill(0)
          .withColumn("aumento", F.col("2024") - F.col("2023")))
    total = Window.partitionBy()
    return (df.join(b["nombres"], "cod_dpto")
            .withColumn("pct", F.col("aumento") * 100 / F.sum("aumento").over(total))
            .withColumn("variacion", F.when(F.col("2023") > 0, F.col("aumento") * 100 / F.col("2023")))
            .withColumn("puesto", puesto("aumento"))
            .select("cod_dpto", "departamento",
                    F.col("2023").cast("bigint").alias("casos_2023"),
                    F.col("2024").cast("bigint").alias("casos_2024"),
                    F.col("aumento").cast("bigint").alias("aumento"),
                    F.round("pct", 2).alias("pct_del_aumento"),
                    F.round("variacion", 2).alias("variacion_pct"), "puesto"))


def p4_clima(b):
    semanas = (b["clima"].groupBy("cod_mpio", "ano_epi", "semana_epi")
               .agg(F.sum("precipitacion_mm").alias("lluvia"),
                    F.avg("temperatura_media_c").alias("temperatura"),
                    F.avg("humedad_relativa_pct").alias("humedad")))
    orden = Window.partitionBy("cod_mpio").orderBy("ano_epi", "semana_epi")
    for r in REZAGOS:
        for v in VARIABLES:
            semanas = semanas.withColumn(f"{v}_{r}", F.lag(v, r).over(orden))
    # una fila por semana y rezago, con el clima de esas semanas antes
    rezagos = F.array(*[
        F.struct(F.lit(r).alias("rezago_semanas"), *[F.col(f"{v}_{r}").alias(v) for v in VARIABLES])
        for r in REZAGOS])
    largo = (semanas.select("cod_mpio", "ano_epi", "semana_epi", F.explode(rezagos).alias("r"))
             .select("cod_mpio", "ano_epi", "semana_epi", "r.*"))

    casos_semana = (b["solo_casos"].groupBy("ano", "semana", "cod_mpio")
                    .agg(F.sum("conteo").alias("casos")))
    df = (largo.where(F.col("ano_epi").isin(ANOS))
          .join(b["poblacion"].select("cod_mpio", F.col("ano").alias("ano_epi"), "poblacion"),
                ["cod_mpio", "ano_epi"])
          .join(casos_semana.withColumnRenamed("ano", "ano_epi").withColumnRenamed("semana", "semana_epi"),
                ["cod_mpio", "ano_epi", "semana_epi"], "left")
          .withColumn("incidencia", F.coalesce("casos", F.lit(0)) * 100000 / F.col("poblacion")))

    # correlación dentro de cada municipio, sin los que no cambian de incidencia
    por_mpio = (df.groupBy("rezago_semanas", "cod_mpio")
                .agg(*[F.corr("incidencia", v).alias(v) for v in VARIABLES],
                     F.max("incidencia").alias("maxima"), F.min("incidencia").alias("minima"))
                .where(F.col("maxima") > F.col("minima")))
    return (por_mpio.groupBy("rezago_semanas")
            .agg(F.count("*").alias("municipios"),
                 *[F.round(F.avg(v), 4).alias(f"corr_{v}") for v in VARIABLES],
                 *[F.round(F.avg(F.when(F.col(v) > 0, 100).otherwise(0)), 1).alias(f"pct_{v}_positiva")
                   for v in VARIABLES])
            .withColumn("rezago_semanas", F.col("rezago_semanas").cast("int"))
            .orderBy("rezago_semanas"))


def p5_gravedad(b):
    c = b["casos"]
    df = (c.groupBy("cod_dpto")
          .agg(F.sum(F.when(c.tipo_evento == "caso", c.conteo).otherwise(0)).alias("casos"),
               F.sum(F.when(c.cod_evento == 220, c.conteo).otherwise(0)).alias("dengue_grave"),
               F.sum(F.when(c.tipo_evento == "muerte", c.conteo).otherwise(0)).alias("muertes"))
          .where("casos > 0")
          .withColumn("gravedad", F.col("dengue_grave") * 100 / F.col("casos"))
          .withColumn("letalidad", F.col("muertes") * 100 / F.col("casos")))
    return (df.join(b["nombres"], "cod_dpto")
            .withColumn("puesto_gravedad", puesto("gravedad"))
            .withColumn("puesto_letalidad", puesto("letalidad"))
            .select("cod_dpto", "departamento", *[F.col(x).cast("bigint").alias(x)
                                                  for x in ("casos", "dengue_grave", "muertes")],
                    F.round("gravedad", 2).alias("pct_gravedad"),
                    F.round("letalidad", 3).alias("letalidad_pct"),
                    "puesto_gravedad", "puesto_letalidad"))


def rango_altitud(columna):
    orden, nombre = F.lit(len(RANGOS)), F.lit(RANGOS[-1][1])
    for i in range(len(RANGOS) - 2, -1, -1):
        limite, texto = RANGOS[i]
        orden = F.when(F.col(columna) < limite, i + 1).otherwise(orden)
        nombre = F.when(F.col(columna) < limite, texto).otherwise(nombre)
    return orden.cast("int"), nombre


def p6_altitud(b):
    orden, nombre = rango_altitud("altitud_m")
    df = (b["municipios"].select("cod_mpio", "altitud_m").join(b["pob_casos"], "cod_mpio")
          .withColumn("orden_rango", orden).withColumn("rango_altitud", nombre))
    return (df.groupBy("ano", "orden_rango", "rango_altitud")
            .agg(F.count("*").alias("municipios"), F.sum("poblacion").alias("poblacion"),
                 F.sum("casos").alias("casos"))
            .withColumn("incidencia_100k", incidencia_100k())
            .orderBy(F.col("ano").desc(), "orden_rango"))


# compara una respuesta de pyspark con la tabla de refined que llenó hive
def comparar(propio, hive, llave, decimales):
    if hive is None:
        return "sin refined", ""
    hive = hive.select(*propio.columns)
    filas_p, filas_h = propio.count(), hive.count()
    if filas_p != filas_h:
        return "FALLA", f"{filas_p} filas contra {filas_h}"
    a, h = propio.alias("a"), hive.alias("h")
    unidas = a.join(h, [F.col(f"a.{k}").cast("string") == F.col(f"h.{k}").cast("string") for k in llave], "full")
    malas = F.lit(False)
    for columna in propio.columns:
        x, y = F.col(f"a.{columna}"), F.col(f"h.{columna}")
        if columna in decimales:
            tolerancia = 0.5 * 10 ** -decimales[columna] + 1e-9
            distinta = F.abs(x - y) > tolerancia
        else:
            distinta = x.cast("string") != y.cast("string")
        malas = malas | F.coalesce(distinta, x.isNull() != y.isNull())
    distintas = unidas.where(malas).count()
    return ("OK", "") if distintas == 0 else ("FALLA", f"{distintas} filas distintas")


def municipio_anual(b):
    clima_ano = (b["clima"].withColumn("ano", F.year("fecha")).where(F.col("ano").isin(ANOS))
                 .groupBy("cod_mpio", "ano")
                 .agg(F.round(F.avg("temperatura_media_c"), 1).alias("temperatura_media_c"),
                      F.round(F.sum("precipitacion_mm"), 1).alias("lluvia_anual_mm"),
                      F.round(F.avg("humedad_relativa_pct"), 1).alias("humedad_media_pct")))
    c = b["casos"]
    eventos = (c.groupBy("ano", "cod_mpio")
               .agg(F.sum(F.when(c.cod_evento == 220, c.conteo).otherwise(0)).alias("dengue_grave"),
                    F.sum(F.when(c.tipo_evento == "muerte", c.conteo).otherwise(0)).alias("muertes")))
    orden, nombre = rango_altitud("altitud_m")
    df = (b["pob_casos"]
          .join(eventos, ["ano", "cod_mpio"], "left")
          .join(b["municipios"].select("cod_mpio", "latitud", "longitud", "altitud_m"), "cod_mpio", "left")
          .join(clima_ano, ["cod_mpio", "ano"], "left")
          .withColumn("rango_altitud", F.when(F.col("altitud_m").isNotNull(), nombre))
          .withColumn("tasa", F.col("casos") * 100000 / F.col("poblacion")))
    return (df.withColumn("puesto_incidencia", puesto("tasa", "ano"))
            .select("ano", "cod_mpio", "municipio", "cod_dpto", "departamento",
                    "latitud", "longitud", "altitud_m", "rango_altitud", "poblacion", "casos",
                    *[F.coalesce(x, F.lit(0)).cast("bigint").alias(x) for x in ("dengue_grave", "muertes")],
                    F.round("tasa", 2).alias("incidencia_100k"), "puesto_incidencia",
                    "temperatura_media_c", "lluvia_anual_mm", "humedad_media_pct"))


def serie_semanal(b):
    c = b["casos"]
    return (c.groupBy("ano", "semana", "fecha_inicio_semana", "cod_dpto")
            .agg(F.sum(F.when(c.tipo_evento == "caso", c.conteo).otherwise(0)).cast("bigint").alias("casos"),
                 F.sum(F.when(c.cod_evento == 220, c.conteo).otherwise(0)).cast("bigint").alias("dengue_grave"),
                 F.sum(F.when(c.tipo_evento == "muerte", c.conteo).otherwise(0)).cast("bigint").alias("muertes"))
            .join(b["nombres"], "cod_dpto")
            .select("ano", F.col("semana").cast("int").alias("semana"), "fecha_inicio_semana",
                    "cod_dpto", "departamento", "casos", "dengue_grave", "muertes"))


def estadisticas(mpio):
    # mitad de los casos: cuántos municipios, de mayor a menor, suman el 50 %
    orden = Window.partitionBy("ano").orderBy(F.col("casos").desc(), "cod_mpio")
    acumulado = (mpio.withColumn("n", F.row_number().over(orden))
                 .withColumn("acumulado", F.sum("casos").over(orden.rowsBetween(Window.unboundedPreceding, 0)))
                 .withColumn("total", F.sum("casos").over(Window.partitionBy("ano"))))
    mitad = (acumulado.where(F.col("acumulado") * 2 >= F.col("total"))
             .groupBy("ano").agg(F.min("n").alias("municipios_mitad_casos")))
    decil = (acumulado.withColumn("top", F.col("n") <= F.ceil(F.count("*").over(Window.partitionBy("ano")) / 10))
             .groupBy("ano")
             .agg(F.round(F.sum(F.when(F.col("top"), F.col("casos")).otherwise(0)) * 100 / F.sum("casos"), 1)
                  .alias("pct_casos_10pct_municipios")))
    cuantiles = F.expr("percentile(incidencia_100k, array(0.25, 0.5, 0.75, 0.9))")
    resumen = (mpio.groupBy("ano")
               .agg(F.count("*").alias("municipios"),
                    F.sum(F.when(F.col("casos") > 0, 1).otherwise(0)).alias("municipios_con_casos"),
                    F.round(F.avg("incidencia_100k"), 2).alias("media"),
                    F.round(F.stddev("incidencia_100k"), 2).alias("desviacion"),
                    cuantiles.alias("q"),
                    F.max("incidencia_100k").alias("maximo")))
    return (resumen.join(mitad, "ano").join(decil, "ano")
            .select("ano", "municipios", "municipios_con_casos",
                    F.round(F.col("municipios_con_casos") * 100 / F.col("municipios"), 1)
                    .alias("pct_municipios_con_casos"),
                    "media", "desviacion",
                    *[F.round(F.col("q")[i], 2).alias(n) for i, n in enumerate(["p25", "mediana", "p75", "p90"])],
                    "maximo", "municipios_mitad_casos", "pct_casos_10pct_municipios")
            .orderBy("ano"))


def main():
    parser = argparse.ArgumentParser(description="análisis del dengue con pyspark")
    parser.add_argument("--datalake", help="bucket del datalake, para escribir en refined desde emr")
    parser.add_argument("--trusted", help="carpeta local con trusted en parquet, para probar sin emr")
    parser.add_argument("--refined", help="carpeta local con refined, para comparar sin emr")
    parser.add_argument("--salida", help="carpeta local donde escribir las tablas nuevas")
    args = parser.parse_args()
    if not args.datalake and not args.salida:
        parser.error("falta --datalake o --salida")

    spark = SparkSession.builder.appName("dengue-pyspark").enableHiveSupport().getOrCreate()
    spark.sparkContext.setLogLevel("WARN")
    datos = Datos(spark, args)
    b = bases(datos)

    preguntas = {
        "incidencia_departamento": p1_departamento,
        "incidencia_municipio": p1_municipio,
        "estacionalidad_departamento": p2_estacionalidad,
        "brote_2024_departamento": p3_brote,
        "clima_rezago": p4_clima,
        "gravedad_departamento": p5_gravedad,
        "incidencia_altitud": p6_altitud,
    }
    respuestas = {}
    for tabla, funcion in preguntas.items():
        respuestas[tabla] = funcion(b).cache()

    titulo("Pregunta 1: departamentos con mayor incidencia en 2024")
    mostrar(respuestas["incidencia_departamento"].where("ano = 2024").orderBy("puesto"), 5)
    titulo("Pregunta 2: semana pico de los departamentos con más casos en 2024")
    mostrar(respuestas["estacionalidad_departamento"].where("ano = 2024").orderBy(F.col("casos_ano").desc()), 5)
    titulo("Pregunta 3: departamentos que explican el brote de 2024")
    mostrar(respuestas["brote_2024_departamento"].orderBy("puesto"), 5)
    titulo("Pregunta 4: correlación del clima con la incidencia, por rezago")
    mostrar(respuestas["clima_rezago"])
    titulo("Pregunta 5: departamentos con mayor letalidad")
    mostrar(respuestas["gravedad_departamento"].orderBy("puesto_letalidad"), 5)
    titulo("Pregunta 6: incidencia por rango de altitud")
    mostrar(respuestas["incidencia_altitud"], 15)

    titulo("PySpark contra las tablas que llenó Hive en dengue_refined")
    fallas = 0
    for tabla, df in respuestas.items():
        llave, decimales = PREGUNTAS[tabla]
        estado, detalle = comparar(df, datos.refined(tabla), llave, decimales)
        fallas += estado == "FALLA"
        print(f"{estado:<7}{tabla:<30}{df.count():>6} filas  {detalle}".rstrip(), flush=True)

    mpio = municipio_anual(b).cache()
    nuevas = {
        "municipio_anual": mpio,
        "serie_semanal_departamento": serie_semanal(b),
        "estadisticas_incidencia": estadisticas(mpio),
    }

    titulo("Estadísticas de la incidencia municipal por año")
    mostrar(nuevas["estadisticas_incidencia"])
    titulo("Municipios de más de 100.000 habitantes con mayor incidencia en 2024")
    mostrar(mpio.where("ano = 2024 AND poblacion > 100000").orderBy(F.col("incidencia_100k").desc())
            .select("municipio", "departamento", "altitud_m", "poblacion", "casos", "incidencia_100k",
                    "temperatura_media_c", "lluvia_anual_mm"), 5)
    titulo("Semanas con más casos en el país")
    mostrar(nuevas["serie_semanal_departamento"].groupBy("ano", "semana", "fecha_inicio_semana")
            .agg(F.sum("casos").alias("casos")).orderBy(F.col("casos").desc()), 5)

    titulo("Tablas nuevas en refined")
    for tabla, df in nuevas.items():
        ruta = datos.escribir(df, tabla)
        print(f"{tabla:<28}{df.count():>6} filas  {ruta}", flush=True)

    spark.stop()
    print()
    if fallas:
        sys.exit(f"FALLA: {fallas} tablas no coinciden con las de Hive.")
    print("OK: PySpark da las mismas 7 respuestas que Hive y escribió 3 tablas nuevas en refined.")


if __name__ == "__main__":
    main()
