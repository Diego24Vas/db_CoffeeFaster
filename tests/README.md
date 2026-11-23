# Pruebas de campañas y afiliaciones

## V09 / CAM-177 — reversión de comisión al cancelar

La migración `20261121200029_revertir_comision_cancelacion.sql` sustituye
`public.cancelar_pedido(p_pedido_id bigint)` sin cambiar su respuesta JSON.
La API pública es `SECURITY INVOKER`; el núcleo `SECURITY DEFINER` está en
`afiliados_privado`, con `search_path` vacío y ejecución solo autenticada.
La identidad se obtiene de `mi_usuario_id()` y se comprueba la propiedad del pedido.

Conserva la cancelación desde pendiente/pagado, el reembolso de `pedidos.total`
y la reposición de stock únicamente cuando `stock_descontado=true`. Bloquea
pedido → productos ordenados → Wallet → comisión. Al existir una comisión
pendiente, marca el original como revertido e inserta su compensación negativa
con el mismo pedido, afiliación, base y tasa históricos y `movimiento_origen_id`.
Todo se confirma en una sola transacción. Una comisión disponible/revertida en
un pedido todavía cancelable provoca error y rollback; no se amplían los estados
cancelables ni se implementan devoluciones después de la entrega.

El reintento devuelve `ya_cancelado`, sin repetir Wallet, stock ni compensación.
Los pedidos sin comisión mantienen el flujo previo. Un código propio con comisión
cero deja una compensación de cero. Pausar la campaña, desactivar el código o
cambiar precios no altera los importes históricos. Los movimientos de reversión
son evidencia: no deben restarse otra vez de un saldo que ya excluye las
comisiones originales revertidas. No se modifican `pagos.estado` ni credenciales QR.

Ejecutar `npm run test:cancelacion-afiliada` con `PGHOST` local, `PGPORT` y
`TEST_PSQL`, o `TEST_POSTGRES_CONTAINER`, como los demás runners. La prueba crea
y elimina `cf_v09_test_*`, con esquema real y Auth simulado; ejecuta compra V08 y
cancelación con rol autenticado. Verifica importes, referencias persistidas,
stock, pedidos históricos, reintento, dos sesiones concurrentes, permisos,
rechazos y rollback provocado durante la inserción de la compensación. También
comprueba rollback de la migración conservando la función anterior.

Validación del 21 de noviembre de 2026: suite completa `npm test` aprobada con
Node 22.21.1 y PostgreSQL 16.15 aislado bajo `/tmp`. No se aplicó SQL en Cloud.

La fuente de V09 es esta migración. El instalador anterior en
`taller-integracion-3/app-mobile/tabla_mobile/rpc_cancelar_pedido.sql` conserva
la definición previa y no debe reaplicarse después de instalar V09.
El script histórico `activar_stock_promociones_cloud.sql` ya rechaza ejecutarse
si existe `cancelar_pedido`; no debe reutilizarse para actualizar V09.

## V08 / CAM-176 — afiliación dentro del pago

La migración `20261120210809_registrar_afiliacion_pago.sql` añade la sobrecarga
autenticada `procesar_pago(p_cafeteria_id bigint, p_items jsonb,
p_franja_retiro text, p_codigo text, p_total_aceptado bigint,
p_clave_idempotencia text)`. Los seis parámetros son obligatorios; código puede
ser NULL. La firma legacy de tres parámetros conserva su definición.
C07 debe pasar estos nombres desde el gateway y mapear las respuestas SQL al
contrato HTTP. V08 no cambia móvil ni microservicios.

El cálculo reutiliza V06 y la elegibilidad local confirmada en V07. Bloquea
productos por ID, Wallet, comprador/cafetería, afiliación y campaña antes de
confirmar el precio. Ante un total distinto devuelve `error=precio_actualizado`,
`total_actualizado`, `descuento_afiliado`, el motivo y `cobrado=false`, sin
modificar pedido, stock, Wallet, pagos o comisiones. Una desactivación o pausa
elimina el descuento y la comisión; pagar el nuevo importe requiere confirmar
con una clave nueva. La comisión válida nace pendiente e incluye base, tasa e
importe históricos, incluso cuando el código propio genera comisión cero.

