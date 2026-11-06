# Punto 1: Caso de estudio

## Dengue y clima en Colombia, 2022 a 2024

El dengue es una enfermedad transmitida por mosquitos que depende del clima y de la altitud. Entre 2022 y 2024 los casos notificados en Colombia pasaron de 67.031 a 312.643 por año.

Este proyecto se plantea desde la mirada de una secretaría de salud que debe decidir dónde y cuándo reforzar la prevención. Para eso cruza los casos notificados con la población y el clima de cada municipio.

## Fuentes de datos

| Fuente exigida | Dataset | Publicado por | Contenido |
|---|---|---|---|
| Base de datos (RDS MariaDB) | [SIVIGILA](https://www.datos.gov.co/resource/wns8-p38i.json), eventos 210, 220 y 580 | Instituto Nacional de Salud | 61.234 filas de casos por municipio y semana epidemiológica |
| Archivos (EC2) | [Proyecciones de población municipal 2018-2042](https://www.dane.gov.co/index.php/estadisticas-por-tema/demografia-y-poblacion/proyecciones-de-poblacion) | DANE | Población de 1.123 municipios por año, en `.xlsx` |
| Archivos (EC2) | [DIVIPOLA](https://www.datos.gov.co/resource/gdxc-w37w.json) | datos.gov.co | 1.122 municipios con latitud y longitud |
| URL en Internet | [API histórica](https://archive-api.open-meteo.com/v1/archive) y [API de altitud](https://api.open-meteo.com/v1/elevation) | Open-Meteo | Temperatura, lluvia y humedad diarias, y altitud |

Los datos de SIVIGILA se cargarán en MariaDB y los archivos se copiarán a EC2 en el Punto 2, para simular fuentes propias de una organización.

## Definiciones

| Término | Definición |
|---|---|
| Casos | Eventos 210 (dengue) + 220 (dengue grave) |
| Muertes | Evento 580 (mortalidad por dengue). Se mide aparte para no contar dos veces a una persona |
| Incidencia | Casos / población total del año × 100.000 |
| Proporción de gravedad | Evento 220 / casos × 100 |
| Letalidad | Evento 580 / casos × 100 |
| Municipio | Municipio de ocurrencia, con código DIVIPOLA de 5 dígitos |
| Semana epidemiológica | De domingo a sábado. La semana 1 es la primera con al menos 4 días dentro del año |

## Preguntas de negocio

1. **Incidencia:** ¿qué departamentos y municipios tuvieron la mayor incidencia cada año?
2. **Estacionalidad:** ¿en qué semanas epidemiológicas se concentra el pico de casos en cada departamento?
3. **Brote de 2024:** ¿qué departamentos explican el aumento de casos de 2024 frente a 2023?
4. **Clima:** ¿cómo se relacionan la lluvia y la temperatura con los casos 2, 4, 6 y 8 semanas después?
5. **Gravedad:** ¿qué departamentos tienen la mayor proporción de gravedad y la mayor letalidad?
6. **Altitud:** ¿cómo cambia la incidencia entre rangos de altitud del municipio?

Estas preguntas seran refinadas medida que avance el proyecto.

## Resultados del perfilado

`explorar_fuentes.py` descarga las fuentes y comprueba que se pueden cruzar. El detalle está en [`resultados/perfil_fuentes.md`](resultados/perfil_fuentes.md).

| Año | Dengue | Dengue grave | Casos | Muertes |
|---|---:|---:|---:|---:|
| 2022 | 65.691 | 1.340 | 67.031 | 85 |
| 2023 | 126.411 | 1.721 | 128.132 | 118 |
| 2024 | 309.627 | 3.016 | 312.643 | 284 |
| **Total** | **501.729** | **6.077** | **507.806** | **487** |

[`resultados/valores_control.json`](resultados/valores_control.json) guarda estas cifras para comparar los resultados de Athena, Hive y Spark en los puntos siguientes. Como referencia, el departamento con mayor incidencia en 2024 fue Valle del Cauca, con 1.890,7 casos por 100.000 habitantes.

SIVIGILA se sigue actualizando, así que una extracción posterior puede dar cifras algo distintas. Las de este documento son del 2026-11-06 (UTC).

## Problemas de calidad encontrados

Estos problemas se corrigen en el Punto 4, al pasar de raw a trusted.

| Problema | Alcance | Tratamiento |
|---|---|---|
| El código de municipio se guarda como número y pierde el cero inicial (`5001` en vez de `05001`) | 7.307 filas, de Antioquia (`05`), Atlántico (`08`) y exterior (`01`) | Rellenar con ceros hasta 5 dígitos |
| Casos registrados como `EXTERIOR_*`, con códigos que no son municipios | 1.012 casos | Excluirlos de los análisis por municipio y departamento |
| Belén de Bajirá (`27086`) no aparece en el DANE ni en DIVIPOLA | 73 casos | Excluirlo de la incidencia, por falta de población |
| `94663` aparece en el DANE pero no en DIVIPOLA | Sin efecto en los casos | Ninguno |
| DIVIPOLA usa coma decimal en las coordenadas | Todas las filas | Convertir a número |
| La población trae tres filas por municipio y año | Todas las filas | Usar solo el área `Total` |

En total, 1.085 casos (0,21 %) no cruzan con la población. No se encontraron duplicados por año, semana, municipio y evento.

## Decisiones de diseño

- **Clima para 300 municipios:** son los que tienen más casos y cubren el 89,4 % del total. La lista está en [`resultados/municipios_clima_top300.csv`](resultados/municipios_clima_top300.csv).
- **Altitud para todos los municipios:** si la pregunta 6 usara solo los 300 con más casos, quedarían por fuera los municipios altos, que tienen pocos casos, y el resultado saldría sesgado.
- **Clima desde 2021-11-01:** la pregunta 4 mira hasta 8 semanas atrás, y las primeras semanas de 2022 necesitan el clima de finales de 2021.
- **Fechas de las semanas:** para cruzar con el clima diario se convierte cada semana epidemiológica a fechas. La semana 1 empezó el 2022-01-02, el 2023-01-01 y el 2023-12-31. La regla coincide con un [boletín del INS](https://www.ins.gov.co/buscador-eventos/BoletinEpidemiologico/2024_Bolet%C3%ADn_epidemiologico_semana_15.pdf) que ubica la semana 15 de 2024 entre el 7 y el 13 de abril.
- **Límite de Open-Meteo:** la API respondió `429` al consultar la altitud de los 1.122 municipios, porque su límite por minuto cuenta cada coordenada. La ingesta del Punto 3 debe hacer esperas y reintentos.

## Limitaciones

- Solo hay datos de 2022 a 2024, así que la comparación entre años es corta y 2024 fue un año atípico.
- SIVIGILA registra casos notificados, no todos los casos reales. Las diferencias entre territorios pueden reflejar también distintos niveles de notificación.
- La pregunta 4 mide asociación, no causalidad, y aplica solo a los 300 municipios con más casos.
- El clima y la altitud corresponden a un solo punto por municipio, no a todo su territorio.

## Cómo reproducirlo

Desde la raíz del repositorio:

```bash
python3 -m venv .venv
```

```bash
source .venv/bin/activate
```

```bash
pip install -r requirements.txt
```

```bash
python punto1-caso-estudio/explorar_fuentes.py
```

Tarda entre 1 y 3 minutos la primera vez, según las esperas de Open-Meteo. No se necesita una cuenta de AWS. Los datos quedan en `punto1-caso-estudio/datos/`,este no se sube a GitHub, y los resultados en `punto1-caso-estudio/resultados/`.

## Evidencias

- `01a-ejecucion-casos.png`: terminal con el comando, las descargas y los casos por año.
- `01b-cruce-codigos.png`: terminal con el cruce de códigos de municipio.
- `01c-incidencia-clima.png`: terminal con la incidencia, las semanas pico y el clima.
- `02-sivigila.png`: página del dataset SIVIGILA en datos.gov.co.
- `03-dane.png`: página de proyecciones de población del DANE.
- `04-open-meteo.png`: respuesta de la API de clima en el navegador.
