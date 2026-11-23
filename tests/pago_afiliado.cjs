const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const temporal = require('./helpers/postgres.cjs');
const preparar = require('./helpers/afiliaciones.cjs');
const leer = nombre => fs.readFileSync(path.join(__dirname,'../supabase/migrations',nombre),'utf8');
const version = '20261120210809_registrar_afiliacion_pago.sql';
const sesion = usuario => `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;
  SET request.jwt.claim.sub='00000000-0000-0000-0000-${String(usuario).padStart(12,'0')}';`;
const items = '[{"producto_id":401,"cantidad":1,"precio_esperado":1000}]';
const pagar = (clave, total=850, codigo="'CAFE-11'", carrito=items, cafeteria=1) =>
  `SELECT public.procesar_pago(${cafeteria},'${carrito}'::jsonb,'12:30-12:45',${codigo},${total},'${clave}');`;

temporal('v08', async ({sql,sqlAsync}) => {
  preparar(sql);
  sql(leer('0006_funciones_y_triggers_wallet.sql'));
  sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(fs.readFileSync(path.join(__dirname,'fixtures/afiliaciones.sql'),'utf8'));
  for (const nombre of ['0021_autorizar_solicitudes_afiliacion.sql','0022_s3_t5_crear_tabla_promociones.sql',
    '20261117175958_cotizar_carrito_afiliado.sql','20261120204414_validar_primera_compra.sql']) sql(leer(nombre));
  const legacy = sql("SELECT pg_get_functiondef('public.procesar_pago(bigint,jsonb,text)'::regprocedure)");
  const migracion = leer(version);
  assert.throws(() => sql(migracion.replace("NOTIFY pgrst,'reload schema';",'SELECT 1/0;')), /Command failed/);
  assert.equal(sql("SELECT to_regclass('afiliados_privado.intentos_pago') IS NULL"),'t');
  sql(migracion);
  assert.equal(sql("SELECT pg_get_functiondef('public.procesar_pago(bigint,jsonb,text)'::regprocedure)"),legacy);
  sql(`INSERT INTO auth.users SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid FROM generate_series(21,35) n;
    INSERT INTO usuarios(id,rol_id,nombre,email,password_hash,auth_user_id)
    SELECT n,1,'V08 '||n,'v08-'||n||'@example.invalid','sin-login',
      ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid FROM generate_series(21,35) n;
    UPDATE wallets SET saldo_actual=100000;
    INSERT INTO metodos_pago(codigo,nombre) VALUES('WALLET','Wallet');
    UPDATE campanas SET tasa_descuento=15,tasa_descuento_oferta=5,version_condiciones='v08';
    UPDATE campanas SET confirmada_por_dueno=true,fecha_confirmacion=now(),usuario_confirma_id=CASE id WHEN 1 THEN 1 ELSE 3 END,
      version_confirmada=version_condiciones;
    INSERT INTO productos(id,cafeteria_id,nombre,precio,stock) VALUES(401,1,'Normal',1000,100),(402,1,'Oferta',800,100),(403,2,'Otra',2000,100);
    INSERT INTO promociones(cafeteria_id,producto_id,nombre,descuento_porcentaje) VALUES(1,402,'Oferta mitad',50);`);
  const compra = (usuario, sentencia) => JSON.parse(sql(sesion(usuario)+sentencia));
  const estado = () => sql(`SELECT jsonb_build_array(
    (SELECT jsonb_agg(to_jsonb(w) ORDER BY id) FROM wallets w),
    (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM productos p),
    (SELECT count(*) FROM pedidos),(SELECT count(*) FROM pagos),
    (SELECT count(*) FROM movimientos_wallet),(SELECT count(*) FROM movimientos_comision))`);
  const resultado = compra(10,pagar('primero'));
  assert.equal(resultado.ok,true);
  assert.equal(resultado.total_pagado,850);
  assert.equal(resultado.comision,85);
  assert.equal(resultado.saldo_restante,99150);
  assert.equal(sql('SELECT stock FROM productos WHERE id=401'),'99');
  assert.equal(resultado.codigo_retiro,resultado.codigo_retiro_diario);
  assert.ok(resultado.qr_token && resultado.codigo_pedido);
  assert.equal(sql(`SELECT total=850 AND stock_descontado FROM pedidos WHERE id=${resultado.pedido_id}`),'t');
  assert.equal(sql(`SELECT base_calculo_clp=850 AND tasa_comision=10 AND monto_clp=85 AND estado='pendiente'
    FROM movimientos_comision WHERE pedido_id=${resultado.pedido_id}`),'t');
  assert.equal(sql(`SELECT monto=850 AND estado='aprobado' FROM pagos WHERE pedido_id=${resultado.pedido_id}`),'t');
  assert.equal(sql(`SELECT monto=-850 AND tipo='compra' FROM movimientos_wallet WHERE pedido_id=${resultado.pedido_id}`),'t');
  const despues = estado();
  sql('UPDATE solicitudes_afiliacion SET codigo_activo=false WHERE id=104');
  assert.deepEqual(compra(10,pagar('primero')),resultado); // Respuesta perdida, incluso con código ahora desactivado.
  assert.equal(compra(10,pagar('primero',1000)).motivo,'clave_reintento_en_conflicto');
  assert.equal(estado(),despues);
  const sinCobro = estado();
  const actualizado = compra(21,pagar('desactivado'));
  assert.equal(actualizado.error,'precio_actualizado');
  assert.equal(actualizado.total_actualizado,1000);
  assert.equal(actualizado.motivo,'codigo_desactivado');
  assert.equal(estado(),sinCobro);
  const sinCodigo = compra(21,pagar('reconfirmado',1000,'NULL'));
  assert.equal(sinCodigo.ok,true);
  assert.equal(sql(`SELECT count(*) FROM movimientos_comision WHERE pedido_id=${sinCodigo.pedido_id}`),'0');
  sql('UPDATE solicitudes_afiliacion SET codigo_activo=true WHERE id=104');
  assert.deepEqual(compra(21,pagar('desactivado')),actualizado); // También conserva rechazos por clave.
  assert.equal(compra(13,pagar('primero')).ok,true); // Misma clave, otro usuario.

  for (const [cambio,motivo] of [["UPDATE campanas SET estado='pausada' WHERE id=1",'campana_pausada'],
    ["UPDATE productos SET precio=1200 WHERE id=401",'precio_actualizado']]) {
    const antes = estado();
    const respuesta = JSON.parse(sql(`BEGIN; ${cambio}; ${sesion(22)} ${pagar(motivo)} ROLLBACK;`));
    assert.equal(respuesta.error,'precio_actualizado');
    assert.equal(respuesta.cobrado,false);
    assert.equal(estado(),antes);
  }
  const mixto = compra(22,pagar('mixto',1230,"'CAFE-11'",'[{"producto_id":401,"cantidad":1},{"producto_id":402,"cantidad":1}]'));
  assert.equal(mixto.subtotal,1400);
  assert.equal(mixto.descuento_afiliado,170);
  assert.equal(mixto.comision,123);
  const propia = compra(11,pagar('propio',1700,"'OTRA-11'",'[{"producto_id":403,"cantidad":1}]',2));
  assert.equal(propia.ok,true);
  assert.equal(propia.comision,0);
  assert.equal(sql(`SELECT count(*) FROM movimientos_comision WHERE pedido_id=${propia.pedido_id} AND monto_clp=0`),'1');

  sql('UPDATE wallets SET saldo_actual=0 WHERE usuario_id=24');
  const antesRechazo = estado();
  assert.equal(compra(24,pagar('sin-saldo')).motivo,'saldo_insuficiente');
  assert.equal(estado(),antesRechazo);
  sql('UPDATE wallets SET saldo_actual=100000 WHERE usuario_id=24');
  assert.equal(compra(24,pagar('sin-saldo')).motivo,'saldo_insuficiente');
  assert.equal(compra(24,pagar('recargado')).ok,true);
  const antesStock = estado();
  assert.equal(JSON.parse(sql(`BEGIN; UPDATE productos SET stock=0 WHERE id=401;
    ${sesion(23)} ${pagar('sin-stock')} ROLLBACK;`)).motivo,'stock_insuficiente');
  assert.equal(estado(),antesStock);
  const antesFallo = estado();
  sql(`CREATE FUNCTION public.fallar_v08() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fallo_controlado_v08'; END $$;
    CREATE TRIGGER fallar_v08 BEFORE INSERT ON movimientos_comision FOR EACH ROW EXECUTE FUNCTION fallar_v08();`);
  assert.throws(() => sql(sesion(25)+pagar('rollback')), /Command failed/);
  assert.equal(estado(),antesFallo);
  assert.equal(sql("SELECT count(*) FROM afiliados_privado.intentos_pago WHERE usuario_id=25 AND clave='rollback'"),'0');
  sql('DROP TRIGGER fallar_v08 ON movimientos_comision; DROP FUNCTION fallar_v08()');
  assert.equal(compra(25,pagar('rollback')).ok,true);

  for (const rol of ['anon','authenticated','service_role']) {
    assert.equal(sql(`SELECT has_table_privilege('${rol}','afiliados_privado.intentos_pago','SELECT') OR
      has_table_privilege('${rol}','afiliados_privado.intentos_pago','INSERT')`),'f');
    if (rol!=='authenticated') assert.equal(sql(`SELECT has_function_privilege('${rol}',
      'public.procesar_pago(bigint,jsonb,text,text,bigint,text)','EXECUTE')`),'f');
  }
  assert.throws(() => sql('SET ROLE authenticated; '+pagar('sin-jwt')),/Command failed/);
  assert.throws(() => sql(sesion(12)+pagar('inactivo')),/Command failed/);

  // Primera transacción paga y conserva el bloqueo; la segunda espera de verdad.
  const carrera = async (usuario, claveA, claveB) => {
    const a = sqlAsync(`BEGIN; ${sesion(usuario)} ${pagar(claveA)} SELECT pg_sleep(1); COMMIT;`);
    const finA = a.then(valor=>({valor}),error=>({error}));
    let listo=false;
    for(let i=0;i<150;i++) {
      if(sql("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE wait_event='PgSleep' AND query LIKE '%SELECT pg_sleep(1)%')")==='t') { listo=true; break; }
      await new Promise(resolve=>setTimeout(resolve,10));
    }
    assert.ok(listo,'Primera compra observada antes del segundo intento');
    const b = sqlAsync(`SET application_name='v08_segunda'; ${sesion(usuario)} ${pagar(claveB)}`);
    const finB = b.then(valor=>({valor}),error=>({error}));
    let esperando=false;
    for(let i=0;i<150;i++) {
      if(sql("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='v08_segunda' AND wait_event_type='Lock')")==='t') { esperando=true; break; }
      await new Promise(resolve=>setTimeout(resolve,10));
    }
    const [ra,rb] = await Promise.all([finA,finB]);
    assert.ok(esperando,'Segunda compra esperando el bloqueo');
    if(ra.error) throw ra.error; if(rb.error) throw rb.error;
    return [JSON.parse(ra.valor.split('\n')[0]),JSON.parse(rb.valor)];
  };
  const [uno,repetido] = await carrera(26,'concurrente','concurrente');
  assert.deepEqual(uno,repetido);
  assert.equal(sql('SELECT count(*) FROM pedidos WHERE usuario_id=26'),'1');
  const [primera,segunda] = await carrera(27,'a','b');
  assert.equal(primera.ok,true);
  assert.equal(segunda.error,'precio_actualizado');
  assert.equal(segunda.motivo,'beneficio_usado');
  assert.equal(sql('SELECT count(*) FROM pedidos WHERE usuario_id=27'),'1');

  // V10: cantidades múltiples y una comisión que redondea desde 284,5 CLP.
  sql('UPDATE productos SET precio=1003 WHERE id=401');
  const carritoV10 = '[{"producto_id":401,"cantidad":2},{"producto_id":402,"cantidad":3}]';
  const verificarImportes = (usuario, codigo, esperado) => {
    const cotizacion = compra(usuario, `SELECT to_jsonb(c)
      FROM public.cotizar_carrito_afiliado(1,'${carritoV10}',${codigo}) c;`);
    assert.deepEqual(cotizacion, esperado);
    const confirmar = pagar('v10-mixto', cotizacion.total, codigo, carritoV10);
    const pago = compra(usuario, confirmar);
    assert.equal(pago.ok, true);
    assert.equal(pago.estado, 'pendiente');
    assert.equal(pago.pago_estado, 'pagado');
    assert.equal(pago.total_pagado, cotizacion.total);
    assert.equal(pago.descuento_afiliado, cotizacion.descuento_afiliado);
    assert.equal(pago.comision, cotizacion.comision);
    assert.equal(pago.saldo_restante, 100000 - cotizacion.total);
    assert.equal(sql(`SELECT saldo_actual FROM wallets WHERE usuario_id=${usuario}`), String(pago.saldo_restante));
    const id = pago.pedido_id;
    assert.equal(sql(`SELECT total=${cotizacion.total} AND pago_estado='pagado' FROM pedidos WHERE id=${id}`), 't');
    assert.equal(sql(`SELECT count(*)=1 AND sum(monto)=${cotizacion.total}
      FROM pagos WHERE pedido_id=${id} AND estado='aprobado'`), 't');
    assert.equal(sql(`SELECT count(*)=1 AND sum(monto)=-${cotizacion.total}
      FROM movimientos_wallet WHERE pedido_id=${id} AND tipo='compra'`), 't');
    assert.equal(sql(`SELECT sum(subtotal) FROM detalles_pedido WHERE pedido_id=${id}`), '3206.00');
    const persistido = estado();
    assert.deepEqual(compra(usuario, confirmar), pago);
    assert.equal(estado(), persistido);
    return id;
  };

  const afiliadoV10 = verificarImportes(28, "'CAFE-11'",
    { subtotal: 3206, descuento_afiliado: 361, total: 2845, comision: 285, motivo: null });
  assert.equal(sql(`SELECT count(*)=1 AND bool_and(base_calculo_clp=2845 AND monto_clp=285
    AND tasa_comision=10 AND estado='pendiente' AND tipo='comision')
    FROM movimientos_comision WHERE pedido_id=${afiliadoV10}`), 't');
  const normalV10 = verificarImportes(29, 'NULL',
    { subtotal: 3206, descuento_afiliado: 0, total: 3206, comision: 0, motivo: 'sin_codigo' });
  assert.equal(sql(`SELECT count(*) FROM movimientos_comision WHERE pedido_id=${normalV10}`), '0');
  console.log('V10 aprobado: carrito mixto de 3.206 CLP; cobro afiliado de 2.845 CLP con comisión de 285 CLP; compra normal de 3.206 CLP sin comisión.');
  console.log('V08 aprobado: pago atómico, importes históricos, reconfirmación, desactivación, reintentos, rollback, permisos y concurrencia real.');
}).catch(error=>{ console.error(error); process.exitCode=1; });
