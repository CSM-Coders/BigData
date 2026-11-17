#!/usr/bin/env python3
# muestra una respuesta de la api como tabla, la lee de la entrada estándar
import json
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
d = json.load(sys.stdin)

if "datos" in d:
    reusado = d["athena"]["resultado_reusado"]
    print(f"{d['descripcion']}, filtros {d['filtros']}: {d['filas']} filas en {d['segundos']} s, "
          f"resultado reusado de Athena: {'sí' if reusado else 'no'}")
    filas = [[str(f[c]) for c in d["columnas"]] for f in d["datos"][:n]]
    anchos = [max(len(x) for x in columna) for columna in zip(d["columnas"], *filas)]
    for fila in [d["columnas"]] + filas:
        print("  ".join(v.ljust(a) for v, a in zip(fila, anchos)).rstrip())
elif d.get("tablas") and isinstance(d["tablas"][0], dict):
    print(d["uso"])
    for t in d["tablas"]:
        print(f"  {t['ruta']:<40}{t['descripcion']}")
elif "error" in d:
    print(f"error: {d['error']}")
else:
    print(json.dumps(d, ensure_ascii=False)[:300])
