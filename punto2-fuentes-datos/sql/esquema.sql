# tabla tal como la publica sivigila, los códigos sin cero se arreglan en el punto 4
CREATE DATABASE IF NOT EXISTS sivigila
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE sivigila;

CREATE TABLE IF NOT EXISTS eventos_dengue (
  cod_eve                 SMALLINT UNSIGNED  NOT NULL,
  nombre_evento           VARCHAR(60)        NOT NULL,
  semana                  TINYINT UNSIGNED   NOT NULL,
  ano                     SMALLINT UNSIGNED  NOT NULL,
  cod_dpto_o              TINYINT UNSIGNED   NOT NULL,
  cod_mun_o               MEDIUMINT UNSIGNED NOT NULL,
  departamento_ocurrencia VARCHAR(60)        NOT NULL,
  municipio_ocurrencia    VARCHAR(100)       NOT NULL,
  conteo                  INT UNSIGNED       NOT NULL,
  PRIMARY KEY (ano, semana, cod_mun_o, cod_eve)
);