`afiliados_privado.intentos_pago` guarda solicitud y respuesta por usuario/clave,
sin permisos de tabla para los roles de API y con RLS habilitada. Repetir los
mismos datos devuelve la respuesta guardada, incluidos los rechazos de negocio;
reusar la clave con otros datos devuelve `clave_reintento_en_conflicto`. Los
errores SQL revierten todas las escrituras y no reservan la clave. La estructura
y cantidades del carrito siguen los límites de V06. El núcleo privilegiado
permanece privado, valida JWT y solo admite ejecución autenticada.

`npm run test:pago-afiliado` utiliza el esquema real y una base desechable
`cf_v08_test_*`. Prueba importes de pedido/pago/Wallet/comisión, stock, promociones,
código propio, código desactivado tras cotizar, pausa, precio modificado, saldo
insuficiente, reintentos, conflicto de clave, permisos y un fallo después del
débito que revierte toda la compra. Dos conexiones prueban la misma clave y dos
claves distintas compitiendo por la primera compra.

Validación local del 20 de noviembre de 2026: Node 22.21.1 y PostgreSQL 16.15
aislado bajo `/tmp`, con Auth simulado. No se aplicó SQL en Supabase Cloud.

## V07 / CAM-175 — primera compra por comprador y cafetería

La migración `20261120204414_validar_primera_compra.sql` implementa la regla
de V07 confirmada para esta tarea: las compras pagadas y no canceladas, incluso
sin código, consumen la elegibilidad en esa cafetería. Las compras fallidas,
canceladas o revertidas mediante rollback no cuentan. Comprar en otra cafetería
no consume la elegibilidad local. Esta decisión sustituye para V07 la regla
global de C01 que conservaba el beneficio después de compras sin código.

`npm run test:primera-compra` reconstruye el esquema real en una base temporal
`cf_v07_test_*`. Comprueba la RPC pública con JWT simulado, precios y campañas,
historial sin código, código propio con comisión cero, permisos de los helpers,
rollback de la migración y compras, y concurrencia entre conexiones reales.
Observa los bloqueos en `pg_locks`/`pg_stat_activity`: dos compras con código,
compra sin código frente a compra con código, rollback de la primera y compras
simultáneas en distintas cafeterías. Las consultas comprueban pedidos y comisiones
persistidos. No instala datos de prueba en Cloud ni modifica el seed manual.

Los helpers de historial y bloqueo permanecen privados. La cotización sigue
siendo de solo lectura; al insertar pedidos y comisiones se conserva un bloqueo
transaccional por comprador y cafetería hasta confirmar o revertir la compra.
Se exige `READ COMMITTED` para revalidar con una vista actualizada tras esperar.
V08 debe bloquear primero la Wallet, después tomar
`afiliados_privado.bloquear_comprador(usuario, cafeteria)` y revalidar antes de
calcular el importe y guardar pedido, débito y comisión en una sola transacción.
V07 protege las escrituras, pero no incorpora el pago afiliado de V08.

La migración conserva V06 sin editar el archivo histórico: sustituye únicamente
su comprobación de elegibilidad. Si la definición instalada difiere de la esperada,
aborta y revierte toda la migración para permitir una revisión del contrato.

Validación local del 20 de noviembre de 2026: Node 22.21.1 y PostgreSQL 16.15
aislado bajo `/tmp`, con Auth simulado. No acredita despliegue en Supabase Cloud.

## Compatibilidad de migraciones con Cloud

