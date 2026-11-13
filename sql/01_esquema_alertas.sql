-- =====================================================================
-- PROYECTO : Alertas de cumplimiento SST / PESV con n8n
-- ARCHIVO  : 01_esquema_alertas.sql
-- CONTENIDO: Esquema propio de las alertas (bitacora) y un rol de PostgreSQL
--            con permisos minimos para que n8n se conecte.
-- REQUISITO: la base sst_pesv ya esta instalada (repo proyecto_base_de_datos_en_PostgreSQL).
-- USO      : psql -U postgres -d sst_pesv -v clave='UNA_CLAVE_SEGURA' -f sql/01_esquema_alertas.sql
-- Es re-ejecutable: no borra nada.
-- =====================================================================
\set ON_ERROR_STOP on

DO $$
BEGIN
    IF current_database() <> 'sst_pesv' THEN
        RAISE EXCEPTION 'Base equivocada: estas en "%". Conectate a sst_pesv.', current_database();
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- 1. ESQUEMA PROPIO
-- Todo lo que crea este proyecto vive en el esquema "alertas": las tablas
-- del proyecto de base de datos (esquema public) no se modifican.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS alertas;

-- Bitacora de cada alerta que n8n intenta enviar. Sirve para dos cosas:
--   1) auditar que se envio, a quien y con que resultado.
--   2) evitar repetir la misma alerta todos los dias (ver 02_consulta_hallazgos.sql).
-- Sin llave foranea a tenants a proposito (mismo criterio que tenant_audit):
-- la bitacora debe sobrevivir aunque se reinstale la base o se borre la empresa.
CREATE TABLE IF NOT EXISTS alertas.bitacora (
    id             BIGSERIAL    PRIMARY KEY,
    tenant_id      INTEGER      NOT NULL,
    tipo           VARCHAR(30)  NOT NULL DEFAULT 'CUMPLIMIENTO_DOCUMENTAL',
    severidad      VARCHAR(10)  NOT NULL,
    resumen        JSONB        NOT NULL,
    canal          VARCHAR(20)  NOT NULL DEFAULT 'EMAIL',
    destinatario   VARCHAR(150) NOT NULL,
    es_simulacro   BOOLEAN      NOT NULL DEFAULT FALSE,
    estado         VARCHAR(10)  NOT NULL,
    detalle_error  TEXT,
    creada_en      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_bitacora_severidad CHECK (severidad IN ('BAJA','MEDIA','ALTA')),
    CONSTRAINT ck_bitacora_estado    CHECK (estado IN ('ENVIADA','ERROR')),
    CONSTRAINT ck_bitacora_error     CHECK (estado = 'ERROR' OR detalle_error IS NULL)
);

-- La consulta de hallazgos pregunta "esta organizacion ya recibio una alerta
-- en los ultimos N dias?": este indice la responde sin recorrer toda la tabla.
CREATE INDEX IF NOT EXISTS idx_bitacora_tenant_fecha
    ON alertas.bitacora (tenant_id, creada_en DESC);

-- ---------------------------------------------------------------------
-- 2. ROL DE n8n CON PERMISOS MINIMOS (principio de minimo privilegio)
-- n8n NO se conecta como postgres: solo puede LEER las 5 tablas que
-- necesita y ESCRIBIR en su propia bitacora. No puede borrar ni modificar
-- nada del sistema SST/PESV.
-- La clave llega por la variable de psql :clave (no queda en el repositorio).
-- ---------------------------------------------------------------------
-- Si el rol ya existe, su clave NO se modifica. Para cambiarla: ALTER ROLE n8n_alertas PASSWORD 'nueva_clave';
SELECT format('CREATE ROLE n8n_alertas LOGIN PASSWORD %L', :'clave')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_alertas')
\gexec

GRANT CONNECT ON DATABASE sst_pesv TO n8n_alertas;

GRANT USAGE  ON SCHEMA public TO n8n_alertas;
GRANT SELECT ON public.tenants, public.documents, public.tenanttemplates,
                public.templates, public.type_system_sst
    TO n8n_alertas;

GRANT USAGE  ON SCHEMA alertas TO n8n_alertas;
GRANT SELECT, INSERT ON alertas.bitacora TO n8n_alertas;
GRANT USAGE  ON SEQUENCE alertas.bitacora_id_seq TO n8n_alertas;
