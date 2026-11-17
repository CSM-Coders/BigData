SELECT cod_dpto, departamento, casos_2023, casos_2024, aumento,
       round(CAST(aumento AS DOUBLE) * 100 / aumento_nacional, 2) AS pct_del_aumento,
       CASE WHEN casos_2023 > 0
            THEN round(CAST(aumento AS DOUBLE) * 100 / casos_2023, 2)
       END AS variacion_pct,
       CAST(puesto AS INT) AS puesto
FROM (
  SELECT cod_dpto, departamento, casos_2023, casos_2024, aumento,
         sum(aumento) OVER () AS aumento_nacional,
         rank() OVER (ORDER BY aumento DESC) AS puesto
  FROM (
    SELECT c.cod_dpto AS cod_dpto,
           n.departamento AS departamento,
           CAST(sum(CASE WHEN c.ano = 2023 THEN c.conteo ELSE 0 END) AS BIGINT) AS casos_2023,
           CAST(sum(CASE WHEN c.ano = 2024 THEN c.conteo ELSE 0 END) AS BIGINT) AS casos_2024,
           CAST(sum(CASE WHEN c.ano = 2024 THEN c.conteo
                         WHEN c.ano = 2023 THEN 0 - c.conteo
                         ELSE 0 END) AS BIGINT) AS aumento
    FROM (
      SELECT CAST(ano AS INT) AS ano, cod_dpto, conteo
      FROM casos_dengue
      WHERE tipo_evento = 'caso'
    ) c
    JOIN (
      SELECT cod_dpto, max(departamento) AS departamento
      FROM poblacion
      GROUP BY cod_dpto
    ) n ON n.cod_dpto = c.cod_dpto
    GROUP BY c.cod_dpto, n.departamento
  ) b
) r
ORDER BY puesto
