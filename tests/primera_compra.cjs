const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const preparar = require('./helpers/afiliaciones.cjs');
const leer = nombre => fs.readFileSync(path.join(__dirname, '../supabase/migrations', nombre), 'utf8');
const migracion = leer('20261120204414_validar_primera_compra.sql');

conBaseTemporal('v07', async ({ sql, sqlAsync }) => {
  preparar(sql);
  sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(fs.readFileSync(path.join(__dirname, 'fixtures/afiliaciones.sql'), 'utf8'));
  sql(leer('0021_autorizar_solicitudes_afiliacion.sql'));
  sql(leer('0022_s3_t5_crear_tabla_promociones.sql'));
  sql(leer('20261117175958_cotizar_carrito_afiliado.sql'));

  const definicion = sql("SELECT pg_get_functiondef('afiliados_privado.cotizar_carrito(bigint,jsonb,text)'::regprocedure)");
  assert.throws(() => sql(migracion.replace("NOTIFY pgrst, 'reload schema';", 'SELECT 1/0;')), /Command failed/);
  assert.equal(sql("SELECT to_regprocedure('afiliados_privado.tiene_compra_previa(bigint,bigint,bigint)') IS NULL"), 't');
  assert.equal(sql("SELECT pg_get_functiondef('afiliados_privado.cotizar_carrito(bigint,jsonb,text)'::regprocedure)"), definicion);
  sql(migracion);

  const previa = (usuario, cafeteria) => sql(`SELECT afiliados_privado.tiene_compra_previa(${usuario},${cafeteria})`);
  const pedido = (id, usuario, cafeteria = 1) => `INSERT INTO pedidos(id,usuario_id,cafeteria_id,estado,pago_estado,total)
    VALUES(${id},${usuario},${cafeteria},'pendiente','pagado',1000);`;
  const comision = (id, cafeteria = 1, monto = 100) => `INSERT INTO movimientos_comision(afiliacion_id,pedido_id,tipo,base_calculo_clp,tasa_comision,monto_clp)
    VALUES(${cafeteria === 1 ? 104 : 105},${id},'comision',1000,10,${monto});`;
  assert.equal(previa(10,1), 'f');
  assert.equal(previa(11,1), 't'); // Pedido 203: historial sin código.
  assert.equal(previa(11,2), 'f');
  sql("INSERT INTO pedidos(id,usuario_id,cafeteria_id,estado,pago_estado,total) VALUES (300,10,1,'cancelado','pagado',100),(301,10,1,'pendiente','fallido',100)");
  assert.equal(previa(10,1), 'f');

  // Ejercitar la RPC pública con identidad del JWT y precios reales.
  sql(`UPDATE campanas SET tasa_descuento=15,tasa_descuento_oferta=5,version_condiciones='v07' WHERE id IN(1,2);
    UPDATE campanas SET confirmada_por_dueno=true,fecha_confirmacion=now(),usuario_confirma_id=CASE id WHEN 1 THEN 1 ELSE 3 END,
      version_confirmada=version_condiciones WHERE id IN(1,2);
    INSERT INTO productos(id,cafeteria_id,nombre,precio) VALUES(401,1,'Producto A',1000),(402,2,'Producto B',1000);`);
  const cotizar = (usuario, cafeteria, codigo) => JSON.parse(sql(`SET SESSION AUTHORIZATION cf_v04_authenticator;
    SET ROLE authenticated; SET request.jwt.claim.sub='00000000-0000-0000-0000-${String(usuario).padStart(12,'0')}';
    SELECT row_to_json(c) FROM public.cotizar_carrito_afiliado(${cafeteria},
      '[{"producto_id":${cafeteria === 1 ? 401 : 402},"cantidad":1}]','${codigo}') c;`));
  assert.deepEqual(cotizar(11,1,'CAFE-11'), { subtotal:1000, descuento_afiliado:0, total:1000, comision:0, motivo:'beneficio_usado' });
  assert.equal(cotizar(11,2,'OTRA-11').motivo, null);
  assert.equal(cotizar(10,1,'CAFE-11').total, 850);
  assert.equal(cotizar(11,1,'').motivo, 'sin_codigo');

  for (const rol of ['anon','authenticated','service_role']) {
    for (const funcion of ['tiene_compra_previa(bigint,bigint,bigint)','bloquear_comprador(bigint,bigint)',
      'serializar_compra()','validar_primera_compra()']) {
      assert.equal(sql(`SELECT has_function_privilege('${rol}','afiliados_privado.${funcion}','EXECUTE')`), 'f');
    }
  }
  assert.throws(() => sql('BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT afiliados_privado.bloquear_comprador(10,1);'), /Command failed/);
  sql(`BEGIN; ${pedido(302,10)} ROLLBACK;`);
  assert.equal(previa(10,1), 'f');
  sql(`BEGIN; ${pedido(303,11)} SELECT test_rechaza($q$${comision(303)}$q$,'23514'); ROLLBACK;`);

  // Observar el bloqueo real antes de iniciar el segundo comprador.
  let barrera = 717500;
  const esperar = async consulta => {
    for (let intento = 0; intento < 150; intento++) {
      if (sql(consulta) === 't') return;
      await new Promise(resolve => setTimeout(resolve,10));
    }
    throw new Error('No se observó la barrera de concurrencia');
  };
  const competir = async (primera, segunda, rechaza = true, cierre = 'COMMIT') => {
    const clave = ++barrera;
    const a = sqlAsync(`BEGIN; ${primera} SELECT pg_advisory_xact_lock(${clave}); SELECT pg_sleep(1); ${cierre};`);
    // Adjuntar de inmediato los manejadores evita rechazos sin observar.
    const resultadoA = a.then(valor => ({valor}), error => ({error}));
    await esperar(`SELECT EXISTS(SELECT FROM pg_locks WHERE locktype='advisory' AND objid=${clave} AND granted)`);
    const b = sqlAsync(`SET application_name='v07_segunda'; BEGIN; ${segunda} COMMIT;`);
    const resultadoB = b.then(valor => ({valor}), error => ({error}));
    await esperar("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='v07_segunda' AND wait_event='advisory')");
    const [finA,finB] = await Promise.all([resultadoA,resultadoB]);
    if (finA.error) throw finA.error;
    if (rechaza) assert.match(finB.error?.message || '', /beneficio_usado/);
    else if (finB.error) throw finB.error;
  };
  await competir(pedido(310,13)+comision(310), pedido(311,13)+comision(311));
  assert.equal(sql('SELECT count(*) FROM pedidos WHERE id IN(310,311)'), '1');
  assert.equal(sql('SELECT count(*) FROM movimientos_comision WHERE pedido_id IN(310,311)'), '1');

  await competir(pedido(320,14), pedido(321,14)+comision(321));
  assert.equal(previa(14,1), 't');
  assert.equal(previa(14,2), 'f');
  assert.equal(sql('SELECT count(*) FROM pedidos WHERE id=321'), '0');

  // Un rollback libera el bloqueo y no consume la primera compra.
  await competir(pedido(330,10)+comision(330), pedido(331,10)+comision(331), false, 'ROLLBACK');
  assert.equal(sql('SELECT count(*) FROM pedidos WHERE id IN(330,331)'), '1');
  assert.equal(sql('SELECT count(*) FROM movimientos_comision WHERE pedido_id=331'), '1');
  // El mismo usuario conserva elegibilidad en otra cafetería.
  sql(`BEGIN; ${pedido(332,10,2)} ${comision(332,2)} COMMIT;`);
  assert.equal(previa(10,2), 't');
  // Código propio con comisión cero también consume la primera compra local.
  sql(`BEGIN; ${pedido(340,11,2)} ${comision(340,2,0)} COMMIT;`);
  assert.equal(cotizar(11,2,'OTRA-11').motivo, 'beneficio_usado');
  assert.equal(sql('SELECT monto_clp FROM movimientos_comision WHERE pedido_id=340'), '0');

  // La compra con código no impide que después se pague una compra sin código.
  sql(`BEGIN; ${pedido(341,13)} COMMIT;`);
  assert.equal(sql('SELECT count(*) FROM pedidos WHERE usuario_id=13 AND cafeteria_id=1'), '2');

  // El bloqueo de una cafetería no serializa compras del mismo usuario en otra.
  const clave = ++barrera;
  const a = sqlAsync(`BEGIN; ${pedido(350,1)} ${comision(350)}
    SELECT pg_advisory_xact_lock(${clave}); SELECT pg_sleep(1); COMMIT;`);
  const resultado = a.then(valor => ({valor}), error => ({error}));
  await esperar(`SELECT EXISTS(SELECT FROM pg_locks WHERE locktype='advisory' AND objid=${clave} AND granted)`);
  sql(`SET lock_timeout='200ms'; BEGIN; ${pedido(351,1,2)} ${comision(351,2)} COMMIT;`);
  const fin = await resultado;
  if (fin.error) throw fin.error;
  assert.equal(sql('SELECT count(*) FROM movimientos_comision WHERE pedido_id IN(350,351)'), '2');
  console.log('V07 aprobado: cotización real, historial sin código, aislamiento por cafetería, permisos, rollback y tres carreras entre sesiones.');
}).catch(error => { console.error(error); process.exitCode = 1; });
