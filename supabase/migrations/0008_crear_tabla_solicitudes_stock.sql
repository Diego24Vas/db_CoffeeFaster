-- ====================================================================
-- MIGRACIÓN 0008: Creación de tabla y políticas para Solicitudes de Stock
-- ====================================================================
-- T17: Solicitudes de reposición de stock.
-- Permite que los empleados registren solicitudes de reposición ('encargar más stock')
-- desde la aplicación de escritorio y que los dueños las aprueben o rechacen.
--
-- Características de diseño y compatibilidad:
-- 1. Clave primaria identity: bigint GENERATED ALWAYS AS IDENTITY.
-- 2. Claves foráneas:
--    - producto_id: FK hacia productos(id) ON DELETE CASCADE.
--    - cafeteria_id: FK hacia cafeterias(id) ON DELETE CASCADE.
--    - usuario_id: FK hacia usuarios(id) ON DELETE SET NULL (empleado solicitante).
--    - usuario_responde_id: FK hacia usuarios(id) ON DELETE SET NULL (dueño que responde).
-- 3. Campo denormalizado 'nombre_producto' para preservar historial ante cambios/bajas.
-- 4. Restricción CHECK de estado: ('pendiente', 'aprobado', 'rechazado') con default 'pendiente'.
-- 5. Restricción CHECK de cantidad_solicitada > 0.
-- 6. Habilitación de RLS con permisos restringidos:
--    - SELECT: Personal autorizado (empleados y dueños). Compatible con funciones
--      auxiliares STABLE (public.es_dueno, public.es_empleado) e IDs de rol directos.
--    - INSERT: Empleados y dueños, forzando estado inicial 'pendiente'.
--    - UPDATE: Exclusivo para dueños (aprobación/rechazo de la solicitud).
--    - DELETE: Deshabilitado para authenticated (registro de auditoría inmutable).
-- 7. Soporte para Supabase Realtime (REPLICA IDENTITY FULL).
-- ====================================================================

-- 1. Crear tabla solicitudes_stock
CREATE TABLE IF NOT EXISTS public.solicitudes_stock (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    producto_id         bigint       NOT NULL REFERENCES public.productos(id) ON DELETE CASCADE,
    nombre_producto     varchar(150),
    cantidad_solicitada integer      NOT NULL CHECK (cantidad_solicitada > 0),
    cafeteria_id        bigint       REFERENCES public.cafeterias(id) ON DELETE CASCADE,
    usuario_id          bigint       REFERENCES public.usuarios(id) ON DELETE SET NULL,
    observaciones       text,
    estado              varchar(20)  NOT NULL DEFAULT 'pendiente'
                        CHECK (estado IN ('pendiente', 'aprobado', 'rechazado')),
    fecha_solicitud     timestamptz  NOT NULL DEFAULT clock_timestamp(),
    fecha_respuesta     timestamptz,
    usuario_responde_id bigint       REFERENCES public.usuarios(id) ON DELETE SET NULL
);

-- 2. Documentación y comentarios
COMMENT ON TABLE public.solicitudes_stock IS
  'Solicitudes de reposición de stock. El empleado inserta (estado pendiente); el dueño actualiza el estado a aprobado/rechazado registrando fecha_respuesta y usuario_responde_id.';

COMMENT ON COLUMN public.solicitudes_stock.estado IS
  'pendiente = recién creada; aprobado = el dueño la acepta; rechazado = el dueño la rechaza';

COMMENT ON COLUMN public.solicitudes_stock.nombre_producto IS
  'Nombre denormalizado del producto al momento de solicitar, para mantener la legibilidad histórica.';

-- 3. Permisos de roles Supabase
REVOKE ALL ON public.solicitudes_stock FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.solicitudes_stock TO authenticated;

-- 4. Índices para optimización de consultas y filtros
CREATE INDEX IF NOT EXISTS idx_solicitudes_stock_estado
    ON public.solicitudes_stock (estado, fecha_solicitud DESC);

CREATE INDEX IF NOT EXISTS idx_solicitudes_stock_usuario
    ON public.solicitudes_stock (usuario_id, fecha_solicitud DESC);

CREATE INDEX IF NOT EXISTS idx_solicitudes_stock_cafeteria
    ON public.solicitudes_stock (cafeteria_id, fecha_solicitud DESC);

CREATE INDEX IF NOT EXISTS idx_solicitudes_stock_producto
    ON public.solicitudes_stock (producto_id);

-- 5. Habilitar Realtime para suscripciones en vivo
ALTER TABLE public.solicitudes_stock REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables 
      WHERE pubname = 'supabase_realtime' AND tablename = 'solicitudes_stock'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.solicitudes_stock;
    END IF;
  END IF;
END $$;

-- 6. Habilitar Seguridad a Nivel de Fila (RLS)
ALTER TABLE public.solicitudes_stock ENABLE ROW LEVEL SECURITY;

-- --------------------------------------------------------------------
-- Políticas RLS
-- Nota de resiliencia: Se evalúa mediante las funciones estándar del proyecto
-- (public.es_dueno(), public.es_empleado()) y también por coincidencia de
-- u.rol_id IN (4, 6) o nombres en roles para compatibilidad entre distintos entornos.
-- --------------------------------------------------------------------

-- Política SELECT: Dueños y empleados pueden visualizar las solicitudes
DROP POLICY IF EXISTS solicitudes_stock_select ON public.solicitudes_stock;
CREATE POLICY solicitudes_stock_select
    ON public.solicitudes_stock
    FOR SELECT
    TO authenticated
    USING (
        public.es_dueno()
        OR public.es_empleado()
        OR EXISTS (
            SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid()
              AND u.rol_id IN (4, 6)
        )
    );

-- Política INSERT: Empleados y dueños pueden crear solicitudes en estado 'pendiente'
DROP POLICY IF EXISTS solicitudes_stock_insert ON public.solicitudes_stock;
CREATE POLICY solicitudes_stock_insert
    ON public.solicitudes_stock
    FOR INSERT
    TO authenticated
    WITH CHECK (
        estado = 'pendiente'
        AND (
            public.es_dueno()
            OR public.es_empleado()
            OR EXISTS (
                SELECT 1 FROM public.usuarios u
                WHERE u.auth_user_id = auth.uid()
                  AND u.rol_id IN (4, 6)
            )
        )
    );

-- Política UPDATE: Únicamente el dueño puede actualizar (aprobar o rechazar)
DROP POLICY IF EXISTS solicitudes_stock_update_dueno ON public.solicitudes_stock;
CREATE POLICY solicitudes_stock_update_dueno
    ON public.solicitudes_stock
    FOR UPDATE
    TO authenticated
    USING (
        public.es_dueno()
        OR EXISTS (
            SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid()
              AND u.rol_id = 6
        )
    )
    WITH CHECK (
        public.es_dueno()
        OR EXISTS (
            SELECT 1 FROM public.usuarios u
            WHERE u.auth_user_id = auth.uid()
              AND u.rol_id = 6
        )
    );
