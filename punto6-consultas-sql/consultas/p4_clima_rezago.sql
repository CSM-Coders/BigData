SELECT rezago_semanas,
       CAST(count(*) AS BIGINT) AS municipios,
       round(avg(corr_lluvia), 4) AS corr_lluvia,
       round(avg(corr_temperatura), 4) AS corr_temperatura,
       round(avg(corr_humedad), 4) AS corr_humedad,
       round(avg(CASE WHEN corr_lluvia > 0 THEN 100 ELSE 0 END), 1) AS pct_lluvia_positiva,
       round(avg(CASE WHEN corr_temperatura > 0 THEN 100 ELSE 0 END), 1) AS pct_temperatura_positiva,
       round(avg(CASE WHEN corr_humedad > 0 THEN 100 ELSE 0 END), 1) AS pct_humedad_positiva
FROM (
  SELECT r.rezago_semanas AS rezago_semanas,
         b.cod_mpio AS cod_mpio,
         corr(b.incidencia, CASE r.rezago_semanas WHEN 2 THEN b.lluvia_2 WHEN 4 THEN b.lluvia_4
                                                  WHEN 6 THEN b.lluvia_6 ELSE b.lluvia_8 END) AS corr_lluvia,
         corr(b.incidencia, CASE r.rezago_semanas WHEN 2 THEN b.temperatura_2 WHEN 4 THEN b.temperatura_4
                                                  WHEN 6 THEN b.temperatura_6 ELSE b.temperatura_8 END) AS corr_temperatura,
         corr(b.incidencia, CASE r.rezago_semanas WHEN 2 THEN b.humedad_2 WHEN 4 THEN b.humedad_4
                                                  WHEN 6 THEN b.humedad_6 ELSE b.humedad_8 END) AS corr_humedad
  FROM (
    SELECT w.cod_mpio AS cod_mpio,
           w.ano_epi AS ano_epi,
           w.semana_epi AS semana_epi,
           CAST(coalesce(c.casos, 0) AS DOUBLE) * 100000 / p.poblacion AS incidencia,
           w.lluvia_2 AS lluvia_2, w.lluvia_4 AS lluvia_4, w.lluvia_6 AS lluvia_6, w.lluvia_8 AS lluvia_8,
           w.temperatura_2 AS temperatura_2, w.temperatura_4 AS temperatura_4, w.temperatura_6 AS temperatura_6, w.temperatura_8 AS temperatura_8,
           w.humedad_2 AS humedad_2, w.humedad_4 AS humedad_4, w.humedad_6 AS humedad_6, w.humedad_8 AS humedad_8
    FROM (
      SELECT cod_mpio, ano_epi, semana_epi,
             lag(lluvia_mm, 2) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS lluvia_2,
             lag(lluvia_mm, 4) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS lluvia_4,
             lag(lluvia_mm, 6) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS lluvia_6,
             lag(lluvia_mm, 8) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS lluvia_8,
             lag(temperatura_c, 2) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS temperatura_2,
             lag(temperatura_c, 4) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS temperatura_4,
             lag(temperatura_c, 6) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS temperatura_6,
             lag(temperatura_c, 8) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS temperatura_8,
             lag(humedad_pct, 2) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS humedad_2,
             lag(humedad_pct, 4) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS humedad_4,
             lag(humedad_pct, 6) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS humedad_6,
             lag(humedad_pct, 8) OVER (PARTITION BY cod_mpio ORDER BY ano_epi, semana_epi) AS humedad_8
      FROM (
        SELECT cod_mpio, ano_epi, semana_epi,
               sum(precipitacion_mm) AS lluvia_mm,
               avg(temperatura_media_c) AS temperatura_c,
               avg(humedad_relativa_pct) AS humedad_pct
        FROM clima_diario
        GROUP BY cod_mpio, ano_epi, semana_epi
      ) s
    ) w
    JOIN poblacion p ON p.cod_mpio = w.cod_mpio AND p.ano = w.ano_epi
    LEFT JOIN (
      SELECT CAST(ano AS INT) AS ano, semana, cod_mpio, sum(conteo) AS casos
      FROM casos_dengue
      WHERE tipo_evento = 'caso'
      GROUP BY CAST(ano AS INT), semana, cod_mpio
    ) c ON c.cod_mpio = w.cod_mpio AND c.ano = w.ano_epi AND c.semana = w.semana_epi
    WHERE w.ano_epi BETWEEN 2022 AND 2024
  ) b
  CROSS JOIN (
    SELECT 2 AS rezago_semanas
    UNION ALL SELECT 4 AS rezago_semanas
    UNION ALL SELECT 6 AS rezago_semanas
    UNION ALL SELECT 8 AS rezago_semanas
  ) r
  GROUP BY r.rezago_semanas, b.cod_mpio
  HAVING max(b.incidencia) > min(b.incidencia)
) m
GROUP BY rezago_semanas
ORDER BY rezago_semanas
