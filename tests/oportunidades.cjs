const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const prepararAfiliaciones = require('./helpers/afiliaciones.cjs');
const migrations = path.join(__dirname, '../supabase/migrations');
const leer = name => fs.readFileSync(path.join(migrations, name), 'utf8');
const sesion = id => 'SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;\n' +
  "SET request.jwt.claim.sub = '00000000-0000-0000-0000-" + String(id).padStart(12, '0') + "';";

module.exports = conBaseTemporal('oportunidades', async ({ sql }) => {
  prepararAfiliaciones(sql);
  sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(fs.readFileSync(path.join(__dirname, 'fixtures/afiliaciones.sql'), 'utf8'));
  sql(leer('0023_s3_t4_rpc_listar_oportunidades_campana.sql'));
  sql(leer('0024_s3_t4_rpc_campanas_vigentes.sql'));

  // La cafetería 2 queda inactiva; la 3 está activa y la 4 está activa sin campañas.
  sql(`UPDATE public.cafeterias SET activa = false WHERE id = 2;
    INSERT INTO public.cafeterias(id,nombre,activa) VALUES
      (3,'Cafetería C — prueba S3-T4',true),
      (4,'Cafetería D — prueba S3-T4',true);
    INSERT INTO public.campanas(id,cafeteria_id,nombre,estado,tasa_descuento,tasa_comision,vigencia_desde,vigencia_hasta)
    OVERRIDING SYSTEM VALUE VALUES
      (10,1,'Futura activa','activa',12.50,8.00,statement_timestamp()+interval '2 days',statement_timestamp()+interval '5 days'),
      (11,1,'Futura pendiente de aceptación','pendiente_aceptacion',5.00,4.00,statement_timestamp()+interval '1 day',statement_timestamp()+interval '3 days'),
      (12,1,'En curso aceptada','aceptada',15.00,7.00,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day'),
      (13,1,'Borrador','borrador',0,0,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day'),
      (14,1,'Pausada','pausada',0,0,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day'),
      (15,1,'Finalizada','finalizada',0,0,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day'),
      (16,1,'Vencida','activa',0,0,statement_timestamp()-interval '2 days',statement_timestamp()-interval '1 day'),
      (17,3,'Otra cafetería activa','activa',9.00,3.00,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day'),
      (18,1,'Vigente con tasas','activa',12.50,8.00,statement_timestamp()-interval '1 hour',statement_timestamp()+interval '1 hour'),
      (19,1,'En curso pendiente de aceptación','pendiente_aceptacion',5.00,4.00,statement_timestamp()-interval '1 day',statement_timestamp()+interval '1 day'),
      (20,1,'Inicio inclusivo','activa',1.00,2.00,statement_timestamp(),statement_timestamp()+interval '1 hour'),
      (21,1,'Fin exclusivo','activa',1.00,2.00,statement_timestamp()-interval '1 hour',statement_timestamp());`);

  assert.equal(sql("SELECT has_function_privilege('authenticated','public.listar_oportunidades_campana(bigint)','EXECUTE') AND NOT has_function_privilege('anon','public.listar_oportunidades_campana(bigint)','EXECUTE') AND NOT has_function_privilege('service_role','public.listar_oportunidades_campana(bigint)','EXECUTE')"), 't', 'solo authenticated recibe EXECUTE');
  assert.equal(sql("SELECT has_function_privilege('authenticated','public.obtener_campana_vigente(bigint)','EXECUTE') AND has_function_privilege('authenticated','public.confirmar_condiciones_campana(bigint,bigint,text)','EXECUTE')"), 't', 'se conservan las RPC anteriores');

  const filas = JSON.parse(sql(sesion(10) + " SELECT coalesce(json_agg(row_to_json(o) ORDER BY o.id),'[]'::json)::text FROM public.listar_oportunidades_campana(1) o;"));
  assert.deepEqual(filas.map(row => Number(row.id)), [1, 18, 20], 'solo campañas vigentes y activas de la cafetería solicitada');
  assert.deepEqual(Object.keys(filas[0]), ['id','nombre','cafeteria_id','cafeteria_nombre','tipo','estado','vigencia_desde','vigencia_hasta','tasa_descuento','tasa_comision','estado_vigencia']);
  assert.ok(filas.every(row => row.estado_vigencia === 'en_curso'), 'estado_vigencia conserva un valor consistente para vigentes');
  const conTasas = filas.find(row => Number(row.id) === 18);
  assert.equal(conTasas.nombre, 'Vigente con tasas');
  assert.equal(Number(conTasas.cafeteria_id), 1);
  assert.equal(conTasas.cafeteria_nombre, 'Cafetería A — prueba V04');
  assert.equal(conTasas.tipo, 'carrito_completo');
  assert.equal(conTasas.estado, 'activa');
  assert.equal(Number(conTasas.tasa_descuento), 12.5);
  assert.equal(Number(conTasas.tasa_comision), 8);
  assert.ok(conTasas.vigencia_desde && conTasas.vigencia_hasta, 'devuelve ambas fechas');
  assert.ok(filas.every(row => row.estado === 'activa'), 'no devuelve estados no visibles');

  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.listar_oportunidades_campana(2);'), '0', 'excluye cafetería inactiva');
  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.listar_oportunidades_campana(3);'), '1', 'limita a la cafetería solicitada');
  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.listar_oportunidades_campana(4);'), '0', 'cafetería activa sin campañas devuelve lista vacía');
  assert.equal(sql(sesion(10) + " SELECT count(*) FROM public.listar_oportunidades_campana(1) WHERE id IN (10,11,12,13,14,15,16,19,21);"), '0', 'excluye futuras, pendientes, aceptadas, borradores, pausadas, finalizadas, vencidas y fin exclusivo');
  assert.equal(sql(sesion(10) + " SELECT count(*) FROM public.listar_oportunidades_campana(1) WHERE id = 20;"), '1', 'incluye el inicio en el mismo instante de la inserción');
  assert.equal(sql(sesion(10) + " SELECT count(*) FROM public.listar_oportunidades_campana(1) WHERE id = 21;"), '0', 'excluye el fin en el mismo instante de la inserción');
  assert.equal(sql(sesion(10) + " SELECT count(*) FROM public.listar_oportunidades_campana(1) WHERE estado <> 'activa';"), '0', 'solo estado activa');
  assert.equal(sql(sesion(10) + ' SELECT count(*) FROM public.campanas;'), '0', 'la RPC no cambia el SELECT directo protegido por RLS');

  assert.equal(sql("SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated; SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(1)','42501');"), '', 'sesión sin uid');
  for (const id of [1, 4, 12]) {
    assert.equal(sql(sesion(id) + " SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(1)','42501');"), '', 'cuenta no estudiante activa ' + id);
  }
  assert.equal(sql("SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE anon; SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(1)','42501');"), '', 'anon bloqueado');
  assert.equal(sql("SET ROLE service_role; SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(1)','42501'); RESET ROLE;"), '', 'service_role sin EXECUTE');
  assert.equal(sql(sesion(10) + " SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(NULL)','22023');"), '', 'parámetro nulo inválido');
  assert.equal(sql(sesion(10) + " SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(0)','22023');"), '', 'parámetro cero inválido');
  assert.equal(sql(sesion(10) + " SELECT test_rechaza('SELECT * FROM public.listar_oportunidades_campana(-1)','22023');"), '', 'parámetro negativo inválido');
  console.log('S3-T4: contrato de campañas vigentes, estados, cafetería activa, límites, identidad y permisos aprobados.');
}).catch(error => { console.error(error.stderr?.toString() || error.stack); throw error; });
