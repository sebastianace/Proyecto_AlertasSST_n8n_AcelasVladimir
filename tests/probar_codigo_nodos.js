// Pruebas de los nodos "Code" del workflow 01 (severidad, escape de HTML, simulacro y registro de errores).
// Lee el codigo directamente del JSON exportado, asi se prueba exactamente lo que ejecutara n8n.
// Uso: node tests/probar_codigo_nodos.js   (Node 18 o superior; no necesita instalar nada)
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const wf = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'workflows', '01_alertas_cumplimiento_sst_pesv.json'), 'utf8')
);
const codigoDe = (nombre) => wf.nodes.find((n) => n.name === nombre).parameters.jsCode;

// Ejecuta el codigo de un nodo con los "globals" que n8n le da ($, $input, $json).
function ejecutar(nombre, { cfg, entradas = [], json = {}, nodosPrevios = {} }) {
  const $ = (nodo) => ({
    first: () => ({ json: nodo === 'Configuración' ? cfg : nodosPrevios[nodo][0].json }),
    all: () => nodosPrevios[nodo],
    item: nodosPrevios[nodo] ? nodosPrevios[nodo][0] : undefined,
  });
  const fn = new Function('$', '$input', '$json', `return (function () {${codigoDe(nombre)}})();`);
  return fn($, { all: () => entradas.map((j) => ({ json: j })) }, json);
}

const CFG = {
  dias_borrador: 15, dias_no_iniciado: 30, umbral_cumplimiento: 60, dias_sin_repetir: 7,
  modo_simulacro: true, correo_prueba: 'prueba@ejemplo.com', correo_remitente: 'alertas@ejemplo.com',
  telegram_chat_id: '1',
};

const doc = (id, estado, dias, titulo = `Documento ${id}`) => ({ id, titulo, estado, sistema: 'SST', dias });
const org = (id, nombre, estancados, bajos) => ({
  tenant_id: id, organizacion: nombre, correo_contacto: `contacto${id}@empresa.com`,
  documentos_estancados: estancados, sistemas_bajo_umbral: bajos,
});
const sis = (porcentaje) => ({ sistema: 'SST', total: 10, finalizados: Math.round(porcentaje / 10), porcentaje });

let pasaron = 0;
function prueba(descripcion, fn) {
  try { fn(); pasaron++; console.log('OK    ' + descripcion); }
  catch (e) { console.error('FALLA ' + descripcion + '\n      ' + e.message.split('\n')[0]); process.exitCode = 1; }
}

// ---------------------------------------------------------------- Construir mensaje
const sev = (estancados, bajos) =>
  ejecutar('Construir mensaje', { cfg: CFG, entradas: [org(1, 'Org', estancados, bajos)] })[0].json.severidad;

prueba('severidad ALTA: un sistema con menos de 30 %', () => assert.equal(sev([doc(1, 'BORRADOR', 20)], [sis(28.6)]), 'ALTA'));
prueba('severidad ALTA: 5 o más documentos estancados', () =>
  assert.equal(sev([1, 2, 3, 4, 5].map((i) => doc(i, 'BORRADOR', 20)), [sis(55)]), 'ALTA'));
prueba('severidad MEDIA: un sistema bajo el umbral (30-59 %)', () => assert.equal(sev([doc(1, 'BORRADOR', 20)], [sis(40)]), 'MEDIA'));
prueba('severidad MEDIA: 3 o 4 documentos estancados sin sistema en riesgo', () =>
  assert.equal(sev([1, 2, 3].map((i) => doc(i, 'BORRADOR', 20)), []), 'MEDIA'));
prueba('severidad BAJA: un solo documento estancado', () => assert.equal(sev([doc(1, 'NO_INICIADO', 40)], []), 'BAJA'));
prueba('severidad: exactamente 30 % ya no es ALTA', () => assert.equal(sev([], [sis(30)]), 'MEDIA'));

prueba('modo simulacro redirige al correo de prueba y lo marca', () => {
  const r = ejecutar('Construir mensaje', { cfg: CFG, entradas: [org(7, 'Org', [doc(1, 'BORRADOR', 20)], [])] })[0].json;
  assert.equal(r.destinatario, 'prueba@ejemplo.com');
  assert.equal(r.es_simulacro, true);
  assert.match(r.asunto, /^\[SIMULACRO\]/);
  assert.match(r.html, /contacto7@empresa\.com/); // el aviso dice a quien habria ido
});

