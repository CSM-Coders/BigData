ADD JAR ${hivevar:jar_json};
SET hive.cli.print.header=true;

CREATE DATABASE IF NOT EXISTS dengue_raw
COMMENT 'zona raw: los datos tal como llegan de las fuentes'
LOCATION 's3://${hivevar:datalake}/raw/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_raw.sivigila (
  cod_eve INT COMMENT '210 dengue, 220 dengue grave, 580 mortalidad',
  nombre_evento STRING,
  semana INT COMMENT 'semana epidemiológica',
  ano INT COMMENT 'año epidemiológico',
  cod_dpto_o INT COMMENT 'código sin el cero inicial',
  cod_mun_o INT COMMENT 'código sin el cero inicial',
  departamento_ocurrencia STRING,
  municipio_ocurrencia STRING,
  conteo INT
)
COMMENT 'exportación de la tabla eventos_dengue de rds'
PARTITIONED BY (fecha_ingesta STRING)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t'
STORED AS TEXTFILE
LOCATION 's3://${hivevar:datalake}/raw/sivigila/'
TBLPROPERTIES ('skip.header.line.count'='1');

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_raw.divipola (
  cod_dpto STRING,
  dpto STRING,
  cod_mpio STRING,
  nom_mpio STRING,
  tipo_municipio STRING,
  longitud STRING COMMENT 'con coma decimal',
  latitud STRING COMMENT 'con coma decimal'
)
COMMENT 'municipios de colombia, copiados desde la ec2'
PARTITIONED BY (fecha_ingesta STRING)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES ('separatorChar'=',', 'quoteChar'='"')
STORED AS TEXTFILE
LOCATION 's3://${hivevar:datalake}/raw/divipola/'
TBLPROPERTIES ('skip.header.line.count'='1');

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_raw.openmeteo_altitud (
  elevation ARRAY<DOUBLE> COMMENT 'altitud en metros'
)
COMMENT 'respuesta de la api de altitud, un archivo por municipio'
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS TEXTFILE
LOCATION 's3://${hivevar:datalake}/raw/openmeteo/altitud/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_raw.openmeteo_clima (
  latitude DOUBLE,
  longitude DOUBLE,
  elevation DOUBLE,
  timezone STRING,
  daily STRUCT<
    temperature_2m_mean:ARRAY<DOUBLE>,
    precipitation_sum:ARRAY<DOUBLE>,
    relative_humidity_2m_mean:ARRAY<DOUBLE>
  > COMMENT 'un valor por día desde 2021-11-01'
)
COMMENT 'respuesta de la api de clima histórico, un archivo por municipio'
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS TEXTFILE
LOCATION 's3://${hivevar:datalake}/raw/openmeteo/clima/';

MSCK REPAIR TABLE dengue_raw.sivigila;
MSCK REPAIR TABLE dengue_raw.divipola;

