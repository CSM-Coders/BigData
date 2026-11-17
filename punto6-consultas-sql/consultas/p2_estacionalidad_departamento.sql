SELECT s.ano AS ano,
       s.cod_dpto AS cod_dpto,
       n.departamento AS departamento,
       s.semana AS semana_pico,
       s.fecha_inicio_semana AS inicio_semana_pico,
       s.casos AS casos_semana_pico,
       s.casos_ano AS casos_ano,
       round(CAST(s.casos AS DOUBLE) * 100 / s.casos_ano, 2) AS pct_del_ano
FROM (
  SELECT ano, cod_dpto, semana, fecha_inicio_semana, casos,
         sum(casos) OVER (PARTITION BY ano, cod_dpto) AS casos_ano,
         row_number() OVER (PARTITION BY ano, cod_dpto ORDER BY casos DESC, semana) AS orden
  FROM (
    SELECT CAST(ano AS INT) AS ano, cod_dpto, semana, fecha_inicio_semana,
           CAST(sum(conteo) AS BIGINT) AS casos
    FROM casos_dengue
    WHERE tipo_evento = 'caso'
    GROUP BY CAST(ano AS INT), cod_dpto, semana, fecha_inicio_semana
  ) w
) s
JOIN (
  SELECT cod_dpto, max(departamento) AS departamento
  FROM poblacion
  GROUP BY cod_dpto
) n ON n.cod_dpto = s.cod_dpto
WHERE s.orden = 1
ORDER BY ano DESC, casos_ano DESC
