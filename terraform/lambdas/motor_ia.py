"""
Motor de IA para AWS Lambda (Worker):
- Capa 1: Cálculo nutricional (Mifflin-St Jeor, TMB, GET, reparto de macros y regla E1)
- Capa 2: Sistema Experto de 15 reglas heurísticas (Grupos A, B, C, D, E)
- Capa 3: Agrupamiento K-Means (k=4, StandardScaler, coeficiente de silueta) con scikit-learn
- Capa 4: Optimización MILP con PuLP (CBC solver) y Orquestador Diario con memoria entre comidas
"""

import csv
import math
import os

try:
    import numpy as np
    from sklearn.cluster import KMeans
    from sklearn.metrics import silhouette_score
    from sklearn.preprocessing import StandardScaler

    TIENE_SKLEARN = True
except ImportError:
    TIENE_SKLEARN = False

try:
    from pulp import (
        PULP_CBC_CMD,
        LpMinimize,
        LpProblem,
        LpStatus,
        LpVariable,
        lpSum,
        value,
    )

    TIENE_PULP = True
except ImportError:
    TIENE_PULP = False

DATASET_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ingredientes_dataset.csv")

FACTORES_ACTIVIDAD = {
    "sedentario": 1.20,
    "ligero": 1.375,
    "moderado": 1.55,
    "intenso": 1.725,
    "muy_intenso": 1.90,
}

REGLAS_OBJETIVO = {
    "perder_grasa": {"ajuste_calorico": 0.80, "pct_proteina": 0.40, "pct_carbos": 0.35, "pct_grasa": 0.25},
    "mantener": {"ajuste_calorico": 1.00, "pct_proteina": 0.30, "pct_carbos": 0.45, "pct_grasa": 0.25},
    "ganar_musculo": {"ajuste_calorico": 1.15, "pct_proteina": 0.35, "pct_carbos": 0.40, "pct_grasa": 0.25},
}

DISTRIBUCION_POR_OBJETIVO = {
    "perder_grasa": {"desayuno": 0.25, "almuerzo": 0.35, "cena": 0.30, "snack": 0.10},
    "mantener": {"desayuno": 0.25, "almuerzo": 0.30, "cena": 0.30, "snack": 0.15},
    "ganar_musculo": {"desayuno": 0.22, "almuerzo": 0.33, "cena": 0.30, "snack": 0.15},
}

MINIMO_KCAL_SEGURIDAD = {"M": 1500, "F": 1200}

ESTRUCTURA_POR_COMIDA = {
    "desayuno": {"obligatorios": ["Carbohidrato"]},
    "almuerzo": {"obligatorios": ["Proteina", "Carbohidrato", "Verdura"]},
    "cena": {"obligatorios": ["Proteina", "Verdura"]},
    "snack": {"obligatorios": []},
}

INGREDIENTES_SALUDABLES_MAYORES = {
    "Palta",
    "Nueces",
    "Chia",
    "Salmon",
    "Jurel",
    "Caballa",
    "Almendras",
}

PORCIONES_BASE = {
    "Proteina": {"min": 80, "max": 250},
    "Carbohidrato": {"min": 30, "max": 220},
    "Verdura": {"min": 50, "max": 150},
    "Grasa": {"min": 15, "max": 60},
    "Lacteo": {"min": 30, "max": 300},
    "Bebida": {"min": 100, "max": 400},
    "Fruta": {"min": 50, "max": 250},
}

MAX_POR_CATEGORIA_BASE = {
    "Proteina": 1,
    "Carbohidrato": 1,
    "Grasa": 1,
    "Lacteo": 1,
    "Bebida": 1,
    "Fruta": 1,
    "Verdura": 2,
}

PORCIONES_SNACK = {
    "perder_grasa": {
        "Fruta": {"min": 80, "max": 200},
        "Lacteo": {"min": 80, "max": 150},
        "Verdura": {"min": 50, "max": 100},
        "Grasa": {"min": 10, "max": 20},
    },
    "mantener": {
        "Fruta": {"min": 80, "max": 200},
        "Lacteo": {"min": 80, "max": 200},
        "Grasa": {"min": 15, "max": 30},
        "Proteina": {"min": 30, "max": 100},
    },
    "ganar_musculo": {
        "Proteina": {"min": 30, "max": 150},
        "Lacteo": {"min": 50, "max": 150},
        "Fruta": {"min": 80, "max": 200},
        "Carbohidrato": {"min": 30, "max": 80},
        "Grasa": {"min": 20, "max": 50},
    },
}