`npm run test:migraciones` verifica versiones únicas y compara los archivos con
el historial de `integracion3` hasta `0017`, consultado en Cloud y guardado en
`fixtures/historial-cloud.json`. Luego reconstruye todas las migraciones `0001`
a V05 y las migraciones S3-T4 `0023`/`0024` en una base desechable, incluida la publicación Realtime.
Las pendientes desde `0018` se ejecutan como propietario sin superusuario, con BYPASSRLS como
el rol postgres de Supabase y permisos por defecto amplios que deben revocarse.
Comprueba RLS, permisos finales y publicación de campañas.

La prueba adapta únicamente `auth.users`, `auth.uid()` y `auth.jwt()` a PostgreSQL
local; no inicia GoTrue, PostgREST ni el servicio de Realtime. Las instrucciones
de publicación y la conciliación del historial están en `supabase/DEPLOY.md`.

Se verificó además `supabase db push --dry-run --skip-vault` con CLI 2.117.0
contra una base local que reproducía el historial remoto hasta `0017`. Propuso
`0018` a `0024`, sin seeds ni roles. Esta simulación no ejecutó
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

## S3-T4 — campañas vigentes para estudiantes

`0023_s3_t4_rpc_listar_oportunidades_campana.sql` creó la RPC inicial, que incluía campañas futuras y `estado_vigencia`. Se conserva sin cambios porque pudo haberse aplicado en otros entornos y `CREATE OR REPLACE FUNCTION` no permite cambiar el tipo de retorno. `0024_s3_t4_rpc_campanas_vigentes.sql` se aplica después, reemplaza solo el cuerpo con la misma firma y conserva `estado_vigencia` con el valor `en_curso` para las campañas vigentes.

- RPC final: `listar_oportunidades_campana(p_cafeteria_id bigint)`. Devuelve `id`, `nombre`, `cafeteria_id`, `cafeteria_nombre`, `tipo`, `estado`, `vigencia_desde`, `vigencia_hasta`, `tasa_descuento`, `tasa_comision` y `estado_vigencia` (`en_curso`). PostgREST entrega `[]` si no hay filas.
- **Vigente** significa `vigencia_desde <= statement_timestamp() < vigencia_hasta`. El inicio es inclusivo y el fin exclusivo. La consulta usa el reloj de PostgreSQL, no el de la aplicación.
- Estados visibles: únicamente `activa`. Se excluyen `borrador`, `pausada`, `finalizada`, `pendiente_aceptacion` y `aceptada`.
  - `pendiente_aceptacion` queda fuera porque el dueño todavía no aceptó las condiciones; `obtener_campana_vigente` la incluye para el dueño y V05 puede aprobar afiliaciones, pero C01 exige una campaña vigente y activa para el beneficio.
  - `aceptada` no tiene una transición en `0018`/`0019`/`0021`; `confirmar_condiciones_campana` deja la campaña en `activa` (`0019:109`). Su significado no puede establecerse con el código actual, por lo que no se expone. Si el negocio confirma que equivale a `activa`, debe agregarse en una migración posterior.
- Se excluyen también las campañas de cafeterías con `activa = false`. La cafetería se limita con `p_cafeteria_id`; no se consultan otras cafeterías.
- Requiere `auth.uid()` y una cuenta activa en `usuarios` con rol activo de estudiante. Usa `SECURITY DEFINER` solo para leer filas ocultas al estudiante por RLS; fija `search_path` vacío, califica objetos, valida identidad y concede `EXECUTE` únicamente a `authenticated`.
- Errores: `42501` si falta sesión o la cuenta no es estudiante activo; `22023` si `p_cafeteria_id` es nulo o no positivo. Cafetería activa sin campañas, o inexistente, devuelve cero filas.
- Se usan `tasa_descuento` y `tasa_comision` existentes. **No se mapean** a `descuento_normal_pct` ni `descuento_oferta_pct`. La incompatibilidad con los dos descuentos de C01/C02 queda como integración separada, fuera de S3-T4.
- `0024` se prueba en dos recorridos: instalación limpia (`0023` y luego `0024`) y actualización desde la versión anterior de `0023` ya aplicada. Ambos verifican que la firma y `estado_vigencia` se conservan, que las futuras dejan de aparecer y que los permisos/RLS no cambian.
- La prueba funcional cubre estudiante válido, sesión ausente, roles ajenos, campaña vigente/futura/pausada/vencida/borrador, `pendiente_aceptacion`/`aceptada`, otra cafetería, cafetería inactiva, límites de inicio/fin, lista vacía, campos/tasas, permisos y bloqueo del SELECT directo.

