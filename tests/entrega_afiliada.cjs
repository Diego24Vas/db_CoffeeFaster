const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const prepararAfiliaciones = require('./helpers/afiliaciones.cjs');

const leer = (archivo) => fs.readFileSync(path.join(__dirname, archivo), 'utf8');
const confirmar = (pedido, cafeteria, credencial) => `SET ROLE service_role;
  SELECT count(*) FROM public.confirmar_entrega_pedido(${pedido}, ${cafeteria}, '${credencial}');`;

conBaseTemporal('v11', async ({ sql, sqlAsync }) => {
  prepararAfiliaciones(sql);
  sql(leer('../supabase/migrations/0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(leer('fixtures/afiliaciones.sql'));
  sql(leer('../supabase/migrations/20261122193030_habilitar_comision_en_entrega.sql'));
  // PostgreSQL aislado no trae los permisos de pedidos que Supabase da al backend.
  sql('GRANT SELECT, UPDATE ON public.pedidos TO service_role;');

  sql(`UPDATE pedidos SET estado=' Listo ', qr_usado=NULL, qr_token='QR-201', codigo_retiro_diario='TOKEN-201' WHERE id=201;
    UPDATE pedidos SET estado='listo', qr_token='QR-202' WHERE id=202;
    UPDATE pedidos SET estado='listo', codigo_retiro_diario='TOKEN-203' WHERE id=203;
    UPDATE pedidos SET qr_token='QR-204' WHERE id=204;
    UPDATE campanas SET estado='pausada' WHERE id=1;`);

  const pedido = (id) => sql(`SELECT to_jsonb(p) FROM pedidos p WHERE id=${id};`);
  const comision = (id) => JSON.parse(sql(`SELECT to_jsonb(m) FROM movimientos_comision m WHERE pedido_id=${id};`));
  const antes = pedido(201);
  const historica = comision(201);

  assert.equal(sql(confirmar(201, 1, 'qr-201')), '0', 'QR de texto distingue mayúsculas');
  assert.equal(sql(confirmar(201, 2, 'QR-201')), '0', 'cafetería ajena');
  assert.equal(sql(confirmar(204, 1, 'QR-204')), '0', 'pedido aún no listo');
  assert.equal(pedido(201), antes);
  assert.deepEqual(comision(201), historica);

  const resultados = await Promise.all([
    sqlAsync(confirmar(201, 1, 'QR-201')),
    sqlAsync(confirmar(201, 1, 'TOKEN-201'))
  ]);
  assert.deepEqual(resultados.sort(), ['0', '1']);
  const entregado = pedido(201);
  const { estado, qr_usado, entregado_en } = JSON.parse(entregado);
  assert.equal(estado, 'entregado');
  assert.equal(qr_usado, true);
  assert.ok(entregado_en);
  const disponible = comision(201);
  assert.deepEqual(disponible, { ...historica, estado: 'disponible', actualizado_en: disponible.actualizado_en });

  assert.equal(sql(confirmar(201, 1, 'TOKEN-201')), '0');
  assert.equal(pedido(201), entregado);
  assert.deepEqual(comision(201), disponible);
  assert.equal(sql(confirmar(203, 1, 'TOKEN-203')), '1', 'entrega sin afiliación');
  assert.equal(sql('SELECT count(*) FROM movimientos_comision WHERE pedido_id=203;'), '0');

  const antesDelFallo = pedido(202);
  const comisionAntesDelFallo = comision(202);
  sql(`CREATE FUNCTION public.test_rechazar_acreditacion() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Fallo controlado al acreditar' USING ERRCODE = '23514'; END; $$;
    CREATE TRIGGER test_rechazar_acreditacion BEFORE UPDATE ON movimientos_comision
    FOR EACH ROW EXECUTE FUNCTION public.test_rechazar_acreditacion();`);
  await assert.rejects(sqlAsync(confirmar(202, 2, 'QR-202')), /Fallo controlado al acreditar/);
  assert.equal(pedido(202), antesDelFallo);
  assert.deepEqual(comision(202), comisionAntesDelFallo);
  sql('DROP TRIGGER test_rechazar_acreditacion ON movimientos_comision;');

  // Algunos entornos tienen qr_token como UUID en vez de texto.
  sql(`UPDATE pedidos SET qr_token=NULL;
    ALTER TABLE pedidos ALTER COLUMN qr_token TYPE uuid USING qr_token::uuid;
    UPDATE pedidos SET qr_token='abcdef00-1234-4234-8234-123456789abc' WHERE id=202;`);
  assert.equal(sql(confirmar(202, 2, 'ABCDEF00123442348234123456789ABC')), '1');
  assert.equal(comision(202).estado, 'disponible');
  console.log('APROBADO V11: entrega, comisión histórica, reintentos concurrentes y reversión ante fallo.');
}).catch((error) => { console.error(error.stderr?.toString() || error.message); process.exitCode = 1; });
