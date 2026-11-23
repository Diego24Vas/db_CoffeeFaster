const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const prepararAfiliaciones = require('./helpers/afiliaciones.cjs');

const leer = (archivo) => fs.readFileSync(path.join(__dirname, archivo), 'utf8');
const sesion = (id) => `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;
  SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-${String(id).padStart(12, '0')}',false);`;
const solicitar = (id, monto) => `${sesion(id)} SELECT public.registrar_retiro_simulado(${monto});`;
const respuesta = (salida) => JSON.parse(salida.split('\n').at(-1));

conBaseTemporal('v13', async ({ sql, sqlAsync }) => {
  prepararAfiliaciones(sql);
  sql(leer('../supabase/migrations/0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(leer('fixtures/afiliaciones.sql'));
  for (const migracion of [
    '0021_autorizar_solicitudes_afiliacion.sql',
    '0022_s3_t5_crear_tabla_promociones.sql',
    '20261117175958_cotizar_carrito_afiliado.sql',
    '20261118211348_consulta_saldo_afiliado.sql',
    '20261123014935_registrar_retiro_simulado.sql'
  ]) {
    sql(leer(`../supabase/migrations/${migracion}`));
  }

  const saldo = (id) => respuesta(sql(`${sesion(id)}
    SELECT row_to_json(s) FROM public.consultar_saldo_afiliado() s;`));
  const historial = () => JSON.parse(sql(`SELECT coalesce(jsonb_agg(r.monto_clp ORDER BY r.id), '[]')
    FROM public.retiros_afiliado r;`));
  const saldoInicial = { pendiente_clp: 500, disponible_clp: 1000, retirado_clp: 0 };
  const sinFondos = { ok: false, motivo: 'saldo_insuficiente' };

  sql("UPDATE public.movimientos_comision SET estado='disponible' WHERE id=301;");
  assert.deepEqual(saldo(11), saldoInicial);
  assert.deepEqual(respuesta(sql(solicitar(11, 1001))), sinFondos);
  assert.deepEqual(respuesta(sql(solicitar(10, 1))), sinFondos);
  for (const monto of ['NULL', '0', '-1', '1.5', "'NaN'::numeric", '9223372036854775808']) {
    assert.deepEqual(respuesta(sql(solicitar(11, monto))), { ok: false, motivo: 'monto_invalido' });
  }
  await assert.rejects(sqlAsync('SET ROLE anon; SELECT public.registrar_retiro_simulado(1);'), /permission denied/);
  await assert.rejects(sqlAsync(solicitar(1, 1)), /sesión de un estudiante activo/);
  await assert.rejects(sqlAsync(`${sesion(11)} BEGIN ISOLATION LEVEL REPEATABLE READ;
    SELECT public.registrar_retiro_simulado(1); COMMIT;`), /READ COMMITTED/);
  assert.deepEqual(historial(), []);
  assert.deepEqual(saldo(11), saldoInicial);

  const resultados = (await Promise.all([
    sqlAsync(solicitar(11, 600)),
    sqlAsync(solicitar(11, 600))
  ])).map(respuesta);
  assert.deepEqual(resultados.find((r) => r.ok), {
    ok: true, monto_clp: 600, destino: 'Cuenta de prueba CoffeeFast (destino ficticio)', disponible_clp: 400
  });
  assert.deepEqual(resultados.find((r) => !r.ok), sinFondos);
  assert.deepEqual(historial(), [600]);
  assert.deepEqual(saldo(11), { pendiente_clp: 500, disponible_clp: 400, retirado_clp: 600 });

  assert.equal(respuesta(sql(solicitar(11, 400))).disponible_clp, 0);
  assert.deepEqual(respuesta(sql(solicitar(11, 1))), sinFondos);
  assert.deepEqual(historial(), [600, 400]);
  assert.deepEqual(saldo(11), { pendiente_clp: 500, disponible_clp: 0, retirado_clp: 1000 });
  assert.deepEqual(saldo(10), { pendiente_clp: 0, disponible_clp: 0, retirado_clp: 0 });

  console.log('V13 aprobado: saldo insuficiente e importe inválido sin escrituras, aislamiento, retiros concurrentes y saldo exacto.');
}).catch((error) => { console.error(error.stderr?.toString() || error); process.exitCode = 1; });