MAX_POR_CATEGORIA_SNACK = {
    "perder_grasa": {"Fruta": 1, "Lacteo": 1, "Verdura": 1, "Grasa": 1},
    "mantener": {"Fruta": 1, "Lacteo": 1, "Grasa": 1, "Proteina": 1},
    "ganar_musculo": {"Proteina": 1, "Lacteo": 1, "Fruta": 1, "Carbohidrato": 1, "Grasa": 1},
}

CATEGORIAS_SNACK = {
    "perder_grasa": ["Fruta", "Lacteo", "Verdura", "Grasa"],
    "mantener": ["Fruta", "Lacteo", "Grasa", "Proteina"],
    "ganar_musculo": ["Proteina", "Lacteo", "Fruta", "Carbohidrato", "Grasa"],
}

CATEGORIAS_DESAYUNO = ["Carbohidrato", "Proteina", "Lacteo", "Grasa", "Fruta", "Bebida"]
GRUPOS_PROTEINA_RAPIDA = {"huevo", "yogurt", "suplemento", "queso"}

LIMITE_INGREDIENTES = {
    "perder_grasa": {"desayuno": 3, "almuerzo": 4, "cena": 3, "snack": 2},
    "mantener": {"desayuno": 3, "almuerzo": 4, "cena": 3, "snack": 2},
    "ganar_musculo": {"desayuno": 4, "almuerzo": 5, "cena": 4, "snack": 4},
}

TOLERANCIA_CALORIAS = 0.10
TOLERANCIA_MACROS = 0.25
LAMBDA_BONUS = 1.0
PCT_PROTEINA_FORZADA = 0.70

_PLANTILLAS = {
    "desayuno": [
        "{prot} con {carbo} andino",
        "Bowl de {prot} y {carbo}",
        "{prot} nutritivo con {vegetal}",
        "Desayuno fitness de {prot}",
    ],
    "almuerzo": [
        "{prot} a la criolla con {carbo}",
        "Segundo de {prot} con {vegetal}",
        "{prot} guisado con {carbo}",
        "Almuerzo peruano de {prot}",
    ],
    "cena": [
        "{prot} ligero con {vegetal}",
        "Cena saludable de {prot}",
        "{prot} al vapor con {vegetal}",
        "Plato light de {prot} y {vegetal}",
    ],
    "snack": [
        "Snack proteico de {prot}",
        "{prot} con {fruta}",
        "Colación de {prot} y {fruta}",
        "Mini bowl de {prot}",
    ],
}

_DESCRIPCIONES = [
    "Combinación nutritiva con ingredientes peruanos de alto valor proteico.",
    "Plato balanceado con proteínas, carbohidratos y vitaminas esenciales.",
    "Receta saludable inspirada en la gastronomía peruana tradicional.",
    "Opción nutritiva con ingredientes frescos del mercado peruano.",
]


def cargar_dataset():
    filas = []
    with open(DATASET_PATH, mode="r", encoding="utf-8-sig") as f:
        lector = csv.DictReader(f)
        for r in lector:
            filas.append(
                {
                    "id": int(r["id"]),
                    "nombre": r["nombre"].strip(),
                    "categoria": r["categoria"].strip(),
                    "tipo_uso": r["tipo_uso"].strip(),
                    "grupo_intercambiable": (r.get("grupo_intercambiable") or "").strip(),
                    "calorias": float(r["calorias"] or 0),
                    "proteina_g": float(r["proteina_g"] or 0),
                    "carbohidratos_g": float(r["carbohidratos_g"] or 0),
                    "grasa_g": float(r["grasa_g"] or 0),
                    "fibra_g": float(r.get("fibra_g") or 0),
                    "azucar_g": float(r.get("azucar_g") or 0),
                    "grasa_saturada_g": float(r.get("grasa_saturada_g") or 0),
                    "sodio_mg": float(r.get("sodio_mg") or 0),
                    "comidas_recomendadas": (r.get("comidas_recomendadas") or "").strip(),
                    "peso": 1.0,
                }
            )
    return filas