CREATE DATABASE IF NOT EXISTS dengue_refined
COMMENT 'zona refined: respuestas a las preguntas de negocio'
LOCATION 's3://${hivevar:datalake}/refined/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_refined.incidencia_departamento (
  ano INT,
  cod_dpto STRING,
  departamento STRING,
  casos BIGINT,
  poblacion BIGINT,
  incidencia_100k DOUBLE COMMENT 'casos por 100.000 habitantes',
  puesto INT COMMENT '1 es la mayor incidencia del año'
)
COMMENT 'pregunta 1: incidencia por departamento y año'
STORED AS PARQUET
LOCATION 's3://${hivevar:datalake}/refined/incidencia_departamento/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_refined.incidencia_municipio (
  ano INT,
  cod_mpio STRING,
  municipio STRING,
  cod_dpto STRING,
  departamento STRING,
  casos BIGINT,
  poblacion BIGINT,
  incidencia_100k DOUBLE COMMENT 'casos por 100.000 habitantes',
  puesto INT COMMENT '1 es la mayor incidencia del año'
)
COMMENT 'pregunta 1: incidencia por municipio y año'
STORED AS PARQUET
LOCATION 's3://${hivevar:datalake}/refined/incidencia_municipio/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_refined.estacionalidad_departamento (
  ano INT,
  cod_dpto STRING,
  departamento STRING,
  semana_pico INT COMMENT 'semana epidemiológica con más casos',
  inicio_semana_pico DATE,
  casos_semana_pico BIGINT,
  casos_ano BIGINT,
  pct_del_ano DOUBLE COMMENT 'parte de los casos del año que cayó en la semana pico'
)
COMMENT 'pregunta 2: semana pico de cada departamento y año'
STORED AS PARQUET
LOCATION 's3://${hivevar:datalake}/refined/estacionalidad_departamento/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_refined.brote_2024_departamento (
  cod_dpto STRING,
  departamento STRING,
  casos_2023 BIGINT,
  casos_2024 BIGINT,
  aumento BIGINT,
  pct_del_aumento DOUBLE COMMENT 'parte del aumento nacional que aporta el departamento',
  variacion_pct DOUBLE COMMENT 'cambio frente a 2023',
  puesto INT COMMENT '1 es el mayor aumento'
)
COMMENT 'pregunta 3: aporte de cada departamento al aumento de 2024'
STORED AS PARQUET
LOCATION 's3://${hivevar:datalake}/refined/brote_2024_departamento/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_refined.clima_rezago (
  rezago_semanas INT COMMENT 'semanas entre el clima y los casos',
  municipios BIGINT COMMENT 'municipios con clima que entran al promedio',
  corr_lluvia DOUBLE COMMENT 'correlación promedio con la lluvia semanal',
  corr_temperatura DOUBLE COMMENT 'correlación promedio con la temperatura media',
  corr_humedad DOUBLE COMMENT 'correlación promedio con la humedad relativa',
  pct_lluvia_positiva DOUBLE COMMENT 'municipios con correlación positiva, en porcentaje',
  pct_temperatura_positiva DOUBLE,
  pct_humedad_positiva DOUBLE
)
COMMENT 'pregunta 4: correlación entre el clima y la incidencia semanas después, dentro de cada municipio'
STORED AS PARQUET
LOCATION 's3://${hivevar:datalake}/refined/clima_rezago/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_refined.gravedad_departamento (
  cod_dpto STRING,
  departamento STRING,
  casos BIGINT,
  dengue_grave BIGINT,
  muertes BIGINT,
  pct_gravedad DOUBLE COMMENT 'dengue grave por cada 100 casos',
  letalidad_pct DOUBLE COMMENT 'muertes por cada 100 casos',
  puesto_gravedad INT,
  puesto_letalidad INT
)
COMMENT 'pregunta 5: gravedad y letalidad por departamento, 2022 a 2024'
STORED AS PARQUET
LOCATION 's3://${hivevar:datalake}/refined/gravedad_departamento/';

CREATE EXTERNAL TABLE IF NOT EXISTS dengue_refined.incidencia_altitud (
  ano INT,
  orden_rango INT,
  rango_altitud STRING,
  municipios BIGINT,
  poblacion BIGINT,
  casos BIGINT,
  incidencia_100k DOUBLE COMMENT 'casos por 100.000 habitantes'
)
COMMENT 'pregunta 6: incidencia por rango de altitud del municipio'
STORED AS PARQUET
LOCATION 's3://${hivevar:datalake}/refined/incidencia_altitud/';

SHOW DATABASES;
SHOW TABLES IN dengue_trusted;
SHOW TABLES IN dengue_raw;
SHOW TABLES IN dengue_refined;
DESCRIBE dengue_trusted.casos_dengue;
SHOW PARTITIONS dengue_raw.sivigila;

SELECT fecha_ingesta, count(*) AS filas_sivigila
FROM dengue_raw.sivigila
GROUP BY fecha_ingesta
ORDER BY fecha_ingesta;

SELECT fecha_ingesta, count(*) AS filas_divipola
FROM dengue_raw.divipola
GROUP BY fecha_ingesta
ORDER BY fecha_ingesta;

SELECT count(*) AS municipios_altitud, min(elevation[0]) AS altitud_min, max(elevation[0]) AS altitud_max
FROM dengue_raw.openmeteo_altitud;

SELECT count(*) AS municipios_clima, sum(size(daily.temperature_2m_mean)) AS dias_clima
FROM dengue_raw.openmeteo_clima;

SELECT count(*) AS filas_casos_trusted, sum(conteo) AS conteo_trusted
FROM dengue_trusted.casos_dengue;
