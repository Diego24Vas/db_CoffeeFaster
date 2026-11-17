# S3-T4 — Contrato de BD para campañas vigentes en Cloud

Documento de implementación y verificación para la consulta de campañas vigentes visible para estudiantes. Alcance limitado a S3-T4 y sus dependencias directas.

## 1. Referencias verificadas

- Fecha de inspección: **2026-11-17**.
- `main`: **`589568dddeae7133e32c7b6d4ebf182515c3fa22`**.
- `develop`: **`715a345ded1258bfcd59459f7d56e9ebcb25a30d`**.
- Entorno Cloud inspeccionado:
  - Proyecto: **`integracion3`**
  - Ref: **`yvkpmqcynpygqjvaoiwn`**
  - Región: **`us-west-2`**
  - PostgreSQL: **`17.11.0.002`**
  - Estado: **`ACTIVE_HEALTHY`**
- Cliente usado: Supabase CLI **2.117.0**, con consultas de solo lectura vía Management API y volcado de esquema con `supabase db dump`.
- No se usaron claves de servicio ni credenciales de base de datos en la salida de este documento. No se imprimieron ni guardaron secretos.

Limitaciones:

- Se inspeccionaron catálogo, definiciones y datos agregados; no se ejecutaron pruebas de PostgREST, GoTrue ni de firma de JWT contra Cloud.
- El volcado de esquema se guardó solo en un archivo temporal fuera del repositorio; no se versionó.
- No se modificó Cloud ni la BD local.
- La automatización de organización fuera de los repositorios no es visible desde Git; solo se verificaron los workflows versionados.

## 2. Esquema necesario para S3-T4

### 2.1 `public.campanas`

