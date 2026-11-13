#!/usr/bin/env bash
# =====================================================================
# Pruebas de la consulta de hallazgos contra la base sst_pesv real.
# Requisitos: la base instalada + sql/01_esquema_alertas.sql + sql/03_datos_demo.sql
# Variables: PGHOST, PGUSER, PGPASSWORD, PGDATABASE (administrador)
#            CLAVE_N8N = clave del rol n8n_alertas (por defecto: clave_ci)
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

export PGHOST="${PGHOST:-localhost}" PGDATABASE="${PGDATABASE:-sst_pesv}"
CLAVE="${CLAVE_N8N:-clave_ci}"

admin() { psql -v ON_ERROR_STOP=1 -At "$@"; }
n8n()   { PGUSER=n8n_alertas PGPASSWORD="$CLAVE" psql -v ON_ERROR_STOP=1 -At "$@"; }

fallos=0
esperar() {  # esperar "descripcion" esperado obtenido
  if [ "$2" = "$3" ]; then echo "OK   $1 (= $3)"; else echo "FALLA $1: esperado $2, obtenido $3"; fallos=$((fallos+1)); fi
}

# Cuenta cuantas organizaciones devuelve la consulta, con los umbrales por defecto.
contar() {
  {
    echo "PREPARE h(int,int,numeric,int) AS SELECT count(*) FROM ("
    sed '/^[[:space:]]*--/d; s/;[[:space:]]*$//' sql/02_consulta_hallazgos.sql
    echo ") q; EXECUTE h(15,30,60,7);"
  } | n8n | tail -n1
}

admin -c "TRUNCATE alertas.bitacora RESTART IDENTITY" >/dev/null

# 1. Con los datos de demostracion deben salir las 4 organizaciones activas con documentos.
esperar "organizaciones con hallazgos" 4 "$(contar)"

# 2. Una alerta REAL reciente saca a esa organizacion de la lista (no se repite).
n8n -c "INSERT INTO alertas.bitacora (tenant_id, severidad, resumen, destinatario, es_simulacro, estado)
        VALUES (1, 'ALTA', '{}', 'a@b.co', FALSE, 'ENVIADA')" >/dev/null
esperar "tras alerta real a la org 1" 3 "$(contar)"

# 3. Un SIMULACRO no cuenta: la org 2 sigue apareciendo aunque tenga un simulacro enviado.
n8n -c "INSERT INTO alertas.bitacora (tenant_id, severidad, resumen, destinatario, es_simulacro, estado)
        VALUES (2, 'MEDIA', '{}', 'a@b.co', TRUE, 'ENVIADA')" >/dev/null
esperar "tras simulacro a la org 2" 3 "$(contar)"

# 4. Una alerta con ERROR tampoco cuenta: hay que reintentarla.
n8n -c "INSERT INTO alertas.bitacora (tenant_id, severidad, resumen, destinatario, es_simulacro, estado, detalle_error)
        VALUES (3, 'ALTA', '{}', 'a@b.co', FALSE, 'ERROR', 'SMTP caido')" >/dev/null
esperar "tras alerta con ERROR a la org 3" 3 "$(contar)"

# 5. Minimo privilegio: el rol de n8n NO puede modificar el sistema SST/PESV.
if n8n -c "UPDATE documents SET status = 'FINALIZADO' WHERE false" >/dev/null 2>&1; then
  echo "FALLA el rol n8n_alertas pudo hacer UPDATE sobre documents"; fallos=$((fallos+1))
else
  echo "OK   el rol n8n_alertas no puede modificar documents"
fi

admin -c "TRUNCATE alertas.bitacora RESTART IDENTITY" >/dev/null

if [ "$fallos" -gt 0 ]; then echo "$fallos prueba(s) fallaron"; exit 1; fi
echo "Todas las pruebas pasaron"
