SELECT ano, cod_mpio, municipio, cod_dpto, departamento, casos, poblacion,
       round(tasa, 2) AS incidencia_100k,
       CAST(puesto AS INT) AS puesto
FROM (
  SELECT ano, cod_mpio, municipio, cod_dpto, departamento, casos, poblacion, tasa,
         rank() OVER (PARTITION BY ano ORDER BY tasa DESC) AS puesto
  FROM (
    SELECT p.ano AS ano,
           p.cod_mpio AS cod_mpio,
           p.municipio AS municipio,
           p.cod_dpto AS cod_dpto,
           p.departamento AS departamento,
           CAST(coalesce(c.casos, 0) AS BIGINT) AS casos,
           CAST(p.poblacion AS BIGINT) AS poblacion,
           CAST(coalesce(c.casos, 0) AS DOUBLE) * 100000 / p.poblacion AS tasa
    FROM poblacion p
    LEFT JOIN (
      SELECT CAST(ano AS INT) AS ano, cod_mpio, sum(conteo) AS casos
      FROM casos_dengue
      WHERE tipo_evento = 'caso'
      GROUP BY CAST(ano AS INT), cod_mpio
    ) c ON c.cod_mpio = p.cod_mpio AND c.ano = p.ano
    WHERE p.ano BETWEEN 2022 AND 2024
  ) m
) r
ORDER BY ano DESC, puesto