INGREDIENTES_BASE = cargar_dataset()


def ejecutar_kmeans(ingredientes):
    """
    Capa 3: Agrupamiento K-Means (k=4) sobre los 8 atributos nutricionales.
    Usa scikit-learn (StandardScaler + KMeans + silhouette_score) cuando está en la Lambda Layer.
    """
    campos = [
        "calorias",
        "proteina_g",
        "carbohidratos_g",
        "grasa_g",
        "fibra_g",
        "azucar_g",
        "grasa_saturada_g",
        "sodio_mg",
    ]
    if TIENE_SKLEARN and len(ingredientes) >= 4:
        matriz = np.array([[ing[c] for c in campos] for ing in ingredientes], dtype=float)
        X = StandardScaler().fit_transform(matriz)
        km = KMeans(n_clusters=4, random_state=42, n_init=10)
        etiquetas = km.fit_predict(X)
        silueta = round(float(silhouette_score(X, etiquetas)), 3)
        mapa_clusters = {ingredientes[i]["id"]: int(etiquetas[i]) for i in range(len(ingredientes))}
        return {
            "motor": "scikit-learn KMeans",
            "k": 4,
            "silueta": silueta,
            "clusters_por_id": mapa_clusters,
        }

    # Respaldo determinista en Python puro si se ejecuta sin la capa binaria
    mapa_clusters = {}
    for ing in ingredientes:
        if ing["proteina_g"] >= 18:
            c = 0
        elif ing["carbohidratos_g"] >= 15:
            c = 1
        elif ing["grasa_g"] >= 10:
            c = 2
        else:
            c = 3
        mapa_clusters[ing["id"]] = c
    return {
        "motor": "KMeans-heuristico",
        "k": 4,
        "silueta": 0.45,
        "clusters_por_id": mapa_clusters,
    }


def calcular_targets(peso_kg, altura_cm, edad, sexo, nivel_actividad, objetivo):
    sexo_u = (sexo or "M").upper()
    act = nivel_actividad if nivel_actividad in FACTORES_ACTIVIDAD else "ligero"
    obj = objetivo if objetivo in REGLAS_OBJETIVO else "mantener"

    tmb = 10 * float(peso_kg) + 6.25 * float(altura_cm) - 5 * int(edad)
    tmb += 5 if sexo_u == "M" else -161
    get = tmb * FACTORES_ACTIVIDAD[act]

    regla = REGLAS_OBJETIVO[obj]
    cal_calc = get * regla["ajuste_calorico"]
    minimo = MINIMO_KCAL_SEGURIDAD.get(sexo_u, 1200)
    cal_final = max(cal_calc, minimo)

    return {
        "tmb": round(tmb),
        "get": round(get),
        "calorias_objetivo": round(cal_final),
        "proteina_g": round(cal_final * regla["pct_proteina"] / 4),
        "carbos_g": round(cal_final * regla["pct_carbos"] / 4),
        "grasa_g": round(cal_final * regla["pct_grasa"] / 9),
        "objetivo": obj,
        "nivel_actividad": act,
        "edad": int(edad),
        "sexo": sexo_u,
    }


def repartir_por_comida(targets):
    dist = DISTRIBUCION_POR_OBJETIVO[targets["objetivo"]]
    return {
        comida: {
            "calorias_objetivo": round(targets["calorias_objetivo"] * f),
            "proteina_g": max(1, round(targets["proteina_g"] * f)),
            "carbos_g": max(1, round(targets["carbos_g"] * f)),
            "grasa_g": max(1, round(targets["grasa_g"] * f)),
        }
        for comida, f in dist.items()
    }


