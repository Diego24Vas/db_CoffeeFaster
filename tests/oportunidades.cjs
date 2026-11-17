const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const prepararAfiliaciones = require('./helpers/afiliaciones.cjs');
const migrations = path.join(__dirname, '../supabase/migrations');
const leer = name => fs.readFileSync(path.join(migrations, name), 'utf8');
const sesion = id => 'SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;\n' +
  "SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-'||lpad(" + id + "::text,12,'0'),false);";

module.exports = conBaseTemporal('oportunidades', async ({ sql }) => {
  prepararAfiliaciones(sql);
  sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(fs.readFileSync(path.join(__dirname, 'fixtures/afiliaciones.sql'), 'utf8'));
  sql(leer('0023_s3_t4_rpc_listar_oportunidades_campana.sql'));

  sql("INSERT INTO public.campanas(id,cafeteria_id,nombre,tipo,estado,tasa_descuento,tasa_comision,vigencia_desde,vigencia_hasta) OVERRIDING SYSTEM VALUE VALUES " +
    "(10,1,'Futura activa','carrito_completo','activa',12.50,8.00,statement_timestamp()+interval '2 days',statement_timestamp()+interval '5 days')," +
    "(11,1,'Futura pendiente de aceptación','carrito_completo','pendiente_aceptacion',5.00,4.00,statement_timestamp()+interval '1 day',statement_timestamp()+interval '3 days')," +
    "(12,1,'En curso aceptada','carrito_completo','aceptada',15.00,7.00,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day')," +
    "(13,1,'Borrador','carrito_completo','borrador',0,0,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day')," +
    "(14,1,'Pausada','carrito_completo','pausada',0,0,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day')," +
    "(15,1,'Finalizada','carrito_completo','finalizada',0,0,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day')," +
    "(16,1,'Vencida','carrito_completo','activa',0,0,statement_timestamp()-interval '2 days',statement_timestamp()-interval '1 day')," +
    "(17,2,'Otra cafetería','carrito_completo','activa',0,0,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day')");

  assert.equal(sql("SELECT has_function_privilege('authenticated','public.listar_oportunidades_campana(bigint)','EXECUTE') AND NOT has_function_privilege('anon','public.listar_oportunidades_campana(bigint)','EXECUTE')"), 't', 'solo authenticated recibe EXECUTE');
  assert.equal(sql("SELECT has_function_privilege('authenticated','public.obtener_campana_vigente(bigint)','EXECUTE') AND has_function_privilege('authenticated','public.confirmar_condiciones_campana(bigint,bigint,text)','EXECUTE')"), 't', 'se conservan las RPC anteriores');

  const filas = JSON.parse(sql(sesion(10) + " SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.id),'[]'::json)::text FROM public.listar_oportunidades_campana(1) o;"));
  assert.deepEqual(filas.map(row => Number(row.id)), [1, 10, 11, 12], 'incluye estados postulables vigentes y omite excluidos');
  const futura = filas.find(row => Number(row.id) === 10);
  assert.deepEqual(Object.keys(futura), ['id','nombre','cafeteria_id','cafeteria_nombre','tipo','estado','vigencia_desde','vigencia_hasta','tasa_descuento','tasa_comision','estado_vigencia']);
  assert.equal(futura.nombre, 'Futura activa');
  assert.equal(Number(futura.cafeteria_id), 1);
  assert.equal(futura.tipo, 'carrito_completo');
  assert.equal(futura.estado_vigencia, 'futura');
  assert.equal(futura.cafeteria_nombre, 'Cafetería A — prueba V04');
  assert.equal(Number(futura.tasa_descuento), 12.5);
  assert.equal(Number(futura.tasa_comision), 8);
  assert.equal(filas.find(row => Number(row.id) === 12).estado_vigencia, 'en_curso');
  assert.equal(filas.find(row => Number(row.id) === 11).estado, 'pendiente_aceptacion');
  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.listar_oportunidades_campana(2);'), '1', 'filtra cafetería');
  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.listar_oportunidades_campana(999);'), '0', 'sin filas equivale a []');
  assert.equal(sql(sesion(10) + " SELECT count(*) FROM public.listar_oportunidades_campana(1) WHERE estado IN ('borrador','pausada','finalizada') OR vigencia_hasta<=statement_timestamp();"), '0', 'excluye estados no postulables y vencidas');
  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.campanas;'), '0', 'la RPC no cambia el SELECT directo protegido por RLS');

  assert.equal(sql("SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated; SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(1)','42501');"), '', 'sesión sin uid');
  for (const id of [1, 4, 12]) {
    assert.equal(sql(sesion(id) + " SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(1)','42501');"), '', 'cuenta no estudiante activa ' + id);
  }
  assert.equal(sql("SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE anon; SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(1)','42501');"), '', 'anon bloqueado');
  assert.equal(sql(sesion(10) + " SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(NULL)','22023');"), '', 'parámetro nulo inválido');
  assert.equal(sql(sesion(10) + " SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(-1)','22023');"), '', 'parámetro negativo inválido');
  console.log('S3-T4: contrato, vigencia, estados, identidad y permisos aprobados.');
}).catch(error => { console.error(error.stderr?.toString() || error.stack); throw error; });