Validación local: 17 de noviembre de 2026, PostgreSQL 17.11 en un contenedor desechable; `npm test` completo, `test:oportunidades` y `test:oportunidades-upgrade` aprobados. La sesión se simula con `request.jwt.claim.sub` y `auth.uid()` local; no se valida la firma de un JWT ni se ejecuta PostgREST.

Ejecutar con `npm run test:oportunidades` y `npm run test:oportunidades-upgrade`; `npm test` incluye ambas coberturas. No se aplicaron las migraciones en Cloud.

## V06 / CAM-288 ÔÇö comprobaci├│n de estructura

La migraci├│n `20261117175958_cotizar_carrito_afiliado.sql` se incorpora a
`npm run test:migraciones`. Esta comprobaci├│n reconstruye las migraciones en
una base temporal y verifica permisos de ejecuci├│n y acceso al esquema privado.
No carga fixtures de cotizaci├│n ni inserta datos de negocio para V06.

Los runners y fixtures funcionales de V06 fueron retirados. Esta comprobaci├│n
estructural no acredita por s├¡ sola importes ni casos de negocio. La versi├│n
actual se valid├│ por separado en un contenedor desechable, registrando los
casos y las salidas en el archivo opcional `V06-Registro-entradas-salidas.md`
del directorio documental de V06 en el repositorio de aplicaciones. La
migraci├│n y las comprobaciones estructurales no dependen de ese registro.
El contrato y el alcance se documentan en
`taller-integracion-3/docs/base-datos/validacion/V06-CAM-288-Cotizacion-carrito.md`.

## S3-T6 / CAM-228 ÔÇö grupos equivalentes

`npm run test:migraciones` reconstruye tambi├®n
`20261117184822_crear_grupos_equivalentes.sql` con propietario sin superusuario y
privilegios iniciales amplios. Comprueba RLS del cat├ílogo, grants m├¡nimos, clave
for├ínea restrictiva, nulabilidad sin default, ├¡ndice v├ílido y cat├ílogo vac├¡o.
No incorpora fixtures ni nuevas funciones auxiliares de aplicaci├│n.

Las pruebas funcionales se ejecutan por separado en una base desechable con el
historial completo: conservar productos anteriores sin grupo; crear y consultar
grupos; rechazar duplicados, c├│digos no can├│nicos y referencias inexistentes;
comprobar asignaci├│n propia, rechazo ajeno, recarga, desclasificaci├│n y CRUD
anterior; comparar precios, stock, pol├¡ticas y una cotizaci├│n V06 antes/despu├®s.
Las condiciones de entrada y resultados reales se conservan en el registro
opcional `S3-T6-Registro-entradas-salidas.md` del repositorio de aplicaciones.

El registro es evidencia textual independiente, no se ejecuta durante las
migraciones ni las pruebas de estructura. Los datos ficticios solo existieron en
PostgreSQL temporal, sin cargar seeds en Cloud o en la base de desarrollo. Las
pruebas SQL emulan Auth y no acreditan GoTrue, HTTP ni interfaz de escritorio.

Resultado local del 17 de noviembre de 2026: **50/50 casos funcionales aprobados**
en PostgreSQL 17.12 con Node 22.23.5, m├ís la reconstrucci├│n completa de migraciones.
La revisi├│n independiente de Camilo sigue pendiente.

## V11 / CAM-179 · Entrega con comisión afiliada

Ejecuta `npm run test:entrega-afiliada` con `PGHOST` apuntando a PostgreSQL local
o con `TEST_POSTGRES_CONTAINER` configurado para el contenedor local de Supabase.
La prueba crea y elimina una base temporal.

