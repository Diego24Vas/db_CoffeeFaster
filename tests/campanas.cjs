// Base desechable y roles reales; no acepta un servidor remoto.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const container = process.env.TEST_POSTGRES_CONTAINER;
if (!container) assert.ok(/^(localhost|127\.0\.0\.1|\/tmp\/[^\s]+)$/.test(process.env.PGHOST || ''), 'PGHOST debe ser local');
const db = `cf_campanas_test_${process.pid}_${Date.now()}`;
const command = database => container
  ? ['docker', ['exec','-i',container,'psql','-U','postgres','-d',database,'-XAt','-v','ON_ERROR_STOP=1']]
  : [process.env.TEST_PSQL || 'psql',['-U','postgres','-d',database,'-XAt','-v','ON_ERROR_STOP=1']];
function sql(input, database = db) {
  const [bin,args]=command(database);
  return execFileSync(bin,args,{input,encoding:'utf8',timeout:30000,stdio:['pipe','pipe','pipe']}).trim();
}
const session = (id = 1) => `SET SESSION AUTHORIZATION cf_campanas_authenticator; SET ROLE authenticated;
 SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000${id}',false);`;
function concurrente(id) {
  const [bin,args]=command(db);
  return new Promise((resolve,reject)=>{
    const child=spawn(bin,args,{timeout:30000}); let out='',err='';
    child.stdout.on('data',v=>{out+=v;}); child.stderr.on('data',v=>{err+=v;});
    child.on('error',reject);
    child.on('close',code=>code===0?resolve(out.match(/\{[^\n]+\}/)?.[0]):reject(new Error(err)));
    child.stdin.end(`BEGIN; ${session(id)} SELECT row_to_json(c) FROM confirmar_condiciones_campana(101,1,'1.0') c; SELECT pg_sleep(0.1); COMMIT;`);
  });
}
(async()=>{
  let created=false;
  try {
    sql(`CREATE DATABASE ${db};`,'postgres'); created=true;
    sql(`DO $$ BEGIN
      IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
      IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
      IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
      IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='cf_campanas_authenticator') THEN CREATE ROLE cf_campanas_authenticator NOLOGIN NOINHERIT; END IF;
    END $$;
    GRANT anon,authenticated TO cf_campanas_authenticator;
    CREATE SCHEMA auth;
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    GRANT USAGE ON SCHEMA public,auth TO anon,authenticated;
    CREATE TABLE roles(id bigint PRIMARY KEY,nombre text);
    CREATE TABLE cafeterias(id bigint PRIMARY KEY);
    CREATE TABLE usuarios(id bigint PRIMARY KEY,auth_user_id uuid,rol_id bigint,activo boolean);
    CREATE TABLE cafeteria_usuarios(usuario_id bigint,cafeteria_id bigint);
    INSERT INTO roles VALUES(1,'dueño'),(2,'empleado'); INSERT INTO cafeterias VALUES(1),(2);
    INSERT INTO usuarios VALUES
      (1,'00000000-0000-0000-0000-000000000001',1,true),(2,'00000000-0000-0000-0000-000000000002',2,true),
      (3,'00000000-0000-0000-0000-000000000003',1,true),(4,'00000000-0000-0000-0000-000000000004',1,false);
    INSERT INTO cafeteria_usuarios VALUES(1,1),(2,1),(3,1),(4,1);`);
    const migrationDir=path.join(__dirname,'../supabase/migrations');
    // Esquema original sin sus políticas; no introduce helpers ficticios de permisos.
    const schema=fs.readFileSync(path.join(migrationDir,'0018_crear_esquema_campanas.sql'),'utf8').split('-- 4. Seguridad')[0];
    sql(schema);
    const migration=fs.readFileSync(path.join(migrationDir,'0019_asegurar_aceptacion_campanas.sql'),'utf8');
    assert.throws(()=>sql(migration.replace('NOTIFY pgrst','SELECT 1/0;\nNOTIFY pgrst')));
    assert.equal(sql("SELECT to_regprocedure('dueno_campana_id(bigint)') IS NULL"),'t','Rollback completo');
    sql(migration); sql(migration);
    sql(`CREATE FUNCTION test_assert(ok boolean,msg text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FALLO: %',msg; END IF; END $$;
    CREATE FUNCTION test_rechaza(stmt text,code text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
      BEGIN EXECUTE stmt; EXCEPTION WHEN OTHERS THEN IF SQLSTATE=code THEN RETURN; END IF; RAISE; END;
      RAISE EXCEPTION 'FALLO: se permitió %',stmt; END $$;
    INSERT INTO campanas(id,cafeteria_id,nombre,estado,version_condiciones,vigencia_desde,vigencia_hasta) OVERRIDING SYSTEM VALUE VALUES
      (101,1,'Concurrente','pendiente_aceptacion','1.0',now()-interval '1 day',now()+interval '1 day'),
      (102,1,'Pausada','pausada','1.0',now()-interval '1 day',now()+interval '1 day'),
      (103,1,'Vencida','activa','1.0',now()-interval '2 days',now()-interval '1 day'),
      (104,1,'Futura','activa','1.0',now()+interval '1 day',now()+interval '2 days'),
      (105,2,'Ajena','activa','1.0',now()-interval '1 day',now()+interval '1 day'),
      (106,1,'Versión','pendiente_aceptacion','2.0',now()-interval '1 day',now()+interval '1 day');
    SELECT test_assert(NOT has_function_privilege('anon','confirmar_condiciones_campana(bigint,bigint,text)','EXECUTE'),'anon sin EXECUTE');
    SELECT test_assert(to_regprocedure('confirmar_condiciones_campana(bigint,bigint,bigint,text)') IS NULL,'firma insegura retirada');
    SET SESSION AUTHORIZATION cf_campanas_authenticator; SET ROLE anon;
    SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(101,1,'1.0')$q$,'42501');
    SET ROLE authenticated;
    SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(101,1,'1.0')$q$,'42501');`);
    for(const id of [2,4]) sql(`${session(id)} SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(101,1,'1.0')$q$,'42501');`);
    sql(`${session()} SELECT test_assert((SELECT count(*)=5 FROM campanas),'RLS propia');
      SELECT test_assert((SELECT count(*)=0 FROM obtener_campana_vigente(2)),'RLS RPC');
      SELECT test_assert((SELECT id IN(101,106) FROM obtener_campana_vigente(1)),'selección vigente');
      SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(105,2,'1.0')$q$,'42501');
      SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(105,1,'1.0')$q$,'P0002');
      SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(106,1,'1.0')$q$,'22023');
      SELECT test_rechaza($q$UPDATE campanas SET confirmada_por_dueno=true WHERE id=101$q$,'42501');
      SELECT test_rechaza($q$INSERT INTO campanas(cafeteria_id,nombre,vigencia_desde,vigencia_hasta,confirmada_por_dueno) VALUES(1,'Falsa',now(),now()+interval '1 day',true)$q$,'42501');
      SELECT test_assert((SELECT usuario_confirma_id=1 AND version_confirmada='2.0' FROM confirmar_condiciones_campana(106,1,'2.0')),'identidad JWT');`);
    for(const id of [102,103,104]) sql(`${session()} SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(${id},1,'1.0')$q$,'22023');`);
    sql(`BEGIN; GRANT INSERT,UPDATE ON campanas TO authenticated;
      CREATE POLICY test_insert ON campanas FOR INSERT TO authenticated WITH CHECK(true);
      CREATE POLICY test_update ON campanas FOR UPDATE TO authenticated USING(true);
      ${session()}
      SELECT test_rechaza($q$UPDATE campanas SET version_confirmada='falsa' WHERE id=106$q$,'42501');
      SELECT test_rechaza($q$INSERT INTO campanas(id,cafeteria_id,nombre,vigencia_desde,vigencia_hasta,confirmada_por_dueno) OVERRIDING SYSTEM VALUE VALUES(999,1,'Falsa',now(),now()+interval '1 day',true)$q$,'42501');
      RESET SESSION AUTHORIZATION; ROLLBACK;
      SELECT test_rechaza($q$UPDATE campanas SET version_condiciones='3.0' WHERE id=106$q$,'22023');
      SELECT test_rechaza($q$UPDATE campanas SET tasa_descuento=10 WHERE id=101$q$,'22023');
      ALTER TABLE campanas DISABLE TRIGGER trg_proteger_confirmacion_campanas;
      UPDATE campanas SET version_condiciones='3.0' WHERE id=106;
      ALTER TABLE campanas ENABLE TRIGGER trg_proteger_confirmacion_campanas;
      ${session()} SELECT test_rechaza($q$SELECT confirmar_condiciones_campana(106,1,'3.0')$q$,'22023');`);
    console.log('APROBADO: migración, rollback, RLS, permisos, trigger, identidad, vigencia y versión');
    const results=await Promise.allSettled([concurrente(1),concurrente(3)]);
    for(const result of results) assert.equal(result.status,'fulfilled',String(result.reason));
    assert.ok(results[0].value); assert.equal(results[0].value,results[1].value,'Aceptación inmutable entre sesiones');
    console.log('APROBADO: concurrencia real entre dos sesiones');
  } finally { if(created) sql(`DROP DATABASE ${db} WITH(FORCE);`,'postgres'); }
})().catch(err=>{console.error(err.stderr?.toString()||err.message);process.exitCode=1;});