prueba('modo real envía al contacto de la organización', () => {
  const r = ejecutar('Construir mensaje', {
    cfg: { ...CFG, modo_simulacro: false }, entradas: [org(7, 'Org', [doc(1, 'BORRADOR', 20)], [])],
  })[0].json;
  assert.equal(r.destinatario, 'contacto7@empresa.com');
  assert.equal(r.es_simulacro, false);
  assert.doesNotMatch(r.asunto, /SIMULACRO/);
});

prueba('el HTML escapa los títulos que vienen de la base de datos', () => {
  const r = ejecutar('Construir mensaje', {
    cfg: CFG, entradas: [org(1, 'Org <b>', [doc(1, 'BORRADOR', 20, '<script>alert(1)</script>')], [])],
  })[0].json;
  assert.doesNotMatch(r.html, /<script>/);
  assert.match(r.html, /&lt;script&gt;/);
  assert.doesNotMatch(r.html, /Org <b>/);
});

prueba('lista como máximo 8 documentos y dice cuántos faltan', () => {
  const muchos = Array.from({ length: 11 }, (_, i) => doc(i + 1, 'BORRADOR', 20, `Doc-${i + 1}-fin`));
  const html = ejecutar('Construir mensaje', { cfg: CFG, entradas: [org(1, 'Org', muchos, [])] })[0].json.html;
  assert.equal((html.match(/Doc-\d+-fin/g) || []).length, 8);
  assert.match(html, /y 3 más/);
});

prueba('un ítem por organización, con su pairedItem', () => {
  const r = ejecutar('Construir mensaje', {
    cfg: CFG, entradas: [org(1, 'A', [doc(1, 'BORRADOR', 20)], []), org(2, 'B', [doc(2, 'BORRADOR', 20)], [])],
  });
  assert.equal(r.length, 2);
  assert.deepEqual(r.map((x) => x.pairedItem.item), [0, 1]);
  assert.deepEqual(r.map((x) => x.json.tenant_id), [1, 2]);
});

// ---------------------------------------------------------------- Preparar registro
const base = { tenant_id: 3, organizacion: 'Org', severidad: 'ALTA', destinatario: 'a@b.co', es_simulacro: false, resumen: { x: 1 } };
const registro = (entrada) =>
  ejecutar('Preparar registro', { cfg: CFG, json: entrada, nodosPrevios: { 'Construir mensaje': [{ json: base }] } }).json;

prueba('registro: correo enviado => ENVIADA sin detalle de error', () => {
  const r = registro({ success: true });
  assert.equal(r.estado, 'ENVIADA');
  assert.equal(r.detalle_error, '');
});
prueba('registro: correo fallido => ERROR con el mensaje', () => {
  const r = registro({ error: { message: 'SMTP 535 auth failed' } });
  assert.equal(r.estado, 'ERROR');
  assert.equal(r.detalle_error, 'SMTP 535 auth failed');
});
prueba('registro: el detalle de error se recorta a 500 caracteres', () =>
  assert.equal(registro({ error: 'x'.repeat(900) }).detalle_error.length, 500));

// ---------------------------------------------------------------- Resumen para el administrador
prueba('resumen: cuenta enviadas y errores e indica el modo', () => {
  const filas = [
    { json: { ...base, organizacion: 'A', estado: 'ENVIADA' } },
    { json: { ...base, organizacion: 'B', estado: 'ERROR' } },
  ];
  const r = ejecutar('Resumen para el administrador', { cfg: CFG, nodosPrevios: { 'Preparar registro': filas } })[0].json.texto;
  assert.match(r, /modo SIMULACRO/);
  assert.match(r, /alertadas: 2 \| enviadas: 1 \| con error: 1/);
  assert.match(r, /- B: ALTA \(ERROR\)/);
});

console.log(`\n${pasaron} pruebas pasaron` + (process.exitCode ? ', hubo fallas' : ''));
