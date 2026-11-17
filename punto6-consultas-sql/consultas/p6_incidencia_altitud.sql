SELECT ano, orden_rango, rango_altitud, municipios, poblacion, casos,
       round(CAST(casos AS DOUBLE) * 100000 / poblacion, 2) AS incidencia_100k
FROM (
  SELECT a.ano AS ano,
         a.orden_rango AS orden_rango,
         a.rango_altitud AS rango_altitud,
         CAST(count(*) AS BIGINT) AS municipios,
         CAST(sum(a.poblacion) AS BIGINT) AS poblacion,
         CAST(sum(a.casos) AS BIGINT) AS casos
  FROM (
    SELECT p.ano AS ano,
           p.poblacion AS poblacion,
           coalesce(c.casos, 0) AS casos,
           CASE WHEN m.altitud_m < 500 THEN 1
                WHEN m.altitud_m < 1000 THEN 2
                WHEN m.altitud_m < 1500 THEN 3
                WHEN m.altitud_m < 2000 THEN 4
                ELSE 5 END AS orden_rango,
           CASE WHEN m.altitud_m < 500 THEN 'menos de 500 m'
                WHEN m.altitud_m < 1000 THEN '500 a 999 m'
                WHEN m.altitud_m < 1500 THEN '1.000 a 1.499 m'
                WHEN m.altitud_m < 2000 THEN '1.500 a 1.999 m'
                ELSE '2.000 m o más' END AS rango_altitud
    FROM municipios m
    JOIN poblacion p ON p.cod_mpio = m.cod_mpio
    LEFT JOIN (
      SELECT CAST(ano AS INT) AS ano, cod_mpio, sum(conteo) AS casos
      FROM casos_dengue
      WHERE tipo_evento = 'caso'
      GROUP BY CAST(ano AS INT), cod_mpio
    ) c ON c.cod_mpio = p.cod_mpio AND c.ano = p.ano
    WHERE p.ano BETWEEN 2022 AND 2024
  ) a
  GROUP BY a.ano, a.orden_rango, a.rango_altitud
) r
ORDER BY ano DESC, orden_rango
