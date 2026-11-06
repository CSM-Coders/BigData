# Proyecto 2 de Big Data: dengue y clima en Colombia


## Integrantes

- Samuel Calderón
- Matías Monsalve
- Camilo Álvarez

## Descripción

Datalake en AWS que cruza los casos de dengue notificados en Colombia entre 2022 y 2024 con la población y el clima de cada municipio. El objetivo es responder seis preguntas de negocio sobre dónde y cuándo se concentra la enfermedad. El caso de estudio completo está en [`punto1-caso-estudio`](punto1-caso-estudio/README.md).

## Arquitectura

La ingesta y las herramientas de cada etapa se confirman en el punto correspondiente.

```mermaid
flowchart LR
    RDS[(RDS MariaDB<br/>casos SIVIGILA)] --> RAW
    EC2[EC2<br/>población y DIVIPOLA] --> RAW
    API[Open-Meteo<br/>clima y altitud] --> RAW
    subgraph S3[Datalake S3]
        RAW[raw] --> TRUSTED[trusted] --> REFINED[refined]
    end
    TRUSTED --> CAT[Catálogo<br/>Glue y Hive]
    REFINED --> CAT
    CAT --> SQL[Athena, Hive<br/>y SparkSQL]
    CAT --> SPARK[PySpark]
    SQL --> APP[Visualización y Streamlit<br/>por API Gateway]
    SPARK --> APP
```

## Reproducción

Cada carpeta explica cómo reproducir su punto. Se deben seguir en orden, del 1 al 8. Desde el Punto 2 se necesita una cuenta de AWS, y el proyecto se desarrolla en AWS Academy Learner Lab en la región `us-east-1`.

