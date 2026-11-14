# Pruebas de aceptación de campañas — S3-T4

Los cambios de base de datos pertenecen a este repositorio. La migración
`0019_asegurar_aceptacion_campanas.sql` se aplica después de `0018` y exige el
esquema base de usuarios, roles y asignaciones de cafetería; no redefine permisos
mediante mocks. La versión 0018 permanece como migración histórica.

- El dueño consulta mediante RLS y confirma únicamente con su JWT.
- Las campañas aceptadas conservan tasas, vigencia, versión y firmante. Para otras
  condiciones se crea una nueva campaña; se permite pausar/finalizar la anterior.
- La aplicación debe actualizarse junto con la migración: la confirmación usa
  `p_campana_id`, `p_cafeteria_id`, `p_version`, sin `p_usuario_id`; la consulta usa
  `obtener_campana_vigente(p_cafeteria_id)` y el reloj del servidor.

## Ejecución aislada

Con un contenedor PostgreSQL local de pruebas:

```sh
TEST_POSTGRES_CONTAINER=cf-test-postgres npm test
```

O con PostgreSQL local y psql instalado:

```sh
PGHOST=127.0.0.1 PGPORT=5432 npm test
```

También se admiten `PGHOST=/tmp/...` para un socket local y `TEST_PSQL` para la
ruta del ejecutable. El usuario postgres necesita crear bases y roles de prueba.
El runner rechaza hosts remotos, crea y elimina exclusivamente su base
`cf_campanas_test_*`. Debe usarse una instancia de pruebas: prepara roles locales
`anon`, `authenticated`, `service_role` y `cf_campanas_authenticator`.

Comprueba rollback ante fallo de migración, reaplicación, aislamiento RLS,
rechazo de anon/sin sesión/empleado/dueño inactivo/cafetería ajena, INSERT/UPDATE
directos, trigger con permisos de escritura concedidos deliberadamente en una
transacción reversible, versión antigua, campañas vencidas/pausadas/futuras,
firmante del JWT, inmutabilidad y dos conexiones concurrentes.

Validación local: 13 de noviembre de 2026, Node 22.16.0 y PostgreSQL 16.15
extraído bajo /tmp, sin conexión Cloud. La función auth.uid reproduce la lectura
del claim en PostgreSQL; no valida la firma de un JWT ni ejecuta PostgREST.
El fixture mínimo utiliza el esquema de tabla de 0018 y aplica 0019 real.
