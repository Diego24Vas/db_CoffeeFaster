const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const conBaseTemporal = require('./helpers/postgres.cjs');
const historial = require('./fixtures/historial-cloud.json');
const directorio = path.join(__dirname, '../supabase/migrations');
const archivos = fs.readdirSync(directorio).filter(nombre => nombre.endsWith('.sql')).sort();
const versiones = archivos.map(nombre => nombre.split('_')[0]);
assert.equal(new Set(versiones).size, versiones.length, 'No puede haber versiones duplicadas');
assert.deepEqual(archivos.slice(0, historial.length),
  historial.map(({ version, name }) => `${version}_${name}.sql`), 'Historial local alineado con Cloud');
assert.deepEqual(versiones.slice(historial.length), ['0018', '0019', '0020'], 'Orden de las migraciones pendientes');

conBaseTemporal('migraciones', async ({ sql }) => {
  sql(`DO $$ BEGIN
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='cf_migration_owner') THEN CREATE ROLE cf_migration_owner NOLOGIN NOSUPERUSER BYPASSRLS; END IF;
  END $$;
  CREATE SCHEMA auth;
  CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,raw_user_meta_data jsonb);
  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
  $$;
  CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb);
  $$;
  GRANT USAGE ON SCHEMA auth,public TO anon,authenticated;
  CREATE PUBLICATION supabase_realtime;`);

  for (const nombre of archivos) {
    if (nombre.startsWith('0018_')) {
      // El rol postgres de Cloud no es superusuario. Conserva propiedad y BYPASSRLS.
      sql(`GRANT USAGE,CREATE ON SCHEMA public TO cf_migration_owner;
        GRANT USAGE ON SCHEMA auth TO cf_migration_owner;
        DO $$ DECLARE tabla record; BEGIN
          EXECUTE format('GRANT CREATE ON DATABASE %I TO cf_migration_owner',current_database());
          FOR tabla IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
            EXECUTE format('ALTER TABLE public.%I OWNER TO cf_migration_owner',tabla.tablename);
          END LOOP;
        END $$;
        ALTER PUBLICATION supabase_realtime OWNER TO cf_migration_owner;
        ALTER DEFAULT PRIVILEGES FOR ROLE cf_migration_owner IN SCHEMA public
          GRANT ALL ON TABLES TO anon,authenticated,service_role;`);
    }
    const rol = nombre.slice(0, 4) >= '0018' ? 'SET ROLE cf_migration_owner;\n' : '';
    sql(rol + fs.readFileSync(path.join(directorio, nombre), 'utf8'));
    console.log(`APROBADO: migración ${nombre}`);
  }
  assert.equal(sql(`SELECT count(*)=3 AND bool_and(relrowsecurity) FROM pg_class
    WHERE oid IN ('public.campanas'::regclass,'public.solicitudes_afiliacion'::regclass,'public.movimientos_comision'::regclass)`), 't');
  assert.equal(sql(`SELECT NOT has_table_privilege('anon','solicitudes_afiliacion','SELECT')
    AND NOT has_table_privilege('authenticated','solicitudes_afiliacion','INSERT')
    AND NOT has_table_privilege('service_role','movimientos_comision','DELETE')`), 't');
  assert.equal(sql(`SELECT EXISTS(SELECT FROM pg_publication_tables
    WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='campanas')`), 't');
  console.log('Historial completo y migraciones pendientes aprobados, con RLS, permisos y publicación Realtime.');
}).catch(error => { console.error(error.message); process.exitCode = 1; });
