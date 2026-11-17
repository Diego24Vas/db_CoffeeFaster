const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const prepararAfiliaciones = require('./helpers/afiliaciones.cjs');
const migrations = path.join(__dirname, '../supabase/migrations');
const leer = name => fs.readFileSync(path.join(migrations, name), 'utf8');
const sesion = id => 'SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;\n' +
  "SET request.jwt.claim.sub = '00000000-0000-0000-0000-" + String(id).padStart(12, '0') + "';";

module.exports = conBaseTemporal('oportunidades_upgrade', async ({ sql }) => {
  prepararAfiliaciones(sql);
  sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(fs.readFileSync(path.join(__dirname, 'fixtures/afiliaciones.sql'), 'utf8'));

  // Simula una base que ya aplicó la versión anterior de 0023.
  sql(leer('0023_s3_t4_rpc_listar_oportunidades_campana.sql'));
  sql(`INSERT INTO public.campanas(id,cafeteria_id,nombre,estado,tasa_descuento,tasa_comision,vigencia_desde,vigencia_hasta)
    OVERRIDING SYSTEM VALUE VALUES
    (30,1,'Futura anterior a 0024','activa',7.00,6.00,statement_timestamp()+interval '1 day',statement_timestamp()+interval '2 days');`);

  const antes = JSON.parse(sql(sesion(10) + " SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.id),'[]'::json)::text FROM public.listar_oportunidades_campana(1) o;"));
  assert.deepEqual(antes.map(row => Number(row.id)), [1, 30], 'la versión anterior de 0023 incluía la campaña futura');
  assert.equal(antes.find(row => Number(row.id) === 30).estado_vigencia, 'futura');
  assert.equal(antes.find(row => Number(row.id) === 1).estado_vigencia, 'en_curso');

  // La migración posterior conserva el mismo retorno y cambia el cuerpo.
  sql(leer('0024_s3_t4_rpc_campanas_vigentes.sql'));
  const despues = JSON.parse(sql(sesion(10) + " SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.id),'[]'::json)::text FROM public.listar_oportunidades_campana(1) o;"));
  assert.deepEqual(despues.map(row => Number(row.id)), [1], '0024 excluye la campaña futura');
  assert.equal(despues[0].estado_vigencia, 'en_curso');
  assert.deepEqual(Object.keys(despues[0]), ['id','nombre','cafeteria_id','cafeteria_nombre','tipo','estado','vigencia_desde','vigencia_hasta','tasa_descuento','tasa_comision','estado_vigencia']);
  assert.equal(sql("SELECT has_function_privilege('authenticated','public.listar_oportunidades_campana(bigint)','EXECUTE') AND NOT has_function_privilege('anon','public.listar_oportunidades_campana(bigint)','EXECUTE') AND NOT has_function_privilege('service_role','public.listar_oportunidades_campana(bigint)','EXECUTE')"), 't', '0024 conserva permisos');
  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.campanas;'), '0', '0024 conserva el bloqueo del SELECT directo');
  console.log('S3-T4 upgrade: 0023 aplicada y luego 0024 reemplaza el cuerpo sin cambiar el retorno; futuro excluido y estado_vigencia conservado.');
}).catch(error => { console.error(error.stderr?.toString() || error.stack); throw error; });
