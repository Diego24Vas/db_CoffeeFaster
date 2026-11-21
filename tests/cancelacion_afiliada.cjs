const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const temporal = require('./helpers/postgres.cjs');
const preparar = require('./helpers/afiliaciones.cjs');
const leer = nombre => fs.readFileSync(path.join(__dirname, '../supabase/migrations', nombre), 'utf8');
const version = '20261121200029_revertir_comision_cancelacion.sql';
const sesion = usuario => `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;
  SET request.jwt.claim.sub='00000000-0000-0000-0000-${String(usuario).padStart(12, '0')}';`;

temporal('v09', async ({ sql, sqlAsync }) => {
  preparar(sql);
  sql(leer('0006_funciones_y_triggers_wallet.sql'));
  sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(fs.readFileSync(path.join(__dirname, 'fixtures/afiliaciones.sql'), 'utf8'));
  for (const nombre of ['0021_autorizar_solicitudes_afiliacion.sql', '0022_s3_t5_crear_tabla_promociones.sql',
    '20261117175958_cotizar_carrito_afiliado.sql', '20261120204414_validar_primera_compra.sql',
    '20261120210809_registrar_afiliacion_pago.sql']) sql(leer(nombre));
  sql(`INSERT INTO auth.users SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid FROM generate_series(21,40) n;
    INSERT INTO usuarios(id,rol_id,nombre,email,password_hash,auth_user_id)
    SELECT n,1,'V09 '||n,'v09-'||n||'@example.invalid','sin-login',
      ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid FROM generate_series(21,40) n;
    UPDATE wallets SET saldo_actual=100000;
    INSERT INTO metodos_pago(codigo,nombre) VALUES('WALLET','Wallet');
    UPDATE campanas SET tasa_descuento=15,tasa_descuento_oferta=5,version_condiciones='v09';
    UPDATE campanas SET confirmada_por_dueno=true,fecha_confirmacion=now(),usuario_confirma_id=CASE id WHEN 1 THEN 1 ELSE 3 END,
      version_confirmada=version_condiciones;
    INSERT INTO productos(id,cafeteria_id,nombre,precio,stock) VALUES(401,1,'Normal',1000,100),(403,2,'Otra',2000,100);`);
  // Instalar también la firma anterior para verificar la actualización y el rollback de DDL.
  sql(leer('0014_rpc_cancelar_pedido_y_seguridad_cuenta.sql').split('-- 2. ELIMINAR')[0]);
  const anterior = sql("SELECT pg_get_functiondef('public.cancelar_pedido(bigint)'::regprocedure)");
  assert.throws(() => sql(leer(version).replace("NOTIFY pgrst, 'reload schema';", 'SELECT 1/0;')), /Command failed/);
  assert.equal(sql("SELECT pg_get_functiondef('public.cancelar_pedido(bigint)'::regprocedure)"), anterior);
  assert.equal(sql("SELECT to_regprocedure('afiliados_privado.cancelar_pedido(bigint)') IS NULL"), 't');
  sql(leer(version));
  const comprar = (usuario, codigo = 'CAFE-11', cafeteria = 1) => JSON.parse(sql(sesion(usuario) +
    `SELECT public.procesar_pago(${cafeteria},'[{"producto_id":${cafeteria === 1 ? 401 : 403},"cantidad":1}]',
      '12:30-12:45',${codigo === null ? 'NULL' : `'${codigo}'`},${codigo === null ? 1000 : cafeteria === 1 ? 850 : 1700},'v09-${usuario}');`));
  const cancelar = (usuario, pedido) => JSON.parse(sql(sesion(usuario) + `SELECT public.cancelar_pedido(${pedido});`));
  const estado = () => sql(`SELECT jsonb_build_array(
    (SELECT jsonb_agg(to_jsonb(w) ORDER BY id) FROM wallets w),
    (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM productos p),
    (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM pedidos p),
    (SELECT jsonb_agg(to_jsonb(m) ORDER BY id) FROM movimientos_wallet m),
    (SELECT jsonb_agg(to_jsonb(m) ORDER BY id) FROM movimientos_comision m))`);
  const comprobar = (pedido, monto, comision) => {
    assert.equal(sql(`SELECT estado='cancelado' AND NOT stock_descontado FROM pedidos WHERE id=${pedido}`), 't');
    assert.equal(sql(`SELECT count(*)=1 AND sum(monto)=${monto} FROM movimientos_wallet WHERE pedido_id=${pedido} AND tipo='reembolso'`), 't');
    if (comision !== null) {
      assert.equal(sql(`SELECT count(*)=2 AND sum(monto_clp)=0 AND bool_and(estado='revertida')
        FROM movimientos_comision WHERE pedido_id=${pedido}`), 't');
      assert.equal(sql(`SELECT r.movimiento_origen_id=c.id AND r.monto_clp=-${comision}
        AND r.afiliacion_id=c.afiliacion_id AND r.base_calculo_clp=c.base_calculo_clp AND r.tasa_comision=c.tasa_comision
        FROM movimientos_comision c JOIN movimientos_comision r ON r.movimiento_origen_id=c.id
        WHERE c.pedido_id=${pedido}`), 't');
    } else assert.equal(sql(`SELECT count(*) FROM movimientos_comision WHERE pedido_id=${pedido}`), '0');
  };

  const compra = comprar(21);
  assert.equal(compra.ok, true);
  const stock = Number(sql('SELECT stock FROM productos WHERE id=401'));
  // Los precios y el estado actuales no afectan el importe histórico a revertir.
  sql("UPDATE campanas SET estado='pausada' WHERE id=1; UPDATE solicitudes_afiliacion SET codigo_activo=false WHERE id=104; UPDATE productos SET precio=1300 WHERE id=401");
  assert.deepEqual(cancelar(21, compra.pedido_id), { ok: true, pedido_id: compra.pedido_id, estado: 'cancelado', monto_reembolsado: 850, saldo_nuevo: 100000 });
  comprobar(compra.pedido_id, 850, 85);
  assert.equal(Number(sql('SELECT stock FROM productos WHERE id=401')), stock + 1);
  const despues = estado();
  assert.equal(cancelar(21, compra.pedido_id).motivo, 'ya_cancelado');
  assert.equal(estado(), despues);
  sql("UPDATE campanas SET estado='activa' WHERE id=1; UPDATE solicitudes_afiliacion SET codigo_activo=true WHERE id=104; UPDATE productos SET precio=1000 WHERE id=401");

  const normal = comprar(22, null);
  assert.equal(cancelar(22, normal.pedido_id).monto_reembolsado, 1000);
  comprobar(normal.pedido_id, 1000, null);
  const propio = comprar(11, 'OTRA-11', 2);
  assert.equal(cancelar(11, propio.pedido_id).ok, true);
  comprobar(propio.pedido_id, 1700, 0);
  // Pedidos históricos sin descuento de inventario no reponen existencias.
  sql('UPDATE wallets SET saldo_actual=0 WHERE usuario_id=20');
  const stockHistorico = sql('SELECT stock FROM productos WHERE id=401');
  assert.equal(cancelar(20, 201).monto_reembolsado, 10000);
  comprobar(201, 10000, 1000);
  assert.equal(sql('SELECT stock FROM productos WHERE id=401'), stockHistorico);

  const rechazado = comprar(23);
  const antesRechazo = estado();
  assert.equal(cancelar(24, rechazado.pedido_id).motivo, 'no_autorizado');
  assert.equal(cancelar(23, 999999).motivo, 'pedido_no_encontrado');
  assert.equal(cancelar(23, 'NULL').motivo, 'pedido_no_encontrado');
  assert.equal(estado(), antesRechazo);
  for (const estadoPedido of ['en_preparacion', 'listo', 'entregado']) {
    sql(`UPDATE pedidos SET estado='${estadoPedido}' WHERE id=${rechazado.pedido_id}`);
    const antes = estado();
    assert.equal(cancelar(23, rechazado.pedido_id).motivo, 'no_cancelable');
    assert.equal(estado(), antes);
  }
  sql(`UPDATE pedidos SET estado='pendiente' WHERE id=${rechazado.pedido_id};
    UPDATE movimientos_comision SET estado='disponible' WHERE pedido_id=${rechazado.pedido_id}`);
  const inconsistente = estado();
  assert.throws(() => cancelar(23, rechazado.pedido_id), /Command failed/);
  assert.equal(estado(), inconsistente);

  const fallida = comprar(25);
  sql(`CREATE FUNCTION public.fallar_v09() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
    IF NEW.tipo='reversion' THEN RAISE EXCEPTION 'fallo_controlado_v09'; END IF; RETURN NEW; END $$;
    CREATE TRIGGER fallar_v09 BEFORE INSERT ON movimientos_comision FOR EACH ROW EXECUTE FUNCTION fallar_v09();`);
  const antesFallo = estado();
  assert.throws(() => cancelar(25, fallida.pedido_id), /Command failed/);
  assert.equal(estado(), antesFallo);
  sql('DROP TRIGGER fallar_v09 ON movimientos_comision; DROP FUNCTION fallar_v09()');
  assert.equal(cancelar(25, fallida.pedido_id).ok, true);
  comprobar(fallida.pedido_id, 850, 85);

  for (const usuario of [26, 27]) {
    const pedido = comprar(usuario).pedido_id;
    sql(`UPDATE wallets SET saldo_actual=${usuario === 26 ? 2147483647 : 0} WHERE usuario_id=${usuario}`);
    if (usuario === 27) sql(`DELETE FROM movimientos_wallet WHERE wallet_id IN (SELECT id FROM wallets WHERE usuario_id=27); DELETE FROM wallets WHERE usuario_id=27`);
    const antes = estado();
    assert.equal(cancelar(usuario, pedido).motivo, usuario === 26 ? 'saldo_invalido' : 'sin_wallet');
    assert.equal(estado(), antes);
  }
  // Permisos reales: la API pública es invoker y el núcleo privilegiado es privado.
  for (const rol of ['anon', 'authenticated', 'service_role']) {
    for (const esquema of ['public', 'afiliados_privado']) assert.equal(sql(`SELECT has_function_privilege('${rol}','${esquema}.cancelar_pedido(bigint)','EXECUTE')`), rol === 'authenticated' ? 't' : 'f');
  }
  assert.equal(sql("SELECT NOT prosecdef FROM pg_proc WHERE oid='public.cancelar_pedido(bigint)'::regprocedure"), 't');
  assert.throws(() => sql('SET ROLE authenticated; SELECT public.cancelar_pedido(201)'), /Command failed/);
  assert.throws(() => sql('SET ROLE anon; SELECT public.cancelar_pedido(201)'), /Command failed/);

  const concurrente = comprar(28);
  const a = sqlAsync(`BEGIN; SET application_name='v09_primera'; ${sesion(28)} SELECT public.cancelar_pedido(${concurrente.pedido_id}); SELECT pg_sleep(2); COMMIT;`);
  const finA = a.then(valor => ({ valor }), error => ({ error }));
  const esperar = async consulta => {
    for (let i = 0; i < 150; i++) {
      if (sql(consulta) === 't') return;
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.fail('No se observó el bloqueo esperado');
  };
  await esperar("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='v09_primera' AND wait_event='PgSleep')");
  const b = sqlAsync(`SET application_name='v09_segunda'; ${sesion(28)} SELECT public.cancelar_pedido(${concurrente.pedido_id});`);
  const finB = b.then(valor => ({ valor }), error => ({ error }));
  await esperar("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE application_name='v09_segunda' AND wait_event_type='Lock')");
  const [ra, rb] = await Promise.all([finA, finB]);
  if (ra.error) throw ra.error;
  if (rb.error) throw rb.error;
  assert.equal(JSON.parse(ra.valor.split('\n')[0]).ok, true);
  assert.equal(JSON.parse(rb.valor).motivo, 'ya_cancelado');
  comprobar(concurrente.pedido_id, 850, 85);
  assert.equal(sql('SELECT saldo_actual FROM wallets WHERE usuario_id=28'), '100000');
  console.log('V09 aprobado: reembolso histórico, compensación vinculada, stock, cero comisión, sin afiliación, rechazos, permisos, rollback y concurrencia real.');
}).catch(error => { console.error(error); process.exitCode = 1; });
