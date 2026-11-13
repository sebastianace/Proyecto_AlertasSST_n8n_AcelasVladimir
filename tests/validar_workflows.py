"""Valida los workflows exportados de n8n antes de subirlos al repositorio.

Revisa:
  1. que sean JSON validos y las conexiones apunten a nodos que existen;
  2. que no incluyan credenciales ni secretos;
  3. que el modo simulacro venga activado por defecto (para que importar el
     workflow nunca envie correos reales por accidente).
"""
import json
import pathlib
import re
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
errores = []


def falla(mensaje):
    errores.append(mensaje)
    print('FALLA', mensaje)


archivos = sorted((RAIZ / 'workflows').glob('*.json'))
if not archivos:
    falla('no hay workflows en la carpeta workflows/')

for ruta in archivos:
    texto = ruta.read_text(encoding='utf-8')
    try:
        wf = json.loads(texto)
    except json.JSONDecodeError as e:
        falla(f'{ruta.name}: JSON invalido ({e})')
        continue

    nombres = [n['name'] for n in wf['nodes']]
    if len(nombres) != len(set(nombres)):
        falla(f'{ruta.name}: hay nombres de nodo repetidos')

    for origen, salidas in wf['connections'].items():
        if origen not in nombres:
            falla(f'{ruta.name}: conexion desde un nodo inexistente ({origen})')
        for grupo in salidas['main']:
            for destino in grupo:
                if destino['node'] not in nombres:
                    falla(f'{ruta.name}: conexion hacia un nodo inexistente ({destino["node"]})')

    for nodo in wf['nodes']:
        if 'credentials' in nodo:
            falla(f'{ruta.name}: el nodo "{nodo["name"]}" exporta credenciales; quitalas antes de subir')

    if re.search(r'(api[_-]?key|secret|bearer\s+[a-z0-9]|password\s*[:=]\s*["\'][^"\']+)', texto, re.I):
        falla(f'{ruta.name}: parece contener un secreto')
    # Tokens de bot de Telegram: 8-10 digitos, dos puntos y 35 caracteres.
    if re.search(r'\b\d{8,10}:[A-Za-z0-9_-]{35}\b', texto):
        falla(f'{ruta.name}: parece contener un token de Telegram')

    if ruta.name.startswith('01_'):
        config = next((n for n in wf['nodes'] if n['name'] == 'Configuración'), None)
        if config is None:
            falla(f'{ruta.name}: falta el nodo Configuración')
        else:
            valores = {a['name']: a['value'] for a in config['parameters']['assignments']['assignments']}
            if valores.get('modo_simulacro') is not True:
                falla(f'{ruta.name}: modo_simulacro debe venir en true por defecto')

if errores:
    print(f'\n{len(errores)} problema(s)')
    sys.exit(1)
print(f'OK: {len(archivos)} workflows validados')