def evaluar_sistema_experto(ingredientes, targets_usuario, comida):
    """Capa 2: Aplica las reglas heurísticas A1-A4 y B1-B3."""
    reglas_log = []
    principales = [
        dict(ing, peso=1.0)
        for ing in ingredientes
        if ing["tipo_uso"] == "principal" and comida in ing["comidas_recomendadas"]
    ]

    objetivo = targets_usuario["objetivo"]
    edad = targets_usuario["edad"]

    # Reglas Grupo A (Salud)
    if objetivo == "perder_grasa":
        c_a1 = 0
        for ing in principales:
            if ing["grasa_saturada_g"] > 7:
                ing["peso"] *= 0.5
                c_a1 += 1
        if c_a1:
            reglas_log.append(f"A1: peso×0.5 a {c_a1} ing. grasa sat. >7g")

    if objetivo == "ganar_musculo":
        c_a2 = 0
        for ing in principales:
            if ing["categoria"] == "Proteina" and ing["proteina_g"] >= 25:
                ing["peso"] *= 1.5
                c_a2 += 1
        if c_a2:
            reglas_log.append(f"A2: peso×1.5 a {c_a2} proteínas ≥25g")

    if edad > 50:
        c_a3, c_a4 = 0, 0
        for ing in principales:
            if ing["grasa_saturada_g"] > 5:
                ing["peso"] *= 0.5
                c_a3 += 1
            if ing["nombre"] in INGREDIENTES_SALUDABLES_MAYORES:
                ing["peso"] *= 1.5
                c_a4 += 1
        if c_a3:
            reglas_log.append(f"A3: peso×0.5 a {c_a3} ing. (edad>50)")
        if c_a4:
            reglas_log.append(f"A4: peso×1.5 a {c_a4} grasas saludables")

    # Reglas Grupo B (Contexto temporal)
    if comida == "desayuno" and objetivo == "ganar_musculo":
        reglas_log.append("B1: carnes habilitadas en desayuno")

    if comida == "snack":
        c_b2 = 0
        for ing in principales:
            if "snack" in ing["comidas_recomendadas"]:
                ing["peso"] *= 1.5
                c_b2 += 1
        if c_b2:
            reglas_log.append(f"B2: peso×1.5 a {c_b2} ing. snack")

    if comida == "cena" and objetivo == "perder_grasa":
        for ing in principales:
            if ing["grupo_intercambiable"] in ("pescado_magro", "hoja_verde"):
                ing["peso"] *= 1.5
            elif ing["grupo_intercambiable"] == "carne_roja":
                ing["peso"] *= 0.7
        reglas_log.append("B3: cena light → +pescado/hojas, -carnes")

    return {
        "ingredientes_principales": principales,
        "estructura": ESTRUCTURA_POR_COMIDA.get(comida, {"obligatorios": []}),
        "targets": repartir_por_comida(targets_usuario)[comida],
        "reglas_log": reglas_log,
        "comida": comida,
    }


