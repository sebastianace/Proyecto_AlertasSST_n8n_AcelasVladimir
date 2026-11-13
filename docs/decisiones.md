# Decisiones de diseño

Este documento explica por qué el proyecto está hecho como está y qué alternativas se descartaron.

## 1. Alertas sobre el estado de los documentos

La base de datos `sst_pesv` gestiona **documentos** del SG-SST y del PESV (estados `NO_INICIADO`, `BORRADOR`, `FINALIZADO`). No guarda fechas de vencimiento de licencias, SOAT o exámenes médicos, así que las alertas se construyen sobre lo que sí existe: el avance documental de cada organización.

- **Documento estancado**: `BORRADOR` sin cambios hace 15 días o más, o `NO_INICIADO` creado hace 30 días o más.
- **Sistema en riesgo**: SST o PESV con menos del 60 % de sus documentos en `FINALIZADO`.

Los tres números (15, 30 y 60) viven en el nodo `Configuración`, no en el código.

**Alternativa descartada:** agregar tablas de vencimientos (SOAT, licencias) a la base. Habría cambiado un proyecto que ya está terminado, y este repositorio debe poder conectarse a esa base sin modificarla.

## 2. Esquema propio y rol de mínimo privilegio

El proyecto necesita guardar una bitácora de alertas. Se crea en el esquema `alertas`, separado de `public`. Y n8n no usa el usuario `postgres`: usa `n8n_alertas`, que puede:

- **leer** `tenants`, `documents`, `tenanttemplates`, `templates` y `type_system_sst`;
- **leer e insertar** en `alertas.bitacora`.

Nada más. Si las credenciales de n8n se filtraran, el daño estaría limitado a leer esas cinco tablas. `tests/probar_consulta.sh` comprueba que el rol no puede hacer `UPDATE` sobre `documents`.

**Alternativa descartada:** crear la bitácora dentro de `public`. Habría mezclado tablas del proyecto de base de datos con las de la automatización, y el script `01_ddl.sql` de ese proyecto (que borra y recrea sus tablas) podría afectarla.

## 3. Cumplimiento calculado en vivo

El proyecto de base de datos ya tiene dos vistas materializadas con el cumplimiento por sistema (`vm_template_sst_docs_summary` y `vm_template_pesv_docs_summary`). Se podrían usar, pero una vista materializada guarda una foto de los datos: si nadie la refresca, la alerta diría algo falso. La consulta calcula el porcentaje directamente desde `documents`.

**Alternativa descartada:** refrescar las vistas desde n8n antes de consultarlas. Funciona, pero obliga a darle permisos de escritura sobre objetos del proyecto de base de datos, contra el principio de mínimo privilegio.

## 4. Consulta con parámetros

El nodo Postgres recibe los umbrales como parámetros (`$1`, `$2`, `$3`, `$4`) en lugar de armar el texto de la consulta con valores pegados. Es la práctica correcta para evitar inyección SQL, aunque aquí los valores vengan de un nodo interno.

Los detalles de cada organización (documentos estancados y sistemas en riesgo) se calculan en subconsultas independientes. Con dos `LEFT JOIN` seguidos las filas se multiplicarían entre sí (el mismo cuidado que ya tiene la vista `vw_tenant_consolidado` del proyecto de base de datos).

## 5. Modo simulacro

El workflow se importa con `modo_simulacro = true`. En ese modo todos los correos van a `correo_prueba` y el mensaje avisa a qué dirección real habrían ido. Así nadie envía correos a clientes por accidente al probar. Además, `tests/validar_workflows.py` falla si alguien sube el workflow con el simulacro desactivado.

## 6. No repetir alertas

Sin control, la misma organización recibiría el mismo correo todos los días. La consulta omite a las organizaciones que ya recibieron una alerta real en los últimos `dias_sin_repetir` días (7 por defecto). Se cuentan solo los registros con estado `ENVIADA` y `es_simulacro = false`:

- los **simulacros** no cuentan, para poder probar todos los días;
- los envíos con **error** no cuentan, para que se reintenten en la siguiente ejecución.

## 7. Manejo de errores en tres niveles

1. **Reintentos automáticos**: el nodo Postgres reintenta 3 veces y el de correo 2.
2. **Continuar si un correo falla**: el nodo de correo usa *On Error → Continue*. Si falla para una organización, las demás se envían y el fallo se guarda como `ERROR` con su detalle.
3. **Workflow de errores** (`02_manejo_de_errores.json`): si el workflow principal falla por completo, avisa por Telegram con el nodo que falló y el enlace a la ejecución.

## 8. Avisar también cuando no hay nada que alertar

Un workflow que no envía nada es indistinguible de un workflow que dejó de funcionar. Por eso, si la consulta no devuelve organizaciones, el administrador recibe un mensaje corto ("hoy no hay organizaciones por alertar"). Es un *heartbeat*: la ausencia de noticias también es una noticia.

## 9. Cómo se probó

| Qué | Cómo | Dónde corre |
|---|---|---|
| Consulta, no repetir alertas y permisos del rol | `tests/probar_consulta.sh` | Automático en cada push (CI) |
| Código de los nodos Code (severidad, HTML escapado, simulacro, registro de errores) | `tests/probar_codigo_nodos.js`, leyendo el código del propio workflow | Automático en cada push (CI) |
| Workflows válidos, sin credenciales y con el simulacro activo | `tests/validar_workflows.py` | Automático en cada push (CI) |
| Workflow completo | Se importó en un n8n real, con la base real y un servidor SMTP de prueba: envío correcto a las 4 organizaciones, envío con SMTP caído (queda `ERROR` en la bitácora y el flujo continúa), segunda ejecución sin repetir alertas y el aviso de "nada que alertar" | Manual, una vez |

**Lo que no se probó:** el envío real por Telegram ni con un servidor de correo real. Las credenciales y el bot son del usuario; el flujo hasta esos nodos sí se ejecutó.

## 10. Lo que no hace el workflow

- No libera los bloqueos de edición vencidos: el proyecto de base de datos ya lo hace con el trigger T15, y duplicar esa lógica en n8n sería un error de diseño.
- No modifica ningún dato del sistema SST/PESV.
