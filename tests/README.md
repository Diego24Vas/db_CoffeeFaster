# Pruebas de campañas y afiliaciones

## Compatibilidad de migraciones con Cloud

`npm run test:migraciones` verifica versiones únicas y compara los archivos con
el historial de `integracion3` hasta `0017`, consultado en Cloud y guardado en
`fixtures/historial-cloud.json`. Luego reconstruye todas las migraciones `0001`
a `0020` en una base desechable, incluida la publicación Realtime. Las pendientes
`0018`–`0020` se ejecutan como propietario sin superusuario, con BYPASSRLS como
el rol postgres de Supabase y permisos por defecto amplios que deben revocarse.
Comprueba RLS, permisos finales y publicación de campañas.

La prueba adapta únicamente `auth.users`, `auth.uid()` y `auth.jwt()` a PostgreSQL
local; no inicia GoTrue, PostgREST ni el servicio de Realtime. Las instrucciones
de publicación y la conciliación del historial están en `supabase/DEPLOY.md`.

Se verificó además `supabase db push --dry-run --skip-vault` con CLI 2.117.0
contra una base local que reproducía el historial remoto hasta `0017`. Propuso
únicamente `0018`, `0019` y `0020`, sin seeds ni roles. Esta simulación no ejecutó
DDL en Cloud y no reemplaza comparar otra vez su historial antes de desplegar.

## V04 / CAM-287 — solicitudes, códigos y movimientos

La migración `0020_modelar_afiliaciones_y_movimientos.sql` pertenece únicamente a
este repositorio y se aplica después de `0019`. Está envuelta en una transacción;
no contiene usuarios, datos de ejemplo ni cambios en la base remota.

- `solicitudes_afiliacion` mantiene una fila por estudiante y campaña. La cafetería
  se obtiene de la campaña, sin duplicarla. Los estados son `pendiente`, `aprobada`
  y `rechazada`, alineados con C02.
- El código es NULL hasta aprobar, se guarda normalizado en mayúsculas, sin espacios
  y con un máximo de 64 caracteres. Su unicidad es global, conforme al contrato C02
  de la PR #62 de Integra 3, más estricta que la unicidad por cafetería indicada en V04.
- `codigo_activo` es independiente de la aprobación. Al desactivarlo se conserva
  el código reservado, la resolución y el acceso del afiliado a sus datos históricos.
- `movimientos_comision` conserva afiliación, pedido, base en CLP, tasa e importe.
  Una comisión nace pendiente; solo puede pasar a disponible o revertida. El importe
  cero admite la compra con código propio, cuyo cálculo corresponderá a V08.
- Cada pedido admite una comisión y una reversión. La reversión referencia al original,
  conserva su base/tasa y compensa exactamente el importe con signo opuesto. Marcar
  el original como revertido e insertar la compensación debe ocurrir en la misma
  transacción; una restricción diferida impide confirmar una reversión incompleta.
- Los importes y referencias son inmutables. Las claves foráneas impiden borrar sus
  padres y los triggers impiden trasladar campañas/pedidos con historial a otra cafetería.
- Las lecturas están filtradas por RLS: estudiante activo propietario o dueño activo
  de la cafetería. Empleados y anon no reciben acceso. No hay escritura directa
  para clientes ni permisos de DELETE para service_role.

V04 prepara el modelo: no implementa la RPC de solicitud ni las decisiones de V05,
el cálculo/pago de V08, la cancelación de V09, la entrega de V11 ni los retiros. En V05
la identidad debe obtenerse de `auth.uid()`; comprobar un `resuelta_por` válido en el
modelo no equivale a autenticar al llamador. Para el saldo futuro se cuentan las
comisiones originales por estado; las filas de reversión son su evidencia, no otra
ganancia ni una segunda resta sobre una comisión ya excluida.

### Prueba de V04

`npm test` ejecuta el historial completo, campañas y V04. Para ejecutar solo V04, usar
`npm run test:afiliaciones` con las variables de conexión local descritas abajo.
El runner crea y elimina una base propia `cf_v04_test_*`, carga el esquema real de
`0001`, los helpers reales de identidad de `0007`, `0018`, `0019` y la nueva `0020`.
Los únicos adaptadores de Auth son `auth.users` mínimo y la lectura del claim de
`auth.uid()`; no se comprueba la firma de un JWT ni se ejecuta PostgREST.

Los datos ficticios están en `tests/fixtures/afiliaciones.sql`, cuyo guard rechaza
bases ajenas al runner. Se prueban restricciones positivas/negativas, roles y RLS,
rollback, códigos entre cafeterías, historial, reversiones y dos conexiones reales
solicitando simultáneamente. No se usa ni se modifica el seed del entorno activo.

Validación local del 14 de noviembre de 2026: Node 22.16.0 y PostgreSQL 17.11,
solo mediante socket bajo /tmp. `npm test` aprobó las veinte migraciones en orden,
la regresión de campañas y 59 comprobaciones de V04. En la validación previa con
PostgreSQL 16.15 se verificaron además tres mutaciones en copias
temporales: eliminar la unicidad de solicitud, eliminar la unicidad de código
y permitir cambiar un importe histórico. Las tres fueron detectadas por
aserciones SQL, no por fallos de compilación o infraestructura.

| Criterio V04 | Evidencia |
|---|---|
| Una solicitud por estudiante y campaña | Restricción UNIQUE y dos conexiones concurrentes |
| Sin código utilizable antes de aprobar | CHECK de estado/código y pruebas de pendiente/rechazo |
| Código aprobado único por cafetería | Unicidad global, incluida la colisión entre cafeterías |
| Referencias históricas de pedido y afiliado | FK RESTRICT, importes inmutables y validación de cafetería |

Esta evidencia no acredita una migración aplicada en Supabase Cloud, el
funcionamiento de los servicios de Supabase ni las operaciones futuras de V05.

## S3-T4 — aceptación de campañas

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
Los runners rechazan hosts remotos y crean/eliminan únicamente bases temporales
`cf_migraciones_test_*`, `cf_campanas_test_*` y `cf_v04_test_*`. Debe usarse una
instancia de pruebas: preparan roles locales de Auth, autenticadores de prueba
y `cf_migration_owner`.

Comprueba rollback ante fallo de migración, reaplicación, aislamiento RLS,
rechazo de anon/sin sesión/empleado/dueño inactivo/cafetería ajena, INSERT/UPDATE
directos, trigger con permisos de escritura concedidos deliberadamente en una
transacción reversible, versión antigua, campañas vencidas/pausadas/futuras,
firmante del JWT, inmutabilidad y dos conexiones concurrentes.

Validación local: 13 de noviembre de 2026, Node 22.16.0 y PostgreSQL 16.15
extraído bajo /tmp, sin conexión Cloud. La función auth.uid reproduce la lectura
del claim en PostgreSQL; no valida la firma de un JWT ni ejecuta PostgREST.
El fixture mínimo utiliza el esquema de tabla de 0018 y aplica 0019 real.
