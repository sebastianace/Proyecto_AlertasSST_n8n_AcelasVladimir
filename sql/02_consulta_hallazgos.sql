-- =====================================================================
-- ARCHIVO  : 02_consulta_hallazgos.sql
-- CONTENIDO: La consulta que ejecuta el nodo "Detectar hallazgos" de n8n.
--            Se deja aqui para poder probarla y leerla sin abrir n8n.
-- PARAMETROS (n8n los pasa como $1..$4, nunca concatenados al texto):
--   $1  dias_borrador       un BORRADOR sin cambios hace >= $1 dias esta estancado
--   $2  dias_no_iniciado    un NO_INICIADO creado hace >= $2 dias esta atrasado
--   $3  umbral_cumplimiento un sistema (SST/PESV) con % finalizado < $3 esta en riesgo
--   $4  dias_sin_repetir    no volver a alertar a una organizacion en $4 dias
-- RESULTADO: una fila por organizacion con hallazgos, con el detalle en JSON.
-- =====================================================================
WITH docs AS (
    -- Un documento con su sistema (SST/PESV) y sus dias de antiguedad.
    -- Solo organizaciones activas y plantillas activas.
    SELECT
        d.id,
        d.tenant_id,
        d.title,
        d.status,
        s.code                                    AS sistema,
        CURRENT_DATE - d.updated_at::date         AS dias_sin_cambios,
        CURRENT_DATE - d.created_at::date         AS dias_desde_creacion
    FROM documents        d
    JOIN tenants          t  ON t.id  = d.tenant_id
    JOIN tenanttemplates  tt ON tt.id = d.tenanttemplate_id
    JOIN templates        tp ON tp.id = tt.template_id
    JOIN type_system_sst  s  ON s.id  = tp.type_system_sst_id
    WHERE t.is_active
      AND tt.is_active
),
estancados AS (
    SELECT
        id, tenant_id, title, status, sistema,
        CASE WHEN status = 'BORRADOR' THEN dias_sin_cambios
             ELSE dias_desde_creacion
        END AS dias
    FROM docs
    WHERE (status = 'BORRADOR'    AND dias_sin_cambios    >= $1::int)
       OR (status = 'NO_INICIADO' AND dias_desde_creacion >= $2::int)
),
cumplimiento AS (
    -- Se calcula en vivo desde documents. Las vistas materializadas
    -- vm_template_*_docs_summary pueden estar desactualizadas hasta que
    -- alguien las refresque, y una alerta no debe basarse en datos viejos.
    SELECT
        tenant_id,
        sistema,
        COUNT(*)::int                                          AS total,
        COUNT(*) FILTER (WHERE status = 'FINALIZADO')::int     AS finalizados,
        ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'FINALIZADO')
              / COUNT(*), 1)                                   AS porcentaje
    FROM docs
    GROUP BY tenant_id, sistema
),
bajo_umbral AS (
    SELECT * FROM cumplimiento WHERE porcentaje < $3::numeric
)
SELECT
    t.id            AS tenant_id,
    t.name          AS organizacion,
    t.contact_email AS correo_contacto,
    -- Cada detalle va en su propia subconsulta: con dos LEFT JOIN seguidos
    -- las filas se multiplicarian entre si (mismo cuidado que en la vista A25).
    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id',      e.id,
                'titulo',  e.title,
                'estado',  e.status,
                'sistema', e.sistema,
                'dias',    e.dias
            ) ORDER BY e.dias DESC, e.id), '[]'::jsonb)
       FROM estancados e
      WHERE e.tenant_id = t.id)                              AS documentos_estancados,
    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'sistema',     b.sistema,
                'total',       b.total,
                'finalizados', b.finalizados,
                'porcentaje',  b.porcentaje
            ) ORDER BY b.sistema), '[]'::jsonb)
       FROM bajo_umbral b
      WHERE b.tenant_id = t.id)                              AS sistemas_bajo_umbral
FROM tenants t
WHERE t.is_active
  AND (EXISTS (SELECT 1 FROM estancados  e WHERE e.tenant_id = t.id)
    OR EXISTS (SELECT 1 FROM bajo_umbral b WHERE b.tenant_id = t.id))
  -- No repetir: si ya se le envio una alerta real hace poco, se omite.
  -- Los simulacros (es_simulacro) no cuentan, para poder probar todos los dias.
  AND NOT EXISTS (
        SELECT 1
          FROM alertas.bitacora a
         WHERE a.tenant_id    = t.id
           AND a.estado       = 'ENVIADA'
           AND NOT a.es_simulacro
           AND a.creada_en    > CURRENT_TIMESTAMP - make_interval(days => $4::int)
  )
ORDER BY t.id;
