SELECT cod_dpto, departamento, casos, dengue_grave, muertes,
       round(gravedad, 2) AS pct_gravedad,
       round(letalidad, 3) AS letalidad_pct,
       CAST(puesto_gravedad AS INT) AS puesto_gravedad,
       CAST(puesto_letalidad AS INT) AS puesto_letalidad
FROM (
  SELECT cod_dpto, departamento, casos, dengue_grave, muertes, gravedad, letalidad,
         rank() OVER (ORDER BY gravedad DESC) AS puesto_gravedad,
         rank() OVER (ORDER BY letalidad DESC) AS puesto_letalidad
  FROM (
    SELECT cod_dpto, departamento, casos, dengue_grave, muertes,
           CAST(dengue_grave AS DOUBLE) * 100 / casos AS gravedad,
           CAST(muertes AS DOUBLE) * 100 / casos AS letalidad
    FROM (
      SELECT c.cod_dpto AS cod_dpto,
             n.departamento AS departamento,
             CAST(sum(CASE WHEN c.tipo_evento = 'caso' THEN c.conteo ELSE 0 END) AS BIGINT) AS casos,
             CAST(sum(CASE WHEN c.cod_evento = 220 THEN c.conteo ELSE 0 END) AS BIGINT) AS dengue_grave,
             CAST(sum(CASE WHEN c.tipo_evento = 'muerte' THEN c.conteo ELSE 0 END) AS BIGINT) AS muertes
      FROM casos_dengue c
      JOIN (
        SELECT cod_dpto, max(departamento) AS departamento
        FROM poblacion
        GROUP BY cod_dpto
      ) n ON n.cod_dpto = c.cod_dpto
      GROUP BY c.cod_dpto, n.departamento
    ) g
    WHERE casos > 0
  ) t
) r
ORDER BY puesto_letalidad, puesto_gravedad
