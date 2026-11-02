-- T17: aislamiento por usuario/cafeteria y respuesta inmutable para solicitudes.
-- No recrea la tabla creada por 0008. Aplicable sobre entornos que ya ejecutaron
-- la migracion base; reutiliza las funciones de identidad/rol de 0007.

ALTER TABLE public.solicitudes_stock ENABLE ROW LEVEL SECURITY;

-- Asegura que las politicas permisivas anteriores no sigan sumando acceso (OR).
DROP POLICY IF EXISTS solicitudes_stock_select ON public.solicitudes_stock;
DROP POLICY IF EXISTS solicitudes_stock_insert ON public.solicitudes_stock;
DROP POLICY IF EXISTS solicitudes_stock_update_dueno ON public.solicitudes_stock;
DROP POLICY IF EXISTS solicitudes_stock_select_autorizado ON public.solicitudes_stock;
DROP POLICY IF EXISTS solicitudes_stock_insert_autorizado ON public.solicitudes_stock;
DROP POLICY IF EXISTS solicitudes_stock_update_dueno_cafeteria ON public.solicitudes_stock;

CREATE POLICY solicitudes_stock_select_autorizado
    ON public.solicitudes_stock FOR SELECT TO authenticated
    USING (
        -- El KDS puede consultar solicitudes pendientes equivalentes para
        -- evitar duplicados entre empleados de la misma cafeteria.
        (public.es_empleado()
         AND cafeteria_id IN (SELECT public.mis_cafeterias_ids()))
        OR
        (public.es_dueno()
         AND cafeteria_id IN (SELECT public.mis_cafeterias_ids()))
    );

CREATE POLICY solicitudes_stock_insert_autorizado
    ON public.solicitudes_stock FOR INSERT TO authenticated
    WITH CHECK (
        estado = 'pendiente'
        AND usuario_id = public.mi_usuario_id()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND EXISTS (
            SELECT 1 FROM public.productos p
            WHERE p.id = solicitudes_stock.producto_id
              AND p.cafeteria_id = solicitudes_stock.cafeteria_id
        )
        AND (public.es_empleado() OR public.es_dueno())
    );

CREATE POLICY solicitudes_stock_update_dueno_cafeteria
    ON public.solicitudes_stock FOR UPDATE TO authenticated
    USING (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND estado = 'pendiente'
    )
    WITH CHECK (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND estado IN ('aprobado', 'rechazado')
    );

-- Permite responder cambiando solo el estado; el trigger llena los metadatos.
REVOKE UPDATE ON public.solicitudes_stock FROM authenticated;
GRANT UPDATE (estado) ON public.solicitudes_stock TO authenticated;
REVOKE DELETE ON public.solicitudes_stock FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.registrar_respuesta_solicitud_stock()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.producto_id IS DISTINCT FROM OLD.producto_id
       OR NEW.nombre_producto IS DISTINCT FROM OLD.nombre_producto
       OR NEW.cantidad_solicitada IS DISTINCT FROM OLD.cantidad_solicitada
       OR NEW.cafeteria_id IS DISTINCT FROM OLD.cafeteria_id
       OR NEW.usuario_id IS DISTINCT FROM OLD.usuario_id
       OR NEW.observaciones IS DISTINCT FROM OLD.observaciones
       OR NEW.fecha_solicitud IS DISTINCT FROM OLD.fecha_solicitud THEN
        RAISE EXCEPTION 'Una solicitud existente no puede editar sus datos';
    END IF;

    IF OLD.estado <> 'pendiente' OR NEW.estado NOT IN ('aprobado', 'rechazado') THEN
        RAISE EXCEPTION 'Solo se puede responder una solicitud pendiente';
    END IF;

    NEW.fecha_respuesta := clock_timestamp();
    NEW.usuario_responde_id := public.mi_usuario_id();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_registrar_respuesta_solicitud_stock ON public.solicitudes_stock;
CREATE TRIGGER trg_registrar_respuesta_solicitud_stock
    BEFORE UPDATE ON public.solicitudes_stock
    FOR EACH ROW EXECUTE FUNCTION public.registrar_respuesta_solicitud_stock();

COMMENT ON FUNCTION public.registrar_respuesta_solicitud_stock() IS
    'Sella solicitudes de stock y registra identidad/fecha de la respuesta del dueño.';
