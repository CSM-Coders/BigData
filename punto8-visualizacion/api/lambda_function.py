# api de solo lectura sobre dengue_refined, api gateway llama esta lambda y ella consulta athena
import json
import os
import re
import time

import boto3

BASE = os.environ.get("BASE", "dengue_refined")
SALIDA = os.environ.get("SALIDA", "")
GRUPO = os.environ.get("GRUPO", "primary")
# athena reusa el resultado de una consulta igual hecha en la última hora
REUSO_MIN = int(os.environ.get("REUSO_MIN", "60"))
ESPERA_MAX_S = 25

# nombre: descripción, orden y filtros que acepta
TABLAS = {
    "incidencia_departamento": ("Pregunta 1: incidencia por departamento y año",
                                "ano DESC, puesto", ["ano", "cod_dpto"]),
    "incidencia_municipio": ("Pregunta 1: incidencia por municipio y año",
                             "ano DESC, puesto", ["ano", "cod_dpto", "cod_mpio"]),
    "estacionalidad_departamento": ("Pregunta 2: semana pico por departamento y año",
                                    "ano DESC, casos_ano DESC", ["ano", "cod_dpto"]),
    "brote_2024_departamento": ("Pregunta 3: aumento de casos de 2024 frente a 2023",
                                "puesto", ["cod_dpto"]),
    "clima_rezago": ("Pregunta 4: correlación del clima con la incidencia, por rezago",
                     "rezago_semanas", []),
    "gravedad_departamento": ("Pregunta 5: gravedad y letalidad por departamento",
                              "puesto_letalidad", ["cod_dpto"]),
    "incidencia_altitud": ("Pregunta 6: incidencia por rango de altitud",
                           "ano DESC, orden_rango", ["ano"]),
    "municipio_anual": ("Punto 7: resumen por municipio y año",
                        "ano DESC, puesto_incidencia", ["ano", "cod_dpto", "cod_mpio"]),
    "serie_semanal_departamento": ("Punto 7: casos por departamento y semana epidemiológica",
                                   "ano, semana, cod_dpto", ["ano", "cod_dpto"]),
    "estadisticas_incidencia": ("Punto 7: distribución de la incidencia municipal por año",
                                "ano", ["ano"]),
}

# cada filtro se valida con su patrón antes de ir al sql, así no se puede inyectar nada
FILTROS = {
    "ano": (r"20\d\d", lambda v: v),
    "cod_dpto": (r"\d{2}", lambda v: f"'{v}'"),
    "cod_mpio": (r"\d{5}", lambda v: f"'{v}'"),
}
LIMITE_MAX = 10000
ENTEROS = {"tinyint", "smallint", "integer", "int", "bigint"}
DECIMALES = {"double", "float", "real", "decimal"}

athena = boto3.client("athena")


def respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {"content-type": "application/json; charset=utf-8"},
        "body": json.dumps(cuerpo, ensure_ascii=False),
    }


def armar_sql(tabla, parametros):
    _, orden, permitidos = TABLAS[tabla]
    condiciones, usados = [], {}
    for nombre, valor in parametros.items():
        if nombre == "limite":
            continue
        if nombre not in permitidos:
            raise ValueError(f"{tabla} no acepta el filtro {nombre}, acepta: {', '.join(permitidos) or 'ninguno'}")
        patron, literal = FILTROS[nombre]
        if not re.fullmatch(patron, valor):
            raise ValueError(f"valor inválido para {nombre}: {valor}")
        condiciones.append(f"{nombre} = {literal(valor)}")
        usados[nombre] = valor
    limite = parametros.get("limite", str(LIMITE_MAX))
    if not limite.isdigit() or not 0 < int(limite) <= LIMITE_MAX:
        raise ValueError(f"limite debe ser un número entre 1 y {LIMITE_MAX}")
    donde = f" WHERE {' AND '.join(condiciones)}" if condiciones else ""
    return f"SELECT * FROM {tabla}{donde} ORDER BY {orden} LIMIT {int(limite)}", usados


