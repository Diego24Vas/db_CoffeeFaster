# Pruebas de campañas y afiliaciones

## Compatibilidad de migraciones con Cloud

`npm run test:migraciones` verifica versiones únicas y compara los archivos con
el historial de `integracion3` hasta `0017`, consultado en Cloud y guardado en
`fixtures/historial-cloud.json`. Luego reconstruye todas las migraciones `0001`
a V05 y la RPC de oportunidades S3-T4 en una base desechable, incluida la publicación Realtime.
Las pendientes desde `0018` se ejecutan como propietario sin superusuario, con BYPASSRLS como
el rol postgres de Supabase y permisos por defecto amplios que deben revocarse.
Comprueba RLS, permisos finales y publicación de campañas.

La prueba adapta únicamente `auth.users`, `auth.uid()` y `auth.jwt()` a PostgreSQL
local; no inicia GoTrue, PostgREST ni el servicio de Realtime. Las instrucciones
de publicación y la conciliación del historial están en `supabase/DEPLOY.md`.

Se verificó además `supabase db push --dry-run --skip-vault` con CLI 2.117.0
contra una base local que reproducía el historial remoto hasta `0017`. Propuso
`0018`, `0019`, `0020`, `0021` y `0022`, sin seeds ni roles. Esta simulación no ejecutó
DDL en Cloud y no reemplaza comparar otra vez su historial antes de desplegar.

## V05 / CAM-172 — autorizar y resolver solicitudes

`0021_autorizar_solicitudes_afiliacion.sql` se aplica después de `0020`.
La migración de promociones continúa la misma numeración como `0022`.

RPC: `resolver_solicitud_afiliacion(p_solicitud_id bigint, p_decision text,
p_codigo text DEFAULT NULL)`, con JWT del dueño y rol `authenticated`. Devuelve
la fila de `solicitudes_afiliacion` y admite estas acciones:

| Acción | Resultado |
|---|---|
| `aprobar` | Pendiente → aprobada, código activo, firmante y fecha del servidor |
| `rechazar` | Pendiente → rechazada, sin código |
| `desactivar` | Mantiene aprobación/código/resolución; desactiva futuras atribuciones |

El dueño debe tener cuenta, rol y asignación de cafetería activos. El ID del dueño
no es un argumento. IDs inexistentes y ajenos reciben el mismo rechazo. Las
funciones privilegiadas fijan `search_path` vacío y califican las tablas; la RPC
se concede únicamente a `authenticated`, y las funciones de trigger no se exponen
por permisos de ejecución a los roles de API.

Un código propuesto se normaliza a mayúsculas y se recortan espacios exteriores;
no se permiten espacios interiores ni longitudes fuera de 1–64. Una colisión
devuelve `23505` (`codigo_en_uso`) sin resolver la solicitud. Sin propuesta se
genera `CF-` más UUID en hexadecimal, con reintentos limitados exclusivamente a
colisiones de la restricción del código. Así se contempla la generación pedida
por V05 y la propuesta del dueño prevista en C02.

El bloqueo de la solicitud serializa decisiones. Repetir una aprobación devuelve
la misma fila, sin cambiar código, fechas ni firmante; una propuesta diferente
conflicta. Repetir rechazo o desactivación tampoco reescribe datos. Reaprobar una
afiliación desactivada no la reactiva. Resolver en el sentido contrario devuelve
`55000`. Parámetros inválidos devuelven `22023`, permisos insuficientes `42501`.

Se permiten aprobaciones de campañas futuras en estados `activa`, `aceptada` o
`pendiente_aceptacion`, mientras no hayan terminado. No se aprueban borradores,
campañas pausadas/finalizadas o estudiantes inactivos. Rechazar o desactivar no
requiere que la campaña continúe vigente. El canje y el pago se validarán en V06/V08.

El nuevo trigger de comisión bloquea la afiliación con `FOR SHARE` al insertar un
original y exige aprobación y código activo. Si una atribución gana la carrera,
termina antes de desactivar; si gana la desactivación, no se inserta la comisión.
La entrega y las reversiones de comisiones anteriores siguen permitidas. La RLS
del estudiante no depende de `codigo_activo`, por lo que conserva acceso al historial.