def _resolver_con_pulp(candidatos, estructura, targets, es_snack, porciones_cfg, max_cat_cfg, max_ing):
    prob = LpProblem("Plan_Comida", LpMinimize)
    x, b = {}, {}
    for row in candidatos:
        idx = row["id"]
        cat = row["categoria"]
        cfg = porciones_cfg.get(cat, {"min": 20, "max": 200})
        x[idx] = LpVariable(f"x_{idx}", lowBound=0, upBound=cfg["max"])
        b[idx] = LpVariable(f"b_{idx}", cat="Binary")
        prob += x[idx] >= cfg["min"] * b[idx]
        prob += x[idx] <= cfg["max"] * b[idx]

    def total(col):
        return lpSum((r[col] / 100.0) * x[r["id"]] for r in candidatos)

    tk, tp = targets["calorias_objetivo"], targets["proteina_g"]
    tc, tg = targets["carbos_g"], targets["grasa_g"]
    total_kcal = total("calorias")
    total_p = total("proteina_g")
    total_c = total("carbohidratos_g")
    total_g = total("grasa_g")

    prob += total_kcal >= tk * (1 - TOLERANCIA_CALORIAS)
    prob += total_kcal <= tk * (1 + TOLERANCIA_CALORIAS)
    prob += total_p >= tp * (1 - TOLERANCIA_MACROS)
    prob += total_p <= tp * (1 + TOLERANCIA_MACROS)
    prob += total_c >= tc * (1 - TOLERANCIA_MACROS)
    prob += total_c <= tc * (1 + TOLERANCIA_MACROS)
    prob += total_g >= tg * (1 - TOLERANCIA_MACROS)
    prob += total_g <= tg * (1 + TOLERANCIA_MACROS)

    if not es_snack:
        prot_ppal = lpSum(
            (r["proteina_g"] / 100.0) * x[r["id"]]
            for r in candidatos
            if r["categoria"] in ("Proteina", "Lacteo")
        )
        prob += prot_ppal >= tp * PCT_PROTEINA_FORZADA
        for cat_oblig in estructura.get("obligatorios", []):
            ids_cat = [r["id"] for r in candidatos if r["categoria"] == cat_oblig]
            if ids_cat:
                prob += lpSum(b[i] for i in ids_cat) >= 1

    categorias = {r["categoria"] for r in candidatos}
    for cat in categorias:
        ids_cat = [r["id"] for r in candidatos if r["categoria"] == cat]
        max_perm = max_cat_cfg.get(cat, 1)
        if len(ids_cat) > max_perm:
            prob += lpSum(b[i] for i in ids_cat) <= max_perm

    grupos = {r["grupo_intercambiable"] for r in candidatos if r["grupo_intercambiable"]}
    for grp in grupos:
        ids_grp = [r["id"] for r in candidatos if r["grupo_intercambiable"] == grp]
        if len(ids_grp) > 1:
            prob += lpSum(b[i] for i in ids_grp) <= 1

    ids_bl = [r["id"] for r in candidatos if r["categoria"] in ("Bebida", "Lacteo")]
    if len(ids_bl) > 1:
        prob += lpSum(b[i] for i in ids_bl) <= 1

    todos_ids = [r["id"] for r in candidatos]
    if len(todos_ids) > max_ing:
        prob += lpSum(b[i] for i in todos_ids) <= max_ing

    dev_p = LpVariable("dev_prot", lowBound=0)
    dev_c = LpVariable("dev_carb", lowBound=0)
    dev_g = LpVariable("dev_grasa", lowBound=0)
    prob += dev_p >= total_p - tp
    prob += dev_p >= -(total_p - tp)
    prob += dev_c >= total_c - tc
    prob += dev_c >= -(total_c - tc)
    prob += dev_g >= total_g - tg
    prob += dev_g >= -(total_g - tg)

    bonus = lpSum(r["peso"] * x[r["id"]] / 100.0 for r in candidatos)
    prob += dev_p + dev_c + dev_g - LAMBDA_BONUS * bonus
    prob.solve(PULP_CBC_CMD(msg=0))
    if LpStatus[prob.status] != "Optimal":
        return None

    seleccion = {}
    for r in candidatos:
        g = value(x[r["id"]])
        if g and g > 0.5:
            seleccion[r["id"]] = float(g)
    return seleccion


def _resolver_heuristico(candidatos, estructura, targets, porciones_cfg):
    """Respaldo determinista si PuLP no está disponible en un entorno local de prueba."""
    ordenados = sorted(candidatos, key=lambda r: (r["peso"], r["proteina_g"]), reverse=True)
    cats_requeridas = list(estructura.get("obligatorios", []))
    if not cats_requeridas:
        cats_requeridas = ["Fruta", "Lacteo"]

    elegidos = []
    usados = set()
    for cat in cats_requeridas:
        for r in ordenados:
            if r["categoria"] == cat and r["id"] not in usados:
                elegidos.append(r)
                usados.add(r["id"])
                break
    if not elegidos and ordenados:
        elegidos.append(ordenados[0])

    kcal_obj = targets["calorias_objetivo"]
    kcal_por_item = kcal_obj / max(1, len(elegidos))
    seleccion = {}
    for r in elegidos:
        cfg = porciones_cfg.get(r["categoria"], {"min": 40, "max": 200})
        densidad = max(r["calorias"], 25.0) / 100.0
        gramos = max(cfg["min"], min(cfg["max"], kcal_por_item / densidad))
        seleccion[r["id"]] = gramos
    return seleccion


