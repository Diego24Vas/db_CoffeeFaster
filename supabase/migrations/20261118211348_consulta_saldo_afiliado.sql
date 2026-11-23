-- V12 / CAM-181. Requiere V04 y V05; no depende de V07/V08/V11.
BEGIN;

-- Libro de retiros confirmados. V13 registrará el débito atómico y V14 añadirá
-- los datos del comprobante. Los intentos rechazados no pertenecen a este libro.
CREATE TABLE public.retiros_afiliado (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    estudiante_id bigint NOT NULL REFERENCES public.usuarios(id) ON DELETE RESTRICT,
    monto_clp bigint NOT NULL CHECK (monto_clp > 0),
    creado_en timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE INDEX retiros_afiliado_estudiante_fecha_idx
    ON public.retiros_afiliado(estudiante_id, creado_en DESC);
ALTER TABLE public.retiros_afiliado ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.retiros_afiliado FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE public.retiros_afiliado_id_seq FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.retiros_afiliado TO authenticated;
CREATE POLICY retiros_afiliado_lectura_propia ON public.retiros_afiliado
    FOR SELECT TO authenticated
    USING (estudiante_id = (SELECT public.estudiante_afiliacion_id()));

CREATE FUNCTION public.proteger_historial_retiro_afiliado()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    RAISE EXCEPTION 'Los retiros confirmados son inmutables' USING ERRCODE = '23514';
END;
$$;
REVOKE ALL ON FUNCTION public.proteger_historial_retiro_afiliado()
    FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER proteger_historial_retiro_afiliado BEFORE UPDATE OR DELETE
    ON public.retiros_afiliado FOR EACH ROW
    EXECUTE FUNCTION public.proteger_historial_retiro_afiliado();

CREATE FUNCTION public.consultar_saldo_afiliado()
RETURNS TABLE (pendiente_clp numeric, disponible_clp numeric, retirado_clp numeric)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
DECLARE
    v_estudiante bigint := public.estudiante_afiliacion_id();
BEGIN
    IF v_estudiante IS NULL THEN
        RAISE EXCEPTION 'Se requiere la sesión de un estudiante activo' USING ERRCODE = '42501';
    END IF;
    -- Una sola consulta mantiene los tres importes en la misma instantánea.
    -- Agregar por separado evita multiplicar comisiones por número de retiros.
    RETURN QUERY
    WITH comisiones AS (
        SELECT coalesce(sum(m.monto_clp) FILTER (WHERE m.estado = 'pendiente'), 0) AS pendiente,
               coalesce(sum(m.monto_clp) FILTER (WHERE m.estado = 'disponible'), 0) AS disponible
        FROM public.movimientos_comision m
        JOIN public.solicitudes_afiliacion s ON s.id = m.afiliacion_id
        WHERE s.estudiante_id = v_estudiante AND m.tipo = 'comision'
    ), retiros AS (
        SELECT coalesce(sum(r.monto_clp), 0) AS retirado
        FROM public.retiros_afiliado r WHERE r.estudiante_id = v_estudiante
    )
    SELECT c.pendiente, c.disponible - r.retirado, r.retirado
    FROM comisiones c CROSS JOIN retiros r;
END;
$$;
REVOKE ALL ON FUNCTION public.consultar_saldo_afiliado()
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.consultar_saldo_afiliado() TO authenticated;
COMMENT ON TABLE public.retiros_afiliado IS
    'Retiros confirmados de comisiones, separados de la Wallet de compra. V13 insertará solo dentro del débito atómico; no guardar intentos rechazados.';
COMMENT ON FUNCTION public.consultar_saldo_afiliado() IS
    'V12: saldo propio en CLP desde comisiones y retiros. Revertidas excluidas sin restar otra vez su reversión. Numeric conserva sumas enteras sin overflow bigint. No reserva ni debita saldo.';
NOTIFY pgrst, 'reload schema';
COMMIT;
