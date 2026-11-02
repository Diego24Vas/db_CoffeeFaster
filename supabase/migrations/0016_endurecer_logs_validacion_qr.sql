-- T12: seguridad de lectura/escritura para la tabla ya existente en 0001.
-- Conserva los nombres consumidos por Taller 3: qr_token_leido, motivo_rechazo,
-- creado_en. No se agregan columnas alternativas duplicadas.

ALTER TABLE public.logs_validacion_qr ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS logs_validacion_qr_insert_empleado ON public.logs_validacion_qr;
DROP POLICY IF EXISTS logs_validacion_qr_insert_empleado_dueno ON public.logs_validacion_qr;
DROP POLICY IF EXISTS logs_validacion_qr_select_staff ON public.logs_validacion_qr;
DROP POLICY IF EXISTS logs_validacion_qr_insert_staff ON public.logs_validacion_qr;
DROP POLICY IF EXISTS logs_validacion_qr_select_dueno ON public.logs_validacion_qr;
DROP POLICY IF EXISTS logs_validacion_qr_select_dueno_cafeteria ON public.logs_validacion_qr;
DROP POLICY IF EXISTS logs_validacion_qr_insert_operador_cafeteria ON public.logs_validacion_qr;

REVOKE ALL ON public.logs_validacion_qr FROM anon, authenticated;
GRANT SELECT, INSERT ON public.logs_validacion_qr TO authenticated;

CREATE POLICY logs_validacion_qr_insert_operador_cafeteria
    ON public.logs_validacion_qr FOR INSERT TO authenticated
    WITH CHECK (
        (public.es_empleado() OR public.es_dueno())
        AND usuario_id = public.mi_usuario_id()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND (
            pedido_id IS NULL OR EXISTS (
                SELECT 1 FROM public.pedidos p
                WHERE p.id = logs_validacion_qr.pedido_id
                  AND p.cafeteria_id = logs_validacion_qr.cafeteria_id
            )
        )
    );

CREATE POLICY logs_validacion_qr_select_dueno_cafeteria
    ON public.logs_validacion_qr FOR SELECT TO authenticated
    USING (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

CREATE INDEX IF NOT EXISTS idx_logs_validacion_qr_pedido_creado
    ON public.logs_validacion_qr (pedido_id, creado_en DESC);
CREATE INDEX IF NOT EXISTS idx_logs_validacion_qr_cafeteria_creado
    ON public.logs_validacion_qr (cafeteria_id, creado_en DESC);

COMMENT ON TABLE public.logs_validacion_qr IS
    'Auditoria de validaciones QR/token. INSERT de personal asignado; lectura del dueño asignado; sin UPDATE/DELETE desde clientes.';
