-- V14 / CAM-249. Los retiros de V13 conservan sus datos históricos.
BEGIN;

ALTER TABLE public.retiros_afiliado
    ADD COLUMN referencia uuid,
    ADD COLUMN clave_idempotencia text COLLATE "C",
    ADD COLUMN disponible_posterior_clp numeric,
    ADD CONSTRAINT retiros_afiliado_referencia_unica UNIQUE (referencia),
    ADD CONSTRAINT retiros_afiliado_clave_unica UNIQUE (estudiante_id, clave_idempotencia),
    ADD CONSTRAINT retiros_afiliado_comprobante_completo CHECK (
        (referencia IS NULL AND clave_idempotencia IS NULL AND disponible_posterior_clp IS NULL)
        OR (referencia IS NOT NULL AND clave_idempotencia IS NOT NULL
            AND octet_length(clave_idempotencia) <= 128 AND clave_idempotencia ~ '[^[:space:]]'
            AND disponible_posterior_clp IS NOT NULL AND disponible_posterior_clp >= 0)
    );

CREATE FUNCTION afiliados_privado.registrar_retiro_simulado(p_monto_clp numeric, p_clave_idempotencia text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_estudiante bigint := public.estudiante_afiliacion_id();
    v_disponible numeric;
    v_retiro public.retiros_afiliado%ROWTYPE;
BEGIN
    IF v_estudiante IS NULL THEN
        RAISE EXCEPTION 'Se requiere la sesión de un estudiante activo' USING ERRCODE = '42501';
    END IF;
    IF p_monto_clp IS NULL OR NOT (p_monto_clp BETWEEN 1 AND 9223372036854775807)
        OR p_monto_clp <> trunc(p_monto_clp) THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'monto_invalido');
    END IF;

    IF p_clave_idempotencia IS NULL OR octet_length(p_clave_idempotencia) > 128
        OR p_clave_idempotencia !~ '[^[:space:]]' THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'clave_idempotencia_invalida');
    END IF;

    -- La consulta posterior al bloqueo debe ver los retiros confirmados por otras sesiones.
    IF current_setting('transaction_isolation') NOT IN ('read committed', 'read uncommitted') THEN
        RAISE EXCEPTION 'El retiro requiere aislamiento READ COMMITTED' USING ERRCODE = '25000';
    END IF;
    PERFORM 1 FROM public.usuarios WHERE id = v_estudiante FOR NO KEY UPDATE;
    IF NOT FOUND OR public.estudiante_afiliacion_id() IS DISTINCT FROM v_estudiante THEN
        RAISE EXCEPTION 'Se requiere la sesión de un estudiante activo' USING ERRCODE = '42501';
    END IF;

    -- Resolver el reintento bajo el mismo bloqueo, incluso si ya no hay saldo.
    SELECT r.* INTO v_retiro FROM public.retiros_afiliado r
    WHERE r.estudiante_id = v_estudiante AND r.clave_idempotencia = p_clave_idempotencia;

    IF FOUND THEN
        IF v_retiro.monto_clp <> p_monto_clp THEN
            RETURN jsonb_build_object('ok', false, 'motivo', 'conflicto_idempotencia');
        END IF;
    ELSE
        -- Las comisiones disponibles son inmutables. Cancelación solo revierte pendientes.
        SELECT s.disponible_clp INTO STRICT v_disponible FROM public.consultar_saldo_afiliado() s;
        IF p_monto_clp > v_disponible THEN
            RETURN jsonb_build_object('ok', false, 'motivo', 'saldo_insuficiente');
        END IF;

        INSERT INTO public.retiros_afiliado (
            estudiante_id, monto_clp, referencia, clave_idempotencia, disponible_posterior_clp
        ) VALUES (
            v_estudiante, p_monto_clp::bigint, gen_random_uuid(),
            p_clave_idempotencia, v_disponible - p_monto_clp
        ) RETURNING * INTO v_retiro;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'estado', 'confirmado',
        'referencia', v_retiro.referencia,
        'monto_clp', v_retiro.monto_clp,
        'destino', 'Cuenta de prueba CoffeeFast (destino ficticio)',
        'disponible_clp', v_retiro.disponible_posterior_clp
    );
END;
$$;

CREATE FUNCTION public.registrar_retiro_simulado(p_monto_clp numeric, p_clave_idempotencia text)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
    SELECT afiliados_privado.registrar_retiro_simulado(p_monto_clp, p_clave_idempotencia);
$$;

-- El contrato de un argumento sigue operativo para clientes V13.
-- Solo los clientes que envían una clave propia pueden repetir la solicitud.
CREATE OR REPLACE FUNCTION public.registrar_retiro_simulado(p_monto_clp numeric)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path = '' AS $$
    SELECT public.registrar_retiro_simulado(p_monto_clp, gen_random_uuid()::text);
$$;

DROP FUNCTION afiliados_privado.registrar_retiro_simulado(numeric);

REVOKE ALL ON FUNCTION afiliados_privado.registrar_retiro_simulado(numeric,text),
    public.registrar_retiro_simulado(numeric,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION afiliados_privado.registrar_retiro_simulado(numeric,text),
    public.registrar_retiro_simulado(numeric,text) TO authenticated;

COMMENT ON FUNCTION public.registrar_retiro_simulado(numeric,text) IS
    'V14: registra un retiro simulado o recupera el comprobante original por cuenta y clave de idempotencia.';

NOTIFY pgrst, 'reload schema';
COMMIT;
