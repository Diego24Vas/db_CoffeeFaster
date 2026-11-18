const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const temporal = require('./helpers/postgres.cjs');
const preparar = require('./helpers/afiliaciones.cjs');
const leer = n => fs.readFileSync(path.join(__dirname, '../supabase/migrations', n), 'utf8');
const sesion = id => `SET SESSION AUTHORIZATION cf_v04_authenticator; SET ROLE authenticated;
 SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-${String(id).padStart(12, '0')}',false);`;

temporal('v12', async ({sql}) => {
 preparar(sql);
 sql(leer('0020_modelar_afiliaciones_y_movimientos.sql'));
 sql(fs.readFileSync(path.join(__dirname,'fixtures/afiliaciones.sql'),'utf8'));
 sql(leer('0021_autorizar_solicitudes_afiliacion.sql'));
 sql('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;');
 const migration = leer('20261118211348_consulta_saldo_afiliado.sql');
 assert.throws(() => sql(migration.replace("NOTIFY pgrst, 'reload schema';",'SELECT 1/0;')), /Command failed/);
 assert.equal(sql("SELECT to_regclass('public.retiros_afiliado') IS NULL AND to_regprocedure('public.consultar_saldo_afiliado()') IS NULL"),'t');
 sql(migration);
 const saldo = id => JSON.parse(sql(sesion(id)+'SELECT row_to_json(s) FROM public.consultar_saldo_afiliado() s;').split('\n').at(-1));
 const esperado = (id,p,d,r) => assert.deepEqual(saldo(id),{pendiente_clp:p,disponible_clp:d,retirado_clp:r});
 esperado(10,0,0,0);
 esperado(11,1500,0,0);
 sql("UPDATE movimientos_comision SET estado='disponible' WHERE id=301; INSERT INTO retiros_afiliado(estudiante_id,monto_clp) VALUES(11,200),(11,300);");
 esperado(11,500,500,500);
 sql("INSERT INTO movimientos_comision(id,afiliacion_id,pedido_id,tipo,base_calculo_clp,tasa_comision,monto_clp) OVERRIDING SYSTEM VALUE VALUES(303,104,203,'comision',8000,10,800); BEGIN; UPDATE movimientos_comision SET estado='revertida' WHERE id=302; INSERT INTO movimientos_comision(afiliacion_id,pedido_id,tipo,base_calculo_clp,tasa_comision,monto_clp,movimiento_origen_id,estado) VALUES(105,202,'reversion',10000,5,-500,302,'revertida'); COMMIT;");
 esperado(11,800,500,500);
 esperado(10,0,0,0);
 sql("UPDATE solicitudes_afiliacion SET codigo_activo=false WHERE id=104");
 esperado(11,800,500,500);
 sql("UPDATE campanas SET estado='finalizada' WHERE id=1;");
 esperado(11,800,500,500);
 assert.equal(sql(sesion(10)+'SELECT count(*) FROM retiros_afiliado;').split('\n').at(-1),'0');
 assert.equal(sql(sesion(11)+'SELECT count(*) FROM retiros_afiliado;').split('\n').at(-1),'2');
 for (const id of [1,4,12]) sql(sesion(id)+"SELECT test_rechaza('SELECT * FROM public.consultar_saldo_afiliado()','42501');");
 sql("SET ROLE authenticated; SELECT test_rechaza('SELECT * FROM public.consultar_saldo_afiliado()','42501');");
 for(const role of ['anon','service_role']) {
  assert.equal(sql("SELECT has_function_privilege('"+role+"','public.consultar_saldo_afiliado()','EXECUTE')"),'f');
 }
 sql("BEGIN; UPDATE usuarios SET activo=false WHERE id=11; "+sesion(11)+"SELECT test_rechaza('SELECT * FROM public.consultar_saldo_afiliado()','42501'); ROLLBACK;");
 sql("BEGIN; UPDATE roles SET activo=false WHERE id=1; "+sesion(11)+"SELECT test_rechaza('SELECT * FROM public.consultar_saldo_afiliado()','42501'); ROLLBACK;");
 for(const role of ['anon','authenticated','service_role']) for(const action of ['INSERT','UPDATE','DELETE','TRUNCATE']) {
  assert.equal(sql("SELECT has_table_privilege('"+role+"','public.retiros_afiliado','"+action+"')"),'f');
 }
 sql("SELECT test_rechaza('INSERT INTO retiros_afiliado(estudiante_id,monto_clp) VALUES(11,0)','23514'); SELECT test_rechaza('UPDATE retiros_afiliado SET monto_clp=1','23514'); SELECT test_rechaza('DELETE FROM retiros_afiliado','23514');");
 esperado(11,800,500,500);
 sql("INSERT INTO pedidos(id,usuario_id,cafeteria_id,estado,pago_estado,total) VALUES(205,20,2,'pendiente','pagado',7000); INSERT INTO movimientos_comision(id,afiliacion_id,pedido_id,tipo,base_calculo_clp,tasa_comision,monto_clp) OVERRIDING SYSTEM VALUE VALUES(304,103,205,'comision',7000,10,700); UPDATE movimientos_comision SET estado='disponible' WHERE id=304; INSERT INTO retiros_afiliado(estudiante_id,monto_clp) VALUES(10,100);");
 esperado(10,0,600,100);
 esperado(11,800,500,500);
 sql(sesion(11)+"SELECT test_rechaza('INSERT INTO retiros_afiliado(estudiante_id,monto_clp) VALUES(11,100)','42501');");
 console.log('V12 aprobado: ceros, conciliación, reversión, múltiples retiros, código desactivado, RLS, sesiones y permisos, rollback de migración e historial inmutable.');
}).catch(e=>{console.error(e);process.exitCode=1;});
