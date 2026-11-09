USE sivigila;

SELECT ano, cod_eve, nombre_evento, COUNT(*) AS filas, SUM(conteo) AS total
FROM eventos_dengue
GROUP BY ano, cod_eve, nombre_evento
ORDER BY ano, cod_eve;

SELECT COUNT(*) AS filas,
       COUNT(DISTINCT cod_mun_o) AS municipios,
       MIN(ano) AS primer_ano,
       MAX(ano) AS ultimo_ano
FROM eventos_dengue;
