const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const prepararAfiliaciones = require('./helpers/afiliaciones.cjs');
const leer = nombre => fs.readFileSync(path.join(__dirname, '../supabase/migrations', nombre), 'utf8');
const sesion = id => `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;
  SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-${String(id).padStart(12, '0')}',false);`;
const resolver = (id, decision, codigo = 'NULL') => `SELECT row_to_json(public.resolver_solicitud_afiliacion(${id},'${decision}',${codigo}))`;
const comision = (afiliacion, pedido) => `INSERT INTO movimientos_comision(afiliacion_id,pedido_id,tipo,base_calculo_clp,tasa_comision,monto_clp)
  VALUES(${afiliacion},${pedido},'comision',8000,10,800)`;

conBaseTemporal('v05', async ({ sql, sqlAsync }) => {
  let casos = 0;
  const comprobar = (nombre, sentencia) => { sql(sentencia); casos++; console.log(`APROBADO: ${nombre}`); };
  const rechazar = (nombre, sentencia, codigo) => comprobar(nombre,
    `SELECT test_rechaza($caso$${sentencia}$caso$,'${codigo}');`);
  prepararAfiliaciones(sql);
  sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
  sql(fs.readFileSync(path.join(__dirname, 'fixtures/afiliaciones.sql'), 'utf8'));
  // Se simulan los permisos por defecto amplios de Supabase antes de crear funciones.
  sql('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon,authenticated,service_role;');
  const migration = leer('0021_autorizar_solicitudes_afiliacion.sql');
  const duenoAnterior = sql("SELECT pg_get_functiondef('dueno_campana_id(bigint)'::regprocedure)");
  assert.throws(() => sql(migration.replace("NOTIFY pgrst, 'reload schema';", 'SELECT 1/0;')), /Command failed/);
  assert.equal(sql("SELECT to_regprocedure('resolver_solicitud_afiliacion(bigint,text,text)') IS NULL AND NOT EXISTS(SELECT FROM pg_trigger WHERE tgname IN ('validar_codigo_afiliacion','proteger_resolucion_afiliacion')) AND has_table_privilege('service_role','solicitudes_afiliacion','UPDATE')"), 't');
  assert.equal(sql("SELECT pg_get_functiondef('dueno_campana_id(bigint)'::regprocedure)"), duenoAnterior);
  casos++; console.log('APROBADO: fallo de migración revierte funciones, trigger y helper anterior');
  sql(migration);
  sql(`INSERT INTO auth.users(id) SELECT ('00000000-0000-0000-0000-'||lpad(id::text,12,'0'))::uuid FROM generate_series(21,40) id;
    INSERT INTO usuarios(id,rol_id,nombre,email,password_hash,auth_user_id)
    SELECT id,1,'Prueba V05 '||id,'v05-'||id||'@example.invalid','sin-login',
      ('00000000-0000-0000-0000-'||lpad(id::text,12,'0'))::uuid FROM generate_series(21,40) id;
    INSERT INTO solicitudes_afiliacion(id,estudiante_id,campana_id,plan_promocion) OVERRIDING SYSTEM VALUE
    SELECT id+85,id,1,'Plan V05' FROM generate_series(21,40) id;
    INSERT INTO solicitudes_afiliacion(id,estudiante_id,campana_id,plan_promocion) OVERRIDING SYSTEM VALUE VALUES(201,21,2,'Plan V05 B');
    INSERT INTO pedidos(id,usuario_id,cafeteria_id,estado,pago_estado,total)
    SELECT id,20,1,'pendiente','pagado',8000 FROM generate_series(205,215) id;
    GRANT SELECT ON usuarios,roles,cafeteria_usuarios,campanas,pedidos TO service_role;
    GRANT UPDATE ON pedidos TO service_role;`);

  for (const [actor, nombre] of [[3,'dueño ajeno'],[4,'empleado'],[10,'estudiante'],[12,'cuenta inactiva']]) {
    for (const accion of ['aprobar','rechazar','desactivar']) {
      comprobar(`${nombre} no puede ${accion}`, `${sesion(actor)}
        SELECT test_rechaza($q$${resolver(accion==='desactivar'?104:101,accion)}$q$,'42501');`);
    }
  }
  comprobar('anon no ejecuta la RPC', `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE anon;
    SELECT test_rechaza($q$${resolver(101,'aprobar')}$q$,'42501');`);
  comprobar('service_role no reemplaza la sesión del dueño', `SET ROLE service_role;
    SELECT test_rechaza($q$${resolver(101,'aprobar')}$q$,'42501');`);
  comprobar('backend no resuelve por UPDATE ni inserta resoluciones ya aprobadas', `SET ROLE service_role;
    SELECT test_rechaza($q$UPDATE solicitudes_afiliacion SET codigo_activo=false WHERE id=104$q$,'42501');
    SELECT test_rechaza($q$INSERT INTO solicitudes_afiliacion(estudiante_id,campana_id,plan_promocion,estado,codigo,codigo_activo,resuelta_por,resuelta_en)
      VALUES(40,2,'Prueba','aprobada','SIN-RPC',true,3,now())$q$,'42501');`);
  comprobar('backend conserva creación de pendientes para C05', `SET ROLE service_role;
    INSERT INTO solicitudes_afiliacion(estudiante_id,campana_id,plan_promocion) VALUES(40,2,'Plan pendiente de C05');`);
  comprobar('el trigger bloquea escritura directa aun con UPDATE concedido por error', `BEGIN;
    GRANT UPDATE ON solicitudes_afiliacion TO service_role; SET ROLE service_role;
    SELECT test_rechaza($q$UPDATE solicitudes_afiliacion SET codigo_activo=false WHERE id=104$q$,'42501'); ROLLBACK;`);
  comprobar('authenticated sin JWT no decide', `SET ROLE authenticated;
    SELECT test_rechaza($q$${resolver(101,'aprobar')}$q$,'42501');`);
  comprobar('dueño inactivo pierde permisos', `BEGIN; UPDATE usuarios SET activo=false WHERE id=1;
    ${sesion(1)} SELECT test_rechaza($q$${resolver(101,'aprobar')}$q$,'42501'); ROLLBACK;`);
  comprobar('rol de dueño inactivo bloquea las tres acciones y las lecturas', `BEGIN; UPDATE roles SET activo=false WHERE id=3;
    ${sesion(1)} SELECT test_assert((SELECT count(*)=0 FROM solicitudes_afiliacion),'sin lectura de dueño inactivo');
    SELECT test_rechaza($q$${resolver(101,'aprobar')}$q$,'42501');
    SELECT test_rechaza($q$${resolver(101,'rechazar')}$q$,'42501');
    SELECT test_rechaza($q$${resolver(104,'desactivar')}$q$,'42501'); ROLLBACK;`);
  comprobar('dueño sin asignación no decide', `BEGIN; DELETE FROM cafeteria_usuarios WHERE usuario_id=1;
    ${sesion(1)} SELECT test_rechaza($q$${resolver(101,'aprobar')}$q$,'42501'); ROLLBACK;`);
  comprobar('ID inexistente no revela existencia de datos ajenos', `${sesion(1)}
    SELECT test_rechaza($q$${resolver(99999,'aprobar')}$q$,'42501');`);
  for (const codigo of ["''", "'CAFE CON ESPACIOS'", "repeat('A',65)"]) {
    comprobar('se rechaza código inválido sin resolver', `${sesion(1)}
      SELECT test_rechaza($q$${resolver(101,'aprobar',codigo)}$q$,'22023');`);
  }
  comprobar('decisión inválida y código al rechazar no escriben', `${sesion(1)}
    SELECT test_rechaza($q$${resolver(101,'otra')}$q$,'22023');
    SELECT test_rechaza($q$${resolver(101,'rechazar',"'NO'")}$q$,'22023');`);
  comprobar('solo se desactivan aprobadas', `${sesion(1)}
    SELECT test_rechaza($q$${resolver(101,'desactivar')}$q$,'55000');`);
  comprobar('aprobar asigna código normalizado y firmante del JWT', `${sesion(1)} ${resolver(101,'aprobar',"' diego-promo1 '")};
    SELECT test_assert((SELECT estado='aprobada' AND codigo='DIEGO-PROMO1' AND codigo_activo AND resuelta_por=1 AND resuelta_en IS NOT NULL
      FROM solicitudes_afiliacion WHERE id=101),'aprobación atómica');`);
  const aprobada = sql('SELECT row_to_json(s) FROM solicitudes_afiliacion s WHERE id=101');
  comprobar('reintento devuelve la misma aprobación', `${sesion(1)} ${resolver(101,'aprobar')}; ${resolver(101,'aprobar',"'diego-promo1'")};`);
  assert.equal(sql('SELECT row_to_json(s) FROM solicitudes_afiliacion s WHERE id=101'), aprobada);
  comprobar('no se reemplaza una resolución ni su código', `${sesion(1)}
    SELECT test_rechaza($q$${resolver(101,'rechazar')}$q$,'55000');
    SELECT test_rechaza($q$${resolver(101,'aprobar',"'OTRO'")}$q$,'55000');`);
  comprobar('sin propuesta se genera un código válido y único', `${sesion(1)} ${resolver(106,'aprobar')};
    SELECT test_assert((SELECT codigo ~ '^CF-[A-F0-9]{32}$' AND codigo_activo FROM solicitudes_afiliacion WHERE id=106),'código generado');`);
  comprobar('código ocupado en otra cafetería deja pendiente', `${sesion(3)}
    SELECT test_rechaza($q$${resolver(201,'aprobar',"'DIEGO-PROMO1'")}$q$,'23505');
    SELECT test_assert((SELECT estado='pendiente' AND codigo IS NULL AND resuelta_por IS NULL FROM solicitudes_afiliacion WHERE id=201),'sin resolución parcial');`);
  comprobar('rechazo no genera código y admite reintento', `${sesion(1)} ${resolver(107,'rechazar')}; ${resolver(107,'rechazar')};
    SELECT test_assert((SELECT estado='rechazada' AND codigo IS NULL AND NOT codigo_activo AND resuelta_por=1 FROM solicitudes_afiliacion WHERE id=107),'rechazo');
    SELECT test_rechaza($q$${resolver(107,'aprobar')}$q$,'55000');`);
  comprobar('no se aprueba un solicitante desactivado', `BEGIN; UPDATE usuarios SET activo=false WHERE id=24;
    ${sesion(1)} SELECT test_rechaza($q$${resolver(109,'aprobar')}$q$,'55000'); ROLLBACK;`);
  comprobar('se permite aprobar antes del inicio', `BEGIN; UPDATE campanas SET vigencia_desde=now()+interval '1 day',version_condiciones='2.0' WHERE id=1;
    ${sesion(1)} ${resolver(110,'aprobar')}; ROLLBACK;`);
  for (const estado of ['borrador','pausada','finalizada']) {
    comprobar(`campaña ${estado} no recibe nuevas aprobaciones`, `BEGIN; UPDATE campanas SET estado='${estado}' WHERE id=1;
      ${sesion(1)} SELECT test_rechaza($q$${resolver(110,'aprobar')}$q$,'55000'); ROLLBACK;`);
  }
  comprobar('campaña vencida no recibe nuevas aprobaciones', `BEGIN;
    UPDATE campanas SET vigencia_desde=now()-interval '2 days',vigencia_hasta=now()-interval '1 day',version_condiciones='2.0' WHERE id=1;
    ${sesion(1)} SELECT test_rechaza($q$${resolver(110,'aprobar')}$q$,'55000'); ROLLBACK;`);
  comprobar('clientes siguen sin escritura directa', `${sesion(1)}
    SELECT test_rechaza($q$UPDATE solicitudes_afiliacion SET codigo_activo=false WHERE id=101$q$,'42501');`);
  const historial = sql('SELECT row_to_json(m) FROM movimientos_comision m WHERE id=301');
  comprobar('desactivar conserva código y resolución', `${sesion(1)} ${resolver(104,'desactivar')};
    SELECT test_assert((SELECT codigo='CAFE-11' AND estado='aprobada' AND NOT codigo_activo AND resuelta_por=1 FROM solicitudes_afiliacion WHERE id=104),'historial conservado');`);
  assert.equal(sql('SELECT row_to_json(m) FROM movimientos_comision m WHERE id=301'), historial);
  const desactivada = sql('SELECT row_to_json(s) FROM solicitudes_afiliacion s WHERE id=104');
  comprobar('reaprobar no reactiva y desactivar dos veces no reescribe', `${sesion(1)} ${resolver(104,'aprobar')}; ${resolver(104,'desactivar')};`);
  assert.equal(sql('SELECT row_to_json(s) FROM solicitudes_afiliacion s WHERE id=104'), desactivada);
  comprobar('afiliado mantiene lectura propia sin ver datos ajenos', `${sesion(11)}
    SELECT test_assert((SELECT count(*)=2 FROM movimientos_comision),'historial propio');
    SELECT test_assert(NOT EXISTS(SELECT FROM solicitudes_afiliacion WHERE estudiante_id<>11),'sin afiliaciones ajenas');`);
  comprobar('backend no registra nuevas comisiones con código desactivado', `SET ROLE service_role;
    SELECT test_rechaza($q$${comision(104,205)}$q$,'23514');`);
  comprobar('desactivar no impide entregar una comisión pendiente', `SET ROLE service_role;
    UPDATE movimientos_comision SET estado='disponible' WHERE id=301;
    SELECT test_assert((SELECT monto_clp=1000 AND estado='disponible' FROM movimientos_comision WHERE id=301),'saldo previo conservado');`);
  comprobar('desactivar tampoco bloquea una reversión previa', `BEGIN; UPDATE movimientos_comision SET estado='revertida' WHERE id=302;
    ${sesion(3)} ${resolver(105,'desactivar')}; RESET SESSION AUTHORIZATION;
    INSERT INTO movimientos_comision(afiliacion_id,pedido_id,tipo,estado,base_calculo_clp,tasa_comision,monto_clp,movimiento_origen_id)
      VALUES(105,202,'reversion','revertida',10000,5,-500,302); COMMIT;`);

  // Barrera observable: el segundo intento arranca cuando el primero ya decidió.
  let llave = 517200;
  const competir = async (nombre, primero, segundo) => {
    const clave = ++llave;
    const a = sqlAsync(`BEGIN; ${primero}; SELECT pg_advisory_xact_lock(${clave}); SELECT pg_sleep(0.3); COMMIT;`);
    let listo = false;
    for (let intento=0; intento<200; intento++) {
      if (sql(`SELECT EXISTS(SELECT FROM pg_locks WHERE locktype='advisory' AND objid=${clave} AND granted)`) === 't') { listo=true; break; }
      await new Promise(resolve => setTimeout(resolve,10));
    }
    const resultados = await Promise.allSettled([a, listo ? sqlAsync(segundo) : Promise.reject(new Error('No llegó a la barrera'))]);
    for (const resultado of resultados) assert.equal(resultado.status,'fulfilled',String(resultado.reason));
    casos++; console.log(`APROBADO: ${nombre}`);
    return resultados.map(resultado => resultado.value);
  };
  const doble = await competir('dos aprobaciones concurrentes conservan una resolución',
    `${sesion(1)} ${resolver(112,'aprobar')}`, `${sesion(1)} ${resolver(112,'aprobar')}`);
  const respuesta = salida => JSON.parse(salida.split('\n').find(linea => linea.startsWith('{')));
  assert.deepEqual(respuesta(doble[0]), respuesta(doble[1]), 'Las dos respuestas conservan código, firmante y fechas');
  comprobar('el código concurrente queda activo y único', `SELECT test_assert((SELECT estado='aprobada' AND codigo_activo AND codigo IS NOT NULL FROM solicitudes_afiliacion WHERE id=112),'aprobación concurrente');`);
  await competir('aprobar gana al rechazo concurrente', `${sesion(1)} ${resolver(113,'aprobar')}`,
    `${sesion(1)} SELECT test_rechaza($q$${resolver(113,'rechazar')}$q$,'55000');`);
  await competir('rechazar gana a la aprobación concurrente', `${sesion(1)} ${resolver(114,'rechazar')}`,
    `${sesion(1)} SELECT test_rechaza($q$${resolver(114,'aprobar')}$q$,'55000');`);
  await competir('colisión concurrente entre cafeterías no resuelve la segunda solicitud', `${sesion(1)} ${resolver(115,'aprobar',"'COMPARTIDO'")}`,
    `${sesion(3)} SELECT test_rechaza($q$${resolver(201,'aprobar',"'COMPARTIDO'")}$q$,'23505');`);
  sql(`${sesion(1)} ${resolver(116,'aprobar')}; ${resolver(117,'aprobar')};`);
  await competir('una atribución ya iniciada termina antes de desactivar', `SET ROLE service_role; ${comision(116,206)}`,
    `${sesion(1)} ${resolver(116,'desactivar')}`);
  comprobar('la comisión previa persiste y la afiliación queda desactivada', `SELECT test_assert(
    (SELECT count(*)=1 FROM movimientos_comision WHERE afiliacion_id=116) AND
    (SELECT NOT codigo_activo FROM solicitudes_afiliacion WHERE id=116),'atribución preservada');`);
  await competir('desactivar primero bloquea una atribución concurrente', `${sesion(1)} ${resolver(117,'desactivar')}`,
    `SET ROLE service_role; SELECT test_rechaza($q$${comision(117,207)}$q$,'23514');`);
  comprobar('el rechazo concurrente no deja una comisión parcial', `SELECT test_assert(
    NOT EXISTS(SELECT FROM movimientos_comision WHERE pedido_id=207),'sin atribución posterior');`);
  console.log(`V05: ${casos} comprobaciones aprobadas con PostgreSQL real.`);
}).catch(error => { console.error(error.stderr?.toString() || error.stack); process.exitCode = 1; });