def ejecutar(sql):
    pedido = {
        "QueryString": sql,
        "QueryExecutionContext": {"Database": BASE},
        "WorkGroup": GRUPO,
        "ResultReuseConfiguration": {
            "ResultReuseByAgeConfiguration": {"Enabled": True, "MaxAgeInMinutes": REUSO_MIN}},
    }
    if SALIDA:
        pedido["ResultConfiguration"] = {"OutputLocation": SALIDA}
    id_consulta = athena.start_query_execution(**pedido)["QueryExecutionId"]

    inicio = time.time()
    while True:
        ejecucion = athena.get_query_execution(QueryExecutionId=id_consulta)["QueryExecution"]
        estado = ejecucion["Status"]["State"]
        if estado == "SUCCEEDED":
            break
        if estado in ("FAILED", "CANCELLED"):
            raise RuntimeError(ejecucion["Status"].get("StateChangeReason", estado))
        if time.time() - inicio > ESPERA_MAX_S:
            raise TimeoutError("Athena tardó demasiado")
        time.sleep(0.25)

    columnas, filas = None, []
    for pagina in athena.get_paginator("get_query_results").paginate(QueryExecutionId=id_consulta):
        if columnas is None:
            columnas = [(c["Name"], c["Type"]) for c in pagina["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]]
            datos = pagina["ResultSet"]["Rows"][1:]
        else:
            datos = pagina["ResultSet"]["Rows"]
        for fila in datos:
            valores = [c.get("VarCharValue") for c in fila["Data"]]
            filas.append({n: convertir(v, t) for (n, t), v in zip(columnas, valores)})
    reusada = ejecucion.get("Statistics", {}).get("ResultReuseInformation", {}).get("ReusedPreviousResult", False)
    return [n for n, _ in columnas], filas, id_consulta, reusada


# athena devuelve todo como texto, se convierte según el tipo de la columna
def convertir(valor, tipo):
    if valor is None:
        return None
    if tipo in ENTEROS:
        return int(valor)
    if tipo in DECIMALES:
        return float(valor)
    return valor


def indice():
    return {
        "api": "dengue en colombia, 2022 a 2024",
        "base": BASE,
        "uso": "GET /tablas/{tabla}?filtro=valor&limite=n",
        "ejemplo": "/tablas/incidencia_departamento?ano=2024&limite=5",
        "tablas": [{"tabla": t, "descripcion": d, "filtros": f, "ruta": f"/tablas/{t}"}
                   for t, (d, _, f) in TABLAS.items()],
    }


def handler(event, context):
    metodo = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    ruta = event.get("rawPath", "/").rstrip("/") or "/"
    parametros = event.get("queryStringParameters") or {}
    if metodo != "GET":
        return respuesta(405, {"error": "solo se permite GET"})
    if ruta == "/":
        return respuesta(200, indice())

    partes = ruta.strip("/").split("/")
    if len(partes) != 2 or partes[0] != "tablas":
        return respuesta(404, {"error": f"ruta desconocida: {ruta}", "ayuda": "GET /"})
    tabla = partes[1]
    if tabla not in TABLAS:
        return respuesta(404, {"error": f"tabla desconocida: {tabla}", "tablas": list(TABLAS)})

    try:
        sql, usados = armar_sql(tabla, parametros)
    except ValueError as error:
        return respuesta(400, {"error": str(error)})

    inicio = time.time()
    try:
        columnas, filas, id_consulta, reusada = ejecutar(sql)
    except (RuntimeError, TimeoutError) as error:
        return respuesta(502, {"error": f"Athena: {error}"})
    return respuesta(200, {
        "tabla": tabla,
        "descripcion": TABLAS[tabla][0],
        "filtros": usados,
        "filas": len(filas),
        "columnas": columnas,
        "segundos": round(time.time() - inicio, 2),
        "athena": {"id": id_consulta, "resultado_reusado": reusada},
        "datos": filas,
    })
