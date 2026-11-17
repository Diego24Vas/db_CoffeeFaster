# Preparación de despliegue de V04 y V05

Repositorio de base de datos: `db_CoffeeFaster`. Proyecto revisado:
`integracion3` (`yvkpmqcynpygqjvaoiwn`), PostgreSQL 17.11.
No se aplicaron migraciones en Cloud durante esta preparación.

## Historial

Cloud registra `0001` a `0017`. Los nombres y versiones se guardan en
`tests/fixtures/historial-cloud.json` como referencia de la revisión del
14 de noviembre de 2026; la prueba no requiere acceso remoto.

Se restauraron localmente `0008_habilitar_realtime_inventario.sql` y
`0009_politicas_seguridad_rls.sql` usando el mismo SQL que sus originales
`0004` y `0007`, respectivamente. Su contenido se contrastó con los statements
registrados en Cloud. Solicitudes de stock se renombró de `0008` a `0010`, como
consta en Cloud. Los dos scripts históricos con versiones duplicadas se conservan
en `supabase/legacy`, fuera de la secuencia activa.

No ejecutar `migration repair` ni renumerar versiones ya aplicadas en el servidor
para adaptar la base al historial local anterior. En otros proyectos se debe
comparar primero su historial: esta conciliación corresponde a `integracion3`.

## Verificación antes de publicar

1. Ejecutar `npm test` contra una instancia PostgreSQL 17 de pruebas, según
   `tests/README.md`. Nunca apuntar estos runners a una base de producción.
2. Con Supabase CLI autenticada, revisar el proyecto vinculado y ejecutar
   `supabase migration list --linked`.
3. Ejecutar `supabase db push --linked --dry-run --skip-vault`. Debe proponer
   exclusivamente, en este orden:
   - `0018_crear_esquema_campanas.sql`
   - `0019_asegurar_aceptacion_campanas.sql`
   - `0020_modelar_afiliaciones_y_movimientos.sql`
   - `0021_autorizar_solicitudes_afiliacion.sql`
   - `0022_s3_t5_crear_tabla_promociones.sql`
   - `0023_s3_t4_rpc_listar_oportunidades_campana.sql`
   - `20261117175958_cotizar_carrito_afiliado.sql`
   - `20261117184822_crear_grupos_equivalentes.sql`
4. Si aparece cualquier otra migración, detener el despliegue y contrastar el
   historial. No usar `--include-all`, `--include-seed` ni `db reset` en Cloud.
5. La aplicación de las migraciones queda pendiente de autorización. Preparar
   conjuntamente la versión de la aplicación que utiliza las RPC de `0019` y `0023`.

`0020` se aplica una sola vez y se registra en el historial. Su transacción revierte
tablas, funciones y triggers si falla. No contiene datos ficticios ni recalcula
importes de pedidos. Los nuevos triggers impiden trasladar campañas o pedidos con
historial de afiliación a otra cafetería. V04 prepara el modelo; V05 añade la RPC
de aprobación/rechazo/desactivación y bloquea nuevas atribuciones a códigos
desactivados. La creación de solicitudes desde la API y el pago afiliado quedan
en las tareas posteriores.

V05 exige JWT del dueño al llamar `resolver_solicitud_afiliacion`, incluso desde
ms-pedidos. `service_role` conserva INSERT de pendientes y pierde UPDATE en
solicitudes; no debe usarse para sustituir la sesión al resolverlas. La migración
conserva su versión temporal generada por CLI y se ejecuta después de `0020`.
Crear también las siguientes mediante `supabase migration new`, sin intercalar
nuevas versiones cortas anteriores a la de V05. Detalles y pruebas en `tests/README.md`.

## S3-T4: oportunidades de afiliación

`0023_s3_t4_rpc_listar_oportunidades_campana.sql` añade una RPC de lectura con validación de estudiante activo y estados/vigencias visibles documentados en `tests/README.md`. No modifica tablas ni las funciones de dueño. La migración y su prueba local quedan pendientes de despliegue; no se aplicaron a Cloud.


## V06: estructura y cotización

`20261117175958_cotizar_carrito_afiliado.sql` añade la tasa de ofertas y sus
restricciones, el cálculo promocional y la cotización autenticada del carrito.
Contiene únicamente definiciones de estructura, funciones y permisos: no inserta
usuarios, productos, campañas, afiliaciones ni movimientos de ejemplo.

La columna `tasa_descuento_oferta` permanece nullable para conservar las
condiciones existentes. Se reutilizan los nombres de restricciones de C03.
La protección de condiciones continúa en los mecanismos de C03/V05; V06 no
incorpora triggers adicionales de administración de campañas.

La función pública es una fachada sin privilegios elevados. El cálculo privado
valida la sesión del usuario activo y consulta precios y elegibilidad. Mantener
`afiliados_privado` fuera de los esquemas expuestos por la Data API.
`precio_promocional` comparte la regla de promociones con el pago: mayor
descuento vigente, sin acumulación, redondeo por unidad y mínimo de 1 CLP.
Revisar su definición instalada antes de publicar esta migración.

V06 no cobra ni consume el beneficio. C07 conecta el endpoint; V07/V08 deben
serializar, revalidar y registrar la atribución junto con el pago. La publicación
en Cloud sigue pendiente de autorización específica.

## S3-T6 / CAM-228: grupos equivalentes

`20261117184822_crear_grupos_equivalentes.sql` crea el catálogo global
`grupos_equivalentes` y añade a productos una referencia nullable e indexada.
No carga datos ni clasifica productos existentes. La migración es transaccional;
el tipo y la presentación de cada grupo forman una combinación única.

La lectura del catálogo requiere `authenticated` y un UID de sesión. Solo el
backend con `service_role` puede consultar y dar de alta combinaciones; no tiene
UPDATE, DELETE ni TRUNCATE sobre el catálogo. Nunca entregar esa credencial al
cliente. El propietario SQL conserva las operaciones administrativas revisadas.
La clave foránea impide borrar o cambiar el ID de un grupo referenciado.

Se conservan las políticas y permisos existentes de productos: la asignación
del grupo respeta el alcance actual del personal de cada cafetería. Los códigos
canónicos y su presentación deben acordarse con Camilo antes de cargar catálogo
real. La revisión independiente de la migración sigue pendiente.

Validar con `npm run test:migraciones`. La evidencia funcional separada reside en
`taller-integracion-3/docs/base-datos/validacion/S3-T6-Registro-entradas-salidas.md`.
La publicación en Cloud y las pantallas/consultas de tareas posteriores no forman
parte de esta implementación local.
