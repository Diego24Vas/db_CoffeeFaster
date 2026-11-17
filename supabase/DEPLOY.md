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
   - `0024_s3_t4_rpc_campanas_vigentes.sql`
4. Si aparece cualquier otra migración, detener el despliegue y contrastar el
   historial. No usar `--include-all`, `--include-seed` ni `db reset` en Cloud.
5. La aplicación de las migraciones queda pendiente de autorización. Preparar
   conjuntamente la versión de la aplicación que utiliza las RPC de `0019` y `0024`.

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

## S3-T4: campañas vigentes de afiliación

`0023_s3_t4_rpc_listar_oportunidades_campana.sql` se conserva tal como estaba: creó la RPC inicial de postulables y pudo haberse aplicado en otros entornos. `0024_s3_t4_rpc_campanas_vigentes.sql` se aplica después y reemplaza solo el cuerpo con `CREATE OR REPLACE FUNCTION`, conservando la misma firma y el campo `estado_vigencia` (`en_curso`) para no romper consumidores. El resultado final lista únicamente campañas vigentes y activas, con estudiante activo, cafetería activa y límites de vigencia documentados en `tests/README.md`. No modifica tablas ni las funciones de dueño, no es una consulta de postulables futuras y no mapea los dos descuentos de C01/C02. Ambas migraciones y sus pruebas locales quedan pendientes de despliegue; no se aplicaron a Cloud.