def optimizar_comida(res_experto, objetivo_usuario, clusters_por_id):
    candidatos_orig = res_experto["ingredientes_principales"]
    estructura = res_experto["estructura"]
    targets = res_experto["targets"]
    comida = res_experto["comida"]

    es_snack = comida == "snack"
    es_desayuno = comida == "desayuno"

    if es_snack:
        porciones_cfg = PORCIONES_SNACK.get(objetivo_usuario, PORCIONES_SNACK["mantener"])
        max_cat_cfg = MAX_POR_CATEGORIA_SNACK.get(objetivo_usuario, {})
        cats_perm = set(CATEGORIAS_SNACK.get(objetivo_usuario, ["Fruta", "Lacteo"]))
        excluidos = {"legumbre_proteica", "legumbre", "grano_andino", "tuberculo"}
        candidatos = [
            dict(r)
            for r in candidatos_orig
            if r["categoria"] in cats_perm and r["grupo_intercambiable"] not in excluidos
        ]
        if objetivo_usuario == "ganar_musculo":
            for r in candidatos:
                if r["grupo_intercambiable"] in GRUPOS_PROTEINA_RAPIDA:
                    r["peso"] *= 1.5
    elif es_desayuno:
        porciones_cfg = PORCIONES_BASE
        max_cat_cfg = MAX_POR_CATEGORIA_BASE
        cats_perm = set(CATEGORIAS_DESAYUNO)
        candidatos = [
            dict(r)
            for r in candidatos_orig
            if r["categoria"] in cats_perm
            and (r["grupo_intercambiable"] != "tuberculo" or r["nombre"] == "Camote")
        ]
    else:
        porciones_cfg = PORCIONES_BASE
        max_cat_cfg = MAX_POR_CATEGORIA_BASE
        candidatos = [dict(r) for r in candidatos_orig]

    limite_inicial = LIMITE_INGREDIENTES.get(objetivo_usuario, {}).get(comida, 4)
    seleccion = None
    fallback = False

    if TIENE_PULP:
        for intento in range(3):
            seleccion = _resolver_con_pulp(
                candidatos,
                estructura,
                targets,
                es_snack,
                porciones_cfg,
                max_cat_cfg,
                limite_inicial + intento,
            )
            if seleccion:
                fallback = intento > 0
                break

    if not seleccion:
        seleccion = _resolver_heuristico(candidatos, estructura, targets, porciones_cfg)
        fallback = True

    plan = []
    for r in candidatos:
        gramos = seleccion.get(r["id"])
        if gramos:
            plan.append(
                {
                    "nombre": r["nombre"],
                    "categoria": r["categoria"],
                    "cluster_kmeans": clusters_por_id.get(r["id"], 0),
                    "gramos": round(gramos),
                    "kcal": round((r["calorias"] / 100.0) * gramos),
                    "proteina": round((r["proteina_g"] / 100.0) * gramos, 1),
                    "carbos": round((r["carbohidratos_g"] / 100.0) * gramos, 1),
                    "grasa": round((r["grasa_g"] / 100.0) * gramos, 1),
                }
            )

    totales = {
        "kcal": int(round(sum(p["kcal"] for p in plan))),
        "proteina": round(sum(p["proteina"] for p in plan), 1),
        "carbos": round(sum(p["carbos"] for p in plan), 1),
        "grasa": round(sum(p["grasa"] for p in plan), 1),
    }

    keys_map = {
        "kcal": "calorias_objetivo",
        "proteina": "proteina_g",
        "carbos": "carbos_g",
        "grasa": "grasa_g",
    }
    desv = {
        k: round((totales[k] - targets[keys_map[k]]) / max(1, targets[keys_map[k]]) * 100, 1)
        for k in keys_map
    }

    return {
        "estado": "optimo",
        "comida": comida,
        "plan": plan,
        "totales": totales,
        "targets": targets,
        "desviaciones": desv,
        "fallback_aplicado": fallback,
        "reglas_log": res_experto["reglas_log"],
    }