La prueba compara las filas persistidas de `pedidos` y `movimientos_comision`
antes y después de confirmar la entrega con `service_role`. Cubre la campaña
pausada después de registrar la comisión, QR y token concurrentes, credenciales
rechazadas, un pedido sin afiliación y la reversión de ambas escrituras ante
un fallo durante la acreditación.

Resultado local con PostgreSQL 17.12 y Node 22.23.1. Para el pedido ficticio 201,
solo una de las dos confirmaciones concurrentes devolvió una fila. El pedido
quedó `entregado` con `qr_usado = true` y el movimiento 301 pasó a `disponible`
con sus 1.000 CLP y tasa histórica del 10 %. El segundo uso conservó la fecha
de entrega y el movimiento. Para el pedido 202, el fallo inducido dejó el
pedido en `listo` y la comisión en `pendiente`.


## V12 / CAM-181 — consulta de saldo del afiliado

Migración: `20261118211348_consulta_saldo_afiliado.sql`, después de V04/V05.
No requiere V07, V08 ni V11.

RPC: `SELECT * FROM public.consultar_saldo_afiliado();`, con sesión de estudiante
y rol authenticated. No acepta identificadores de usuario. Devuelve una fila con
pendiente_clp, disponible_clp y retirado_clp (numeric, importes enteros en CLP).
Un consumidor debe conservar precisión decimal si supera Number.MAX_SAFE_INTEGER.

- Pendiente: suma de comisiones originales pendientes.
- Disponible: comisiones originales disponibles menos retiros confirmados.
- Retirado: suma de retiros confirmados.

Originales revertidos y sus reversiones quedan excluidos sin doble descuento.
Comisiones y retiros se agregan por separado, en una sola consulta, evitando
multiplicar importes. Un estudiante activo sin movimientos recibe ceros.
Código desactivado o campaña finalizada conservan el historial y el saldo.
Se reutiliza estudiante_afiliacion_id() para validar sesión, cuenta y rol.
La RPC es SECURITY INVOKER y respeta RLS; dueños, empleados, cuentas/roles inactivos
y sesiones sin estudiante válido reciben 42501.

La nueva tabla retiros_afiliado contiene solo retiros confirmados, con importe
positivo, estudiante y fecha. Tiene RLS de lectura propia, historial inmutable
y ninguna escritura concedida a roles de API. V13 implementará el control atómico
del saldo y la inserción del retiro en una misma transacción; V14 podrá añadir
referencia y clave idempotente. Los intentos rechazados nunca se insertan aquí.
La consulta no guarda otro saldo ni utiliza la Wallet de compra. No oculta un
saldo negativo: V13 deberá impedir el débito que lo produciría.

### Evidencia reproducible

Ejecutar `npm run test:saldo-afiliado` con las variables locales de la sección
Ejecución aislada. El runner crea y elimina su propia base cf_v12_test_*.

| Escenario | Pendiente | Disponible | Retirado |
|---|---:|---:|---:|
| Sin movimientos | 0 | 0 | 0 |
| Dos comisiones pendientes | 1500 | 0 | 0 |
| Comisión disponible 1000, pendiente 500, retiros 200 + 300 | 500 | 500 | 500 |
| Reversión de 500 y nueva comisión pendiente 800 | 800 | 500 | 500 |
| Otro afiliado con comisión disponible 700 y retiro 100 | 0 | 600 | 100 |

También comprueba aislamiento entre usuarios, permisos con defaults amplios,
RLS, sesiones inválidas, código desactivado, campaña finalizada, historial
inmutable y rollback de la migración ante un fallo.

Validación local: PostgreSQL 18.6 desechable, cliente SQL temporal y Auth mínimo.
No ejecuta PostgREST ni aplica cambios en Cloud. El proyecto declara PostgreSQL 17
como versión objetivo; esta ejecución no certifica esa versión.
