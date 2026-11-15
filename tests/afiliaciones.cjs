const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const prepararAfiliaciones = require('./helpers/afiliaciones.cjs');
const migrations = path.join(__dirname, '../supabase/migrations');
const leer = name => fs.readFileSync(path.join(migrations, name), 'utf8');
const sesion = id => `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;
    SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-${String(id).padStart(12, '0')}',false);`;

conBaseTemporal('v04', async ({ sql, sqlAsync }) => {
  let casos = 0;
  const comprobar = (nombre, sentencia) => { sql(sentencia); casos++; console.log(`APROBADO: ${nombre}`); };
  const rechazar = (nombre, sentencia, codigo = '23514') =>
    comprobar(nombre, `SELECT test_rechaza($prueba$${sentencia}$prueba$,'${codigo}');`);
  const nueva = extra => `INSERT INTO solicitudes_afiliacion(estudiante_id,campana_id,plan_promocion${extra?.columnas || ''})
    VALUES(${extra?.estudiante || 13},${extra?.campana || 1},'Plan ficticio'${extra?.valores || ''})`;
  const comision = extra => `INSERT INTO movimientos_comision(afiliacion_id,pedido_id,tipo,base_calculo_clp,tasa_comision,monto_clp${extra?.columnas || ''})
    VALUES(${extra?.afiliacion || 104},${extra?.pedido || 204},'comision',${extra?.base ?? 8000},${extra?.tasa ?? 10},${extra?.monto ?? 800}${extra?.valores || ''})`;

  prepararAfiliaciones(sql);
  // Supabase puede conceder ALL por defecto: la migración debe revocarlo.
  sql('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;');
  const migration = leer('0020_modelar_afiliaciones_y_movimientos.sql');
  assert.throws(() => sql(migration.replace("NOTIFY pgrst, 'reload schema';", "SELECT 1/0;")), /Command failed/);
  assert.equal(sql("SELECT to_regclass('solicitudes_afiliacion') IS NULL AND to_regclass('movimientos_comision') IS NULL"), 't');
  assert.equal(sql("SELECT to_regprocedure('estudiante_afiliacion_id()') IS NULL AND NOT EXISTS(SELECT FROM pg_trigger WHERE tgname='proteger_ambito_afiliaciones')"), 't');
  casos++; console.log('APROBADO: un fallo de migración revierte ambas tablas');
  sql(migration);
  sql(fs.readFileSync(path.join(__dirname, 'fixtures/afiliaciones.sql'), 'utf8'));
  sql(`SELECT setval(pg_get_serial_sequence('solicitudes_afiliacion','id'),(SELECT max(id) FROM solicitudes_afiliacion));
    SELECT setval(pg_get_serial_sequence('movimientos_comision','id'),(SELECT max(id) FROM movimientos_comision));
    GRANT SELECT ON usuarios,roles,cafeteria_usuarios,campanas,pedidos TO service_role;`);

  comprobar('el estudiante solo ve sus solicitudes y movimientos', `${sesion(11)}
    SELECT test_assert((SELECT count(*)=2 FROM solicitudes_afiliacion),'dos solicitudes propias');
    SELECT test_assert((SELECT count(*)=2 FROM movimientos_comision),'dos movimientos propios');
    SELECT test_assert(NOT EXISTS(SELECT FROM solicitudes_afiliacion WHERE estudiante_id<>11),'sin solicitudes ajenas');`);
  comprobar('otro estudiante no ve comisiones ajenas', `${sesion(10)}
    SELECT test_assert((SELECT count(*)=2 FROM solicitudes_afiliacion),'solicitudes propias');
    SELECT test_assert((SELECT count(*)=0 FROM movimientos_comision),'sin movimientos ajenos');`);
  for (const [usuario, solicitudes, movimientos] of [[1,3,1], [3,2,1], [4,0,0], [12,0,0]]) {
    comprobar(`alcance de lectura de cuenta ${usuario}`, `${sesion(usuario)}
      SELECT test_assert((SELECT count(*)=${solicitudes} FROM solicitudes_afiliacion),'solicitudes autorizadas');
      SELECT test_assert((SELECT count(*)=${movimientos} FROM movimientos_comision),'movimientos autorizados');`);
  }
  comprobar('sin sesión no se revelan solicitudes', `SET ROLE authenticated;
    SELECT test_assert((SELECT count(*)=0 FROM solicitudes_afiliacion),'sin sesión');`);
  comprobar('anon no lee las tablas', `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE anon;
    SELECT test_rechaza('SELECT * FROM solicitudes_afiliacion','42501');
    SELECT test_rechaza('SELECT * FROM movimientos_comision','42501');`);
  comprobar('cliente no crea, aprueba ni borra datos', `${sesion(11)}
    SELECT test_rechaza($q$${nueva()}$q$,'42501');
    SELECT test_rechaza($q$UPDATE solicitudes_afiliacion SET estado='aprobada' WHERE id=104$q$,'42501');
    SELECT test_rechaza($q$UPDATE movimientos_comision SET monto_clp=1 WHERE id=301$q$,'42501');
    SELECT test_rechaza($q$DELETE FROM solicitudes_afiliacion WHERE id=104$q$,'42501');`);
  comprobar('backend no conserva DELETE heredado de privilegios por defecto', `SET ROLE service_role;
    SELECT test_rechaza($q$DELETE FROM solicitudes_afiliacion WHERE id=101$q$,'42501');
    SELECT test_rechaza($q$DELETE FROM movimientos_comision WHERE id=301$q$,'42501');`);

  rechazar('una solicitud repetida no crea otra fila', nueva({ estudiante: 10 }), '23505');
  rechazar('estudiante inexistente o inactivo no puede solicitar', nueva({ estudiante: 12 }));
  rechazar('usuario inexistente no puede solicitar', nueva({ estudiante: 999 }));
  rechazar('un dueño no se registra como estudiante', nueva({ estudiante: 1 }));
  rechazar('pendiente no puede tener código', nueva({ columnas: ',codigo', valores: ",'FALSO'" }));
  rechazar('pendiente no puede tener código activo', nueva({ columnas: ',codigo_activo', valores: ',true' }));
  rechazar('aprobada exige código', nueva({ columnas: ',estado,resuelta_por,resuelta_en', valores: ",'aprobada',1,now()" }));
  rechazar('rechazada no admite código', nueva({ columnas: ',estado,codigo,resuelta_por,resuelta_en', valores: ",'rechazada','FALSO',1,now()" }));
  rechazar('se exige explicación no vacía', "INSERT INTO solicitudes_afiliacion(estudiante_id,campana_id,plan_promocion) VALUES(13,1,E' \\t\\n')");
  rechazar('la resolución no puede atribuirse a un dueño ajeno', nueva({ columnas: ',estado,resuelta_por,resuelta_en', valores: ",'rechazada',3,now()" }));
  const aprobada = codigo => nueva({ campana: 2, columnas: ',estado,codigo,codigo_activo,resuelta_por,resuelta_en', valores: `,'aprobada','${codigo}',true,3,now()` });
  rechazar('código único incluso entre cafeterías', aprobada('CAFE-11'), '23505');
  rechazar('código debe estar normalizado', aprobada('cafe-13'));
  rechazar('código no admite espacios', aprobada('CAFE 13'));
  rechazar('código aprobado no puede estar vacío', aprobada(''));
  rechazar('código tiene longitud acotada', aprobada('A'.repeat(65)));
  rechazar('afiliación no puede cambiar de campaña', 'UPDATE solicitudes_afiliacion SET campana_id=2 WHERE id=104');
  rechazar('código asignado no se reemplaza', "UPDATE solicitudes_afiliacion SET codigo='OTRO' WHERE id=104");
  rechazar('resolución no se sobrescribe', "UPDATE solicitudes_afiliacion SET resuelta_por=3 WHERE id=104");

  rechazar('no hay comisión de una solicitud pendiente', comision({ afiliacion: 101 }));
  rechazar('pedido y afiliación deben pertenecer a la misma cafetería', comision({ afiliacion: 103 }));
  rechazar('un pedido no duplica su comisión', comision({ pedido: 201, base: 10000, monto: 1000 }), '23505');
  rechazar('importe original no puede ser negativo', comision({ monto: -1 }));
  rechazar('base no puede ser negativa', comision({ base: -1, monto: 0 }));
  rechazar('comisión no puede exceder la base', comision({ monto: 9000 }));
  rechazar('tasa no puede superar cien', comision({ tasa: 101 }));
  rechazar('comisión no nace como disponible', comision({ columnas: ',estado', valores: ",'disponible'" }));
  comprobar('se admite comisión cero sin perder la atribución', comision({ pedido: 203, monto: 0 }));
  rechazar('importe histórico no cambia', 'UPDATE movimientos_comision SET monto_clp=900 WHERE id=301');
  rechazar('referencias históricas no cambian', 'UPDATE movimientos_comision SET afiliacion_id=101 WHERE id=301');
  const historico = sql('SELECT row_to_json(m) FROM movimientos_comision m WHERE id=301');
  comprobar('cambiar tasa de campaña no recalcula movimientos', `UPDATE campanas SET tasa_comision=20,version_condiciones='2.0' WHERE id=1;`);
  assert.equal(sql('SELECT row_to_json(m) FROM movimientos_comision m WHERE id=301'), historico);
  rechazar('campaña con afiliados no cambia de cafetería', 'UPDATE campanas SET cafeteria_id=2 WHERE id=1');
  rechazar('pedido con comisión no cambia de cafetería', 'UPDATE pedidos SET cafeteria_id=2 WHERE id=201');

  comprobar('desactivar conserva estado, código e historial visible', `UPDATE solicitudes_afiliacion SET codigo_activo=false WHERE id=104;
    ${sesion(11)}
    SELECT test_assert((SELECT estado='aprobada' AND codigo='CAFE-11' AND NOT codigo_activo FROM solicitudes_afiliacion WHERE id=104),'código conservado');
    SELECT test_assert((SELECT monto_clp=1000 FROM movimientos_comision WHERE id=301),'historial accesible');`);
  comprobar('una cuenta inactiva pierde acceso sin borrar el historial', `UPDATE usuarios SET activo=false WHERE id=11;
    ${sesion(11)} SELECT test_assert((SELECT count(*)=0 FROM solicitudes_afiliacion),'cuenta inactiva');
    SELECT test_assert((SELECT count(*)=0 FROM movimientos_comision),'historial privado');`);
  comprobar('reactivar la cuenta recupera las lecturas conservadas', `UPDATE usuarios SET activo=true WHERE id=11;
    ${sesion(11)} SELECT test_assert((SELECT monto_clp=1000 FROM movimientos_comision WHERE id=301),'historial conservado');`);
  rechazar('un código desactivado sigue reservado', aprobada('CAFE-11'), '23505');
  const reversion = monto => `INSERT INTO movimientos_comision(afiliacion_id,pedido_id,tipo,estado,base_calculo_clp,tasa_comision,monto_clp,movimiento_origen_id)
    VALUES(104,201,'reversion','revertida',10000,10,${monto},301)`;
  rechazar('no se revierte una comisión aún pendiente', reversion(-1000));
  assert.throws(() => sql("UPDATE movimientos_comision SET estado='revertida' WHERE id=301"),
    error => error.stderr.toString().includes('deben confirmarse juntas'));
  comprobar('una reversión incompleta hace rollback al confirmar',
    "SELECT test_assert((SELECT estado='pendiente' FROM movimientos_comision WHERE id=301),'rollback de reversión incompleta');");
  comprobar('reversión enlazada conserva los importes originales', `BEGIN;
    UPDATE movimientos_comision SET estado='revertida' WHERE id=301;
    ${reversion(-1000)};
    SELECT test_assert((SELECT monto_clp=1000 AND tasa_comision=10 FROM movimientos_comision WHERE id=301),'original intacto'); COMMIT;`);
  rechazar('reversión no se duplica', reversion(-1000), '23505');
  rechazar('reversión debe compensar exactamente el importe', reversion(-900));
  rechazar('no se reactiva una comisión revertida', "UPDATE movimientos_comision SET estado='disponible' WHERE id=301");
  rechazar('el pedido no se borra con historial', 'DELETE FROM pedidos WHERE id=201', '23503');
  rechazar('el afiliado no se borra con historial', 'DELETE FROM solicitudes_afiliacion WHERE id=104', '23503');
  rechazar('la campaña no se borra con afiliados', 'DELETE FROM campanas WHERE id=1', '23503');
  rechazar('el usuario no se borra con solicitudes', 'DELETE FROM usuarios WHERE id=11', '23503');

  comprobar('backend puede insertar con identidad generada sin escritura del cliente', `SET ROLE service_role; ${nueva()};`);
  const repetida = `BEGIN; ${nueva({ estudiante: 14, campana: 2 })} ON CONFLICT DO NOTHING; SELECT pg_sleep(0.1); COMMIT;`;
  const resultados = await Promise.allSettled([sqlAsync(repetida), sqlAsync(repetida)]);
  for (const resultado of resultados) assert.equal(resultado.status, 'fulfilled', String(resultado.reason));
  comprobar('dos sesiones simultáneas dejan una sola solicitud', `SELECT test_assert(
    (SELECT count(*)=1 FROM solicitudes_afiliacion WHERE estudiante_id=14 AND campana_id=2),'sin duplicados concurrentes');`);
  console.log(`V04: ${casos} comprobaciones aprobadas con PostgreSQL real.`);
}).catch(error => { console.error(error.stderr?.toString() || error.stack); process.exitCode = 1; });