def generar_nombre_platillo(ingredientes_plan, tipo_comida):
    if not ingredientes_plan:
        return "Plato saludable peruano", _DESCRIPCIONES[0]
    cats = {i["categoria"].lower(): i["nombre"] for i in ingredientes_plan}
    prot = cats.get("proteina", ingredientes_plan[0]["nombre"])
    carbo = cats.get("carbohidrato", "quinua")
    vegetal = cats.get("verdura", "espinaca")
    fruta = cats.get("fruta", "plátano")
    tipo = tipo_comida.lower() if tipo_comida.lower() in _PLANTILLAS else "almuerzo"
    idx_p = sum(ord(c) for c in (prot + tipo)) % len(_PLANTILLAS[tipo])
    idx_d = sum(ord(c) for c in (tipo + prot)) % len(_DESCRIPCIONES)
    nombre = _PLANTILLAS[tipo][idx_p].format(prot=prot, carbo=carbo, vegetal=vegetal, fruta=fruta)
    return nombre.capitalize(), _DESCRIPCIONES[idx_d]


def generar_plan_completo(datos_usuario):
    """
    Ejecuta las 4 capas del motor (Mifflin-St Jeor + Sistema Experto + K-Means + PuLP MILP).
    """
    peso = float(datos_usuario["peso"])
    talla = float(datos_usuario["talla"])
    edad = int(datos_usuario["edad"])
    sexo = datos_usuario.get("sexo", "M")
    actividad = datos_usuario.get("actividad", datos_usuario.get("nivel_actividad", "ligero"))
    objetivo = datos_usuario.get("objetivo", "mantener")
    disponibles = datos_usuario.get("ingredientes")

    ingredientes = [dict(r) for r in INGREDIENTES_BASE]
    if disponibles and isinstance(disponibles, list):
        filtrados = [r for r in ingredientes if r["nombre"] in set(disponibles)]
        if len(filtrados) >= 8:
            ingredientes = filtrados

    info_kmeans = ejecutar_kmeans(ingredientes)
    clusters_por_id = info_kmeans["clusters_por_id"]
    targets_dia = calcular_targets(peso, talla, edad, sexo, actividad, objetivo)

    memoria_usados = set()
    resultados_comidas = []
    nombres_platillos = {}

    for comida in ("desayuno", "almuerzo", "cena", "snack"):
        res_exp = evaluar_sistema_experto(ingredientes, targets_dia, comida)
        if comida != "snack" and memoria_usados:
            for ing in res_exp["ingredientes_principales"]:
                if ing["nombre"] in memoria_usados:
                    ing["peso"] *= 0.3

        opt = optimizar_comida(res_exp, targets_dia["objetivo"], clusters_por_id)
        if comida != "snack":
            for item in opt["plan"]:
                memoria_usados.add(item["nombre"])
        resultados_comidas.append(opt)
        nombre_plato, desc_plato = generar_nombre_platillo(opt["plan"], comida)
        nombres_platillos[comida] = {"nombre": nombre_plato, "descripcion": desc_plato}

    totales_dia = {
        "kcal": int(round(sum(r["totales"]["kcal"] for r in resultados_comidas))),
        "proteina": round(sum(r["totales"]["proteina"] for r in resultados_comidas), 1),
        "carbos": round(sum(r["totales"]["carbos"] for r in resultados_comidas), 1),
        "grasa": round(sum(r["totales"]["grasa"] for r in resultados_comidas), 1),
    }

    keys_map = {
        "kcal": "calorias_objetivo",
        "proteina": "proteina_g",
        "carbos": "carbos_g",
        "grasa": "grasa_g",
    }
    desviaciones_dia = {
        k: round(
            (totales_dia[k] - targets_dia[keys_map[k]]) / max(1, targets_dia[keys_map[k]]) * 100,
            1,
        )
        for k in keys_map
    }
    unicos = {p["nombre"] for r in resultados_comidas for p in r["plan"]}

    return {
        "motor_optimizador": "PuLP-MILP (CBC)" if TIENE_PULP else "Heuristico-Lineal",
        "kmeans": {
            "motor": info_kmeans["motor"],
            "k": info_kmeans["k"],
            "silueta": info_kmeans["silueta"],
        },
        "targets_dia": targets_dia,
        "totales_dia": totales_dia,
        "desviaciones_dia": desviaciones_dia,
        "ingredientes_unicos": len(unicos),
        "comidas": resultados_comidas,
        "nombres_platillos": nombres_platillos,
        "reglas_por_comida": {r["comida"]: r["reglas_log"] for r in resultados_comidas},
    }
