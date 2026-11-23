-- V13 / CAM-182. Reutiliza el saldo y el historial de V12.
BEGIN;

CREATE FUNCTION afiliados_privado.registrar_retiro_simulado(p_monto_clp numeric)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_estudiante bigint := public.estudiante_afiliacion_id();
    v_disponible numeric;
BEGIN
    IF v_estudiante IS NULL THEN
        RAISE EXCEPTION 'Se requiere la sesión de un estudiante activo' USING ERRCODE = '42501';
    END IF;
    IF p_monto_clp IS NULL OR NOT (p_monto_clp BETWEEN 1 AND 9223372036854775807)
        OR p_monto_clp <> trunc(p_monto_clp) THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'monto_invalido');
    END IF;

    -- La consulta posterior al bloqueo debe ver los retiros confirmados por otras sesiones.
    IF current_setting('transaction_isolation') NOT IN ('read committed', 'read uncommitted') THEN
        RAISE EXCEPTION 'El retiro requiere aislamiento READ COMMITTED' USING ERRCODE = '25000';
    END IF;
    PERFORM 1 FROM public.usuarios WHERE id = v_estudiante FOR NO KEY UPDATE;
    IF NOT FOUND OR public.estudiante_afiliacion_id() IS DISTINCT FROM v_estudiante THEN
        RAISE EXCEPTION 'Se requiere la sesión de un estudiante activo' USING ERRCODE = '42501';
    END IF;

    -- Las comisiones disponibles son inmutables. Cancelación solo revierte pendientes.
    SELECT s.disponible_clp INTO STRICT v_disponible FROM public.consultar_saldo_afiliado() s;
    IF p_monto_clp > v_disponible THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'saldo_insuficiente');
    END IF;

    INSERT INTO public.retiros_afiliado (estudiante_id, monto_clp)
    VALUES (v_estudiante, p_monto_clp::bigint);

    RETURN jsonb_build_object(
        'ok', true,
        'monto_clp', p_monto_clp::bigint,
        'destino', 'Cuenta de prueba CoffeeFast (destino ficticio)',
        'disponible_clp', v_disponible - p_monto_clp
    );
END;
$$;

CREATE FUNCTION public.registrar_retiro_simulado(p_monto_clp numeric)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
    SELECT afiliados_privado.registrar_retiro_simulado(p_monto_clp);
$$;

REVOKE ALL ON FUNCTION afiliados_privado.registrar_retiro_simulado(numeric),
    public.registrar_retiro_simulado(numeric) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION afiliados_privado.registrar_retiro_simulado(numeric),
    public.registrar_retiro_simulado(numeric) TO authenticated;

COMMENT ON FUNCTION public.registrar_retiro_simulado(numeric) IS
    'V13: registra un retiro simulado de comisiones para la sesión propia y reduce su disponible.';

NOTIFY pgrst, 'reload schema';
COMMIT;
