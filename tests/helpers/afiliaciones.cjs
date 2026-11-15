const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const migrations = path.join(__dirname, '../../supabase/migrations');
const leer = name => fs.readFileSync(path.join(migrations, name), 'utf8');

module.exports = function prepararAfiliaciones(sql) {
  sql(`DO $$ BEGIN
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
    IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='cf_v04_authenticator') THEN CREATE ROLE cf_v04_authenticator NOLOGIN NOINHERIT; END IF;
  END $$;
  GRANT anon,authenticated TO cf_v04_authenticator;
  CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY);
  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
  $$;
  GRANT USAGE ON SCHEMA auth,public TO anon,authenticated;`);
  // Esquema base y permisos de campañas reales; solo Auth se adapta al fixture local.
  sql(leer('0001_create_tables.sql'));
  const helpers = leer('0007_politicas_seguridad_rls.sql');
  const inicio = helpers.indexOf('-- 1.1 '), fin = helpers.indexOf('-- 1.6 ');
  assert.ok(inicio >= 0 && fin > inicio, 'Sección de helpers de identidad reconocible');
  sql(helpers.slice(inicio, fin));
  sql(leer('0018_crear_esquema_campanas.sql'));
  sql(leer('0019_asegurar_aceptacion_campanas.sql'));
};
