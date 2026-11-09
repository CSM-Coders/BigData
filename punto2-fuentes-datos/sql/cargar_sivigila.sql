# todo en una transacción, si falla no se pierde lo que había
# cod_mpio se ignora porque no viene de la fuente
USE sivigila;

START TRANSACTION;

DELETE FROM eventos_dengue;

LOAD DATA LOCAL INFILE 'sivigila_dengue.csv'
INTO TABLE eventos_dengue
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(cod_eve, nombre_evento, semana, ano, cod_dpto_o, cod_mun_o,
 departamento_ocurrencia, municipio_ocurrencia, conteo, @cod_mpio);

COMMIT;