`service_role` conserva creación de solicitudes pendientes para C05, pero pierde
UPDATE sobre ellas. Un trigger impide insertar resoluciones terminales o resolver
directamente desde roles de API, incluso si se concede UPDATE por error. C05 debe
usar la RPC con la sesión del dueño; no sustituirla por una llamada con service_role.
No se añaden rutas, pantallas, correos ni el cálculo de saldo de V12.

`npm run test:resoluciones` usa la misma preparación de tablas/helpers reales que
V04 y el fixture protegido para bases `cf_v05_test_*`. El 14 de noviembre de 2026
pasaron 56 comprobaciones en PostgreSQL 17.11: permisos de cuentas/roles/asignación,
RLS, escrituras directas, rollback de migración, códigos, reintentos y seis carreras
entre sesiones reales. Las carreras usan una barrera observable en `pg_locks`;
se comparan las dos respuestas de aprobación y se comprueban datos persistidos.

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

V04 prepara el modelo: por sí sola no implementa la RPC de solicitud ni las decisiones de V05,
el cálculo/pago de V08, la cancelación de V09, la entrega de V11 ni los retiros. En V05
la identidad debe obtenerse de `auth.uid()`; comprobar un `resuelta_por` válido en el
modelo no equivale a autenticar al llamador. Para el saldo futuro se cuentan las
comisiones originales por estado; las filas de reversión son su evidencia, no otra
ganancia ni una segunda resta sobre una comisión ya excluida.

### Prueba de V04

`npm test` ejecuta el historial completo, campañas, V04 y V05. Para ejecutar solo V04, usar
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
`cf_migraciones_test_*`, `cf_campanas_test_*`, `cf_v04_test_*` y `cf_v05_test_*`. Debe usarse una
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

## S3-T4 — listado de oportunidades para estudiantes

La migración `0023_s3_t4_rpc_listar_oportunidades_campana.sql` añade una función de lectura sobre `campanas`; no crea tablas ni modifica la lectura directa o RPC existentes.

- RPC: `listar_oportunidades_campana(p_cafeteria_id bigint)`. Devuelve `id`, `nombre`, `cafeteria_id`, `cafeteria_nombre`, `tipo` (el alcance guardado actualmente), `estado`, vigencias, tasas existentes y `estado_vigencia` (`futura` / `en_curso`). PostgREST entrega `[]` si no hay filas.
- Estados listables: `pendiente_aceptacion`, `activa` y `aceptada`. Se excluyen borradores, pausadas, finalizadas y campañas vencidas. Las campañas futuras siguen siendo postulables y aparecen marcadas como `futura`.
- Postularse no exige confirmación previa del dueño. Una campaña `pendiente_aceptacion` se devuelve con ese estado para que el cliente indique que la oferta todavía espera confirmación. La confirmación sigue usando la RPC existente y no se modifica aquí. La vigencia para canje y beneficios se valida en las tareas que implementen esas operaciones. La RPC existente de confirmación (0019) no acepta campañas antes de `vigencia_desde`; la RPC de resolución (0021) sí admite aprobar afiliaciones en `pendiente_aceptacion`. Por tanto, esta lectura permite postulación anticipada, pero no cambia ni impone una espera de aprobación hasta confirmar: esa coordinación queda como acuerdo de negocio aparte.
- Requiere `auth.uid()` y una cuenta activa en `usuarios` con rol activo de estudiante. Usa `SECURITY DEFINER` solo para leer filas ocultas al estudiante por RLS; fija `search_path` vacío, califica objetos, valida identidad y concede `EXECUTE` únicamente a `authenticated`.
- Errores: `42501` si falta sesión o la cuenta no es estudiante activo; `22023` si `p_cafeteria_id` es nulo o no positivo. Cafetería sin oportunidades, incluso inexistente, devuelve cero filas.
- Se usan `tasa_descuento` y `tasa_comision` existentes. El desacuerdo con los dos descuentos descritos en C01/C02 queda fuera de esta RPC para acordarse aparte.

Ejecutar con `npm run test:oportunidades`; `npm test` también incluye esta cobertura. No se aplicó la migración en Cloud.