Definida en Git en [0018_crear_esquema_campanas.sql](../supabase/migrations/0018_crear_esquema_campanas.sql#L13-L36). En Cloud existe y coincide en columnas y restricciones principales.

| Columna | Tipo Cloud | Nulabilidad / default | Observación |
|---|---|---|---|
| `id` | `bigint` | PK, identity | |
| `cafeteria_id` | `bigint` | NOT NULL | FK `cafeterias(id)` `ON DELETE CASCADE` |
| `nombre` | `varchar(150)` | NOT NULL | |
| `descripcion` | `text` | NULL | |
| `tipo` | `varchar(50)` | NOT NULL, default `carrito_completo` | CHECK solo `carrito_completo` |
| `estado` | `varchar(30)` | NOT NULL, default `borrador` | CHECK: `borrador`, `activa`, `pausada`, `finalizada`, `pendiente_aceptacion`, `aceptada` |
| `version_condiciones` | `varchar(20)` | NOT NULL, default `1.0` | |
| `tasa_descuento` | `numeric(5,2)` | NOT NULL, default `0.00` | CHECK 0–100 |
| `tasa_comision` | `numeric(5,2)` | NOT NULL, default `0.00` | CHECK 0–100 |
| `vigencia_desde` | `timestamptz` | NOT NULL | |
| `vigencia_hasta` | `timestamptz` | NOT NULL | CHECK `vigencia_hasta > vigencia_desde` |
| `confirmada_por_dueno` | `boolean` | NOT NULL, default `false` | |
| `fecha_confirmacion` | `timestamptz` | NULL | |
| `usuario_confirma_id` | `bigint` | NULL | FK `usuarios(id)` `ON DELETE SET NULL` |
| `version_confirmada` | `varchar(20)` | NULL | |
| `creado_en` / `actualizado_en` | `timestamptz` | NOT NULL | `clock_timestamp()` |

Cloud **no** tiene `tasa_descuento_oferta`: la migración V06 no está aplicada.

### 2.2 `public.campanas_afiliados`

- **No existe en Cloud.**
- **No forma parte del esquema oficial versionado del repositorio de BD.**
- La tabla provisional de la aplicación no debe usarse como contrato de S3-T4. La consulta debe apoyarse en `public.campanas`.

### 2.3 `public.cafeterias`

Existe en Cloud. Columnas relevantes:

- `id bigint` PK.
- `campus_id bigint` NULL, FK `campus_sedes(id)` `ON DELETE CASCADE`.
- `nombre varchar(255)` NOT NULL.
- `activa boolean` NULL, default `true`.
- `creado_en`, `actualizado_en` `timestamptz`.

La consulta S3-T4 debe exigir `cafeterias.activa IS TRUE`.

### 2.4 `public.usuarios` y `public.roles`

`usuarios` existe en Cloud:

- `id bigint` PK.
- `rol_id bigint` NULL, FK `roles(id)` `ON DELETE SET NULL`.
- `nombre varchar(100)` NOT NULL, `apellido varchar(100)` NULL.
- `email varchar(255)` NOT NULL, UNIQUE.
- `password_hash varchar(255)` NOT NULL.
- `activo boolean` NULL, default `true`.
- `auth_user_id uuid` NULL, FK `auth.users(id)` `ON DELETE SET NULL`.

`roles` existe en Cloud:

- `id bigint` PK.
- `nombre varchar(100)` NOT NULL, UNIQUE.
- `activo boolean` NULL, default `true`.

Cloud tiene los roles `empleado`, `estudiante` y `dueño`, activos. La consulta S3-T4 exige rol `estudiante`, cuenta activa y rol activo.

### 2.5 `public.solicitudes_afiliacion`

Existe en Cloud y está definida en Git en [0020_modelar_afiliaciones_y_movimientos.sql](../supabase/migrations/0020_modelar_afiliaciones_y_movimientos.sql#L4-L34).

- `id bigint` PK.
- `estudiante_id bigint` NOT NULL, FK `usuarios(id)` `ON DELETE RESTRICT`.
- `campana_id bigint` NOT NULL, FK `campanas(id)` `ON DELETE RESTRICT`.
- `estado text` NOT NULL, default `pendiente`; CHECK `pendiente`, `aprobada`, `rechazada`.
- `plan_promocion text` NOT NULL, CHECK no vacío.
- `enlace_publico text` NULL.
- `codigo text` NULL; UNIQUE global.
- `codigo_activo boolean` NOT NULL, default `false`.
- `resuelta_por bigint` NULL, FK `usuarios(id)` `ON DELETE RESTRICT`.
- `resuelta_en timestamptz` NULL.
- `creado_en`, `actualizado_en` `timestamptz` NOT NULL.
- UNIQUE `(estudiante_id, campana_id)`; CHECK de código/resolución.

No es necesaria para calcular campañas vigentes. Solo afecta si la aplicación quiere mostrar “ya postulado” o el estado de una solicitud; eso requiere una consulta adicional o una ampliación posterior del contrato.

### 2.6 Objetos no aplicados en Cloud

| Objeto | Git `develop` | Cloud |
|---|---|---|
| `listar_oportunidades_campana` | `0023` + `0024` | Ausente |
| `tasa_descuento_oferta` | V06 | Ausente |
| `grupos_equivalentes` / `productos.grupo_equivalente_id` | S3-T6 | Ausentes |
| `campanas_afiliados` | No oficial | Ausente |
| `promociones` | `0022` | Presente |

## 3. Identidad y permisos

### 3.1 Vínculo de identidad

1. Supabase Auth entrega el UUID en `auth.uid()`.
2. `usuarios.auth_user_id` referencia `auth.users(id)`.
3. `usuarios.rol_id` referencia `roles(id)`.
4. Estudiante válido: `usuarios.activo = true`, `roles.activo = true` y `lower(roles.nombre) = 'estudiante'`.

La RPC de S3-T4 debe obtener la identidad únicamente de `auth.uid()`; no debe aceptar un `usuario_id` como parámetro.

### 3.2 RLS y permisos verificados en Cloud

`public.campanas`:

- RLS habilitada.
- Única política: `campanas_select_operador` para `authenticated`, usando `dueno_campana_id(cafeteria_id) IS NOT NULL`.
- No hay SELECT directo para estudiantes.
- Permisos de tabla: `authenticated` solo `SELECT`; `anon` sin acceso; `service_role` con privilegios amplios.

`public.cafeterias`:

- RLS habilitada.
- `cafeterias_select_public` permite `SELECT` a `anon`/`authenticated` para cafeterías activas o propias.
- Existen políticas de lectura/actualización para dueño.
- Los privilegios de tabla son amplios por los defaults de Supabase; la protección efectiva es RLS.

`public.usuarios`:

- RLS habilitada.
- `usuarios_select_own` permite la propia cuenta, dueño o empleado.
- `usuarios_update_own` limita la actualización.
- Los privilegios de tabla son amplios; RLS es la protección efectiva.

`public.roles`:

- RLS habilitada.
- `roles_select_public` permite leer roles activos.
- No hay política de escritura para roles de API.

`public.solicitudes_afiliacion`:

- RLS habilitada.
- Estudiante ve sus propias solicitudes; el dueño ve las de sus campañas.
- `authenticated` solo tiene `SELECT`; `service_role` tiene `SELECT` e `INSERT`, no `UPDATE`.
- La resolución se hace por RPC con JWT del dueño.

### 3.3 RPC relevantes en Cloud

| RPC | Estado | Seguridad/ACL |
|---|---|---|
| `listar_oportunidades_campana(bigint)` | **Ausente** | — |
| `obtener_campana_vigente(bigint)` | Presente | SQL STABLE, no SECURITY DEFINER, `search_path=public`, `authenticated` |
| `confirmar_condiciones_campana(bigint,bigint,text)` | Presente | SECURITY DEFINER, `search_path=public`, `authenticated`/`service_role` |
| `resolver_solicitud_afiliacion(bigint,text,text)` | Presente | SECURITY DEFINER, `search_path=''`, solo `authenticated` |
| `dueno_campana_id(bigint)` | Presente | SECURITY DEFINER, `search_path=''`, `authenticated` |
| `estudiante_afiliacion_id()` | Presente | SECURITY DEFINER, `search_path=public`, `authenticated`/`service_role` |

`obtener_campana_vigente` incluye para el dueño los estados `pendiente_aceptacion` y `activa` y exige vigencia actual; no es el contrato de estudiantes.

## 4. Contrato de consulta

### 4.1 Estado real en Cloud

`public.listar_oportunidades_campana(bigint)` **no existe** en Cloud. La consulta `to_regprocedure('public.listar_oportunidades_campana(bigint)')` devolvió `NULL`.

Por tanto, hoy un cliente que llame a esa RPC recibirá un error de función inexistente de PostgREST; no hay contrato efectivo en Cloud hasta aplicar las migraciones.

### 4.2 Contrato versionado en Git

La definición inicial está en [0023_s3_t4_rpc_listar_oportunidades_campana.sql](../supabase/migrations/0023_s3_t4_rpc_listar_oportunidades_campana.sql#L5-L55). La corrección posterior está en [0024_s3_t4_rpc_campanas_vigentes.sql](../supabase/migrations/0024_s3_t4_rpc_campanas_vigentes.sql#L7-L59).

`0024` conserva la misma firma y el mismo tipo de retorno que `0023`:

```sql
listar_oportunidades_campana(p_cafeteria_id bigint)
RETURNS TABLE (
  id bigint,
  nombre varchar(150),
  cafeteria_id bigint,
  cafeteria_nombre text,
  tipo varchar(50),
  estado varchar(30),
  vigencia_desde timestamptz,
  vigencia_hasta timestamptz,
  tasa_descuento numeric(5,2),
  tasa_comision numeric(5,2),
  estado_vigencia text
)
```

Comportamiento efectivo después de `0024`:

- Requiere `auth.uid()` no nulo.
- Requiere cuenta activa con rol activo `estudiante`.
- Exige `p_cafeteria_id` positivo.
- Filtra `cafeterias.activa IS TRUE`.
- Filtra `campanas.estado = 'activa'`.
- Exige `vigencia_desde <= statement_timestamp() < vigencia_hasta`.
- Ordena por `vigencia_desde, id`.
- Devuelve `estado_vigencia = 'en_curso'` para todas las filas vigentes; se conserva por compatibilidad con `0023`.
- Excluye `borrador`, `pausada`, `finalizada`, `pendiente_aceptacion`, `aceptada`, futuras y vencidas.
- Usa `SECURITY DEFINER`, `search_path=''`, y concede `EXECUTE` solo a `authenticated`.

`aceptada` queda excluida hasta que se defina formalmente su significado. `pendiente_aceptacion` no se expone como campaña vigente para estudiantes.

### 4.3 Contrato propuesto para `ms-pedidos`

El endpoint debe usar la sesión del estudiante, no `service_role`:

```ts
supabase.rpc('listar_oportunidades_campana', {
  p_cafeteria_id: cafeteriaId,
})
```

Campos que debe devolver la capa HTTP al cliente:

- `id`, `nombre`, `cafeteria_id`, `cafeteria_nombre`.
- `tipo`, `estado`, `estado_vigencia`.
- `vigencia_desde`, `vigencia_hasta`.
- `tasa_descuento`, `tasa_comision`.

No mapear `tasa_descuento` a `descuento_normal_pct` ni a `descuento_oferta_pct`. El modelo de dos descuentos de C01/C02 sigue siendo una integración separada y no está representado en el esquema oficial.

Traducción propuesta de errores:

| SQLSTATE / caso | HTTP propuesto |
|---|---|
| Sin JWT | `401` |
| `42501` con sesión pero sin rol estudiante activo | `403` |
| `22023` (`p_cafeteria_id` inválido) | `400` o `422` |
| RPC inexistente (`PGRST202`) hasta aplicar migraciones | `503` |
| Error inesperado | `500` |

Una cafetería activa sin campañas debe devolver `200` con `{"campanas":[]}`. En Cloud actualmente hay **0 campañas**, así que el resultado esperado es una lista vacía incluso después de aplicar la RPC.

## 5. Estado de migraciones

### 5.1 Historial registrado en Cloud

Cloud registra **`0001`–`0022`**. No registra:

- `0023_s3_t4_rpc_listar_oportunidades_campana`
- `0024_s3_t4_rpc_campanas_vigentes`
- `20261117175958_cotizar_carrito_afiliado`
- `20261117184822_crear_grupos_equivalentes`

### 5.2 Comparación con Git

`develop` contiene `0001`–`0024` y las dos migraciones con versión timestamp. `main` contiene hasta `0022`. El historial de Cloud coincide con `main` en las migraciones aplicadas, pero **no** con `develop`.

### 5.3 Objetos reales comprobados

No basta el historial; se comprobó el catálogo de Cloud:

- `campanas`, `cafeterias`, `usuarios`, `roles`, `solicitudes_afiliacion`, `movimientos_comision` y `promociones`: presentes.
- `campanas_afiliados`, `grupos_equivalentes`: ausentes.
- `productos.grupo_equivalente_id`: ausente.
- `campanas.tasa_descuento_oferta`: ausente.
- `listar_oportunidades_campana`: ausente.

Esto confirma que las migraciones S3-T4, V06 y S3-T6 no están aplicadas en Cloud, aunque sus archivos existan en Git.

### 5.4 Dependencias para habilitar S3-T4

1. `0001` y `0007`: tablas base, roles, usuarios y helpers de identidad.
2. `0018` y `0019`: `campanas`, RLS, estados y funciones de aceptación.
3. `0023`: primera versión de la RPC.
4. `0024`: cuerpo definitivo de campañas vigentes, con el mismo retorno.
5. `0020`/`0021`: solo necesarias si se mostrará estado de solicitudes; no son dependencia de la RPC de campañas.
6. V06/S3-T6 no son dependencias de S3-T4, pero forman parte del mismo lote pendiente en `develop`.

## 6. Datos existentes relevantes

Consultas agregadas realizadas en Cloud, sin exportar filas personales:

| Consulta | Resultado |
|---|---|
| Campañas totales | **0** |
| Campañas por estado | Sin filas |
| Campañas futuras / en curso / vencidas | **0 / 0 / 0** |
| Cafeterías activas / total | **1 / 1** |
| `campanas_afiliados` | No existe |

No se consultaron ni exportaron usuarios, JWT, códigos privados, solicitudes ni filas personales.

Consecuencia: la aplicación debe manejar explícitamente el estado vacío. No hay datos reales de campañas con los que validar la UI en Cloud.

## 7. Publicación

### 7.1 Procedimiento real

La publicación de migraciones es **manual** y está descrita en [supabase/DEPLOY.md](../supabase/DEPLOY.md#L24-L42):

1. Ejecutar `npm test` contra PostgreSQL de pruebas.
2. Revisar el proyecto vinculado con `supabase migration list --linked`.
3. Ejecutar `supabase db push --linked --dry-run --skip-vault`.
4. Confirmar que solo se proponen las migraciones pendientes esperadas.
5. Aplicar con autorización expresa.
6. No usar `--include-all`, `--include-seed` ni `db reset` en Cloud.

Para este estado, el dry-run debería proponer `0023`, `0024` y las dos migraciones timestamp de V06/S3-T6, en ese orden.

### 7.2 ¿Un push o merge a `main` despliega Cloud?

No se encontró automatización de migraciones en el repositorio de BD:

- El repositorio de BD no contiene `.github/workflows`.
- No hay script `supabase db push` en `package.json`.
- Los workflows del repositorio de aplicación que corren en `main` publican servicios/imágenes de la aplicación; no se encontró un paso de migración de base de datos.

Conclusión verificable en los repositorios: **un push o merge a `main` no aplica automáticamente migraciones en Cloud**. La aplicación de SQL sigue siendo un paso manual autorizado. No se puede descartar automatización externa a nivel de organización porque no es visible desde Git.

No se ejecutó `supabase db push`, ni siquiera en dry-run, durante esta inspección.

## 8. Recomendación

### Antes de integrar/publicar `main`

- Revisar y aprobar el merge `develop` → `main`, que incluye S3-T4, V06 y S3-T6.
- Confirmar que `main` no publique migraciones automáticamente; la publicación de BD debe ser explícita.
- Mantener `aceptada` fuera de la consulta hasta definir su significado.
- Resolver la incompatibilidad de los dos descuentos de C01/C02 en una tarea separada.

### Antes de aplicar migraciones en Cloud

- Autorizar la ventana de despliegue y confirmar que el proyecto es `integracion3`.
- Ejecutar `supabase migration list --linked` y `supabase db push --linked --dry-run --skip-vault`.
- Verificar que solo se proponen `0023`, `0024` y las dos migraciones timestamp.
- Aplicar y comprobar después:
  - existencia y firma de `listar_oportunidades_campana`;
  - `estado_vigencia = en_curso`;
  - RLS de `campanas` y bloqueo del SELECT directo;
  - columnas V06/S3-T6 si se aplican en el mismo lote.
- No usar `db reset` ni `--include-all`/`--include-seed`.

### Antes de habilitar el GET en la aplicación

- Aplicar `0023`/`0024` en Cloud y confirmar la RPC con una sesión de estudiante.
- Implementar la ruta de `ms-pedidos` con JWT del usuario; no usar `service_role`.
- Traducir `42501` y `22023` como se indica arriba y devolver `[]` cuando no haya campañas.
- No depender de `campanas_afiliados`.
- No mapear `tasa_descuento` a los dos descuentos del modelo provisional.
- Agregar pruebas de contrato/HTTP; la prueba SQL local ya cubre la RPC y la actualización desde `0023`.
- Considerar que Cloud no tiene campañas todavía: el flujo administrativo para crearlas queda fuera de S3-T4.

## Referencias del repositorio

- [DEPLOY.md](../supabase/DEPLOY.md)
- [0018 — esquema de campañas](../supabase/migrations/0018_crear_esquema_campanas.sql)
- [0019 — aceptación de campañas](../supabase/migrations/0019_asegurar_aceptacion_campanas.sql)
- [0020 — afiliaciones y movimientos](../supabase/migrations/0020_modelar_afiliaciones_y_movimientos.sql)
- [0021 — resolución de solicitudes](../supabase/migrations/0021_autorizar_solicitudes_afiliacion.sql)
- [0022 — promociones](../supabase/migrations/0022_s3_t5_crear_tabla_promociones.sql)
- [0023 — RPC inicial](../supabase/migrations/0023_s3_t4_rpc_listar_oportunidades_campana.sql)
- [0024 — RPC de campañas vigentes](../supabase/migrations/0024_s3_t4_rpc_campanas_vigentes.sql)
- [Pruebas S3-T4](../tests/README.md)
- [Prueba de instalación limpia](../tests/oportunidades.cjs)
- [Prueba de actualización desde 0023](../tests/oportunidades_upgrade.cjs)
