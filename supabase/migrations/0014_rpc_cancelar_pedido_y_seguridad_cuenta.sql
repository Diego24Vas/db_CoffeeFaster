-- ====================================================================
-- MIGRACIÓN 0014: RPC cancelar_pedido, endurecimiento de seguridad y RLS de cuenta (S2-T18)
-- Tarea: S2-T18-Diego Vásquez — Corregir incidencias de cuenta
--
-- Objetivos:
-- 1. Desplegar la función RPC transaccional cancelar_pedido(BIGINT) RETURNS JSONB
--    con reembolso íntegro a Wallet, registro en movimientos_wallet y actualización
--    a estado canónico 'cancelado' (SECURITY DEFINER).
-- 2. Eliminar la directiva legacy 'pedidos_update_cancelar_own' en pedidos para
--    garantizar que ninguna cancelación de cliente evada el reembolso transaccional.
-- 3. Endurecer la directiva RLS 'usuarios_update_own' en public.usuarios para
--    permitir que usuarios autenticados editen su perfil incluso ante inconsistencias
--    en auth_user_id (vinculación por email o mi_usuario_id()).
-- 4. Notificar a PostgREST para recargar la caché de esquemas.
--
-- Idempotente: seguro de ejecutar en Supabase SQL Editor o migraciones CLI.
-- ====================================================================

-- --------------------------------------------------------------------
-- 1. FUNCIÓN RPC TRANSACCIONAL: cancelar_pedido
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancelar_pedido(
    p_pedido_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario_id     BIGINT;
    v_ped_usuario_id BIGINT;
    v_estado         TEXT;
    v_total          NUMERIC(10,2);
    v_monto          INTEGER;
    v_wallet_id      BIGINT;
    v_saldo          INTEGER;
    v_saldo_nuevo    INTEGER;
BEGIN
    -- 1) Resolver el usuario autenticado (id interno desde auth.uid()).
    v_usuario_id := public.mi_usuario_id();

    IF v_usuario_id IS NULL THEN
        RAISE EXCEPTION 'sin_sesion'
            USING ERRCODE = '42501',
                  HINT    = 'La sesión no tiene usuario interno asociado.';
    END IF;

    IF p_pedido_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'pedido_no_encontrado');
    END IF;

    -- 2) Bloquear el pedido (serializa cancelaciones concurrentes).
    SELECT p.usuario_id, p.estado, p.total
      INTO v_ped_usuario_id, v_estado, v_total
      FROM public.pedidos p
     WHERE p.id = p_pedido_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'pedido_no_encontrado');
    END IF;

    -- 3) Solo el propietario puede cancelar su propio pedido.
    IF v_ped_usuario_id IS DISTINCT FROM v_usuario_id THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'no_autorizado');
    END IF;

    -- 4) Solo se cancela desde 'pendiente' (legacy de lectura: 'pagado').
    IF lower(v_estado) = 'cancelado' THEN
        RETURN jsonb_build_object(
            'ok', false, 'motivo', 'ya_cancelado', 'estado_actual', 'cancelado'
        );
    END IF;

    IF v_estado IS NULL OR lower(v_estado) NOT IN ('pendiente', 'pagado') THEN
        RETURN jsonb_build_object(
            'ok', false, 'motivo', 'no_cancelable', 'estado_actual', v_estado
        );
    END IF;

    -- 5) Monto autoritativo: pedidos.total (NO se recalcula desde productos).
    IF v_total IS NULL OR v_total <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'monto_invalido');
    END IF;

    -- 6) La Wallet usa INTEGER (CLP): validar enteros y overflow.
    IF v_total <> trunc(v_total) OR v_total > 2147483647 THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'monto_no_entero');
    END IF;

    v_monto := v_total::INTEGER;

    -- 7) Bloquear o auto-crear la Wallet del usuario para asegurar el abono.
    SELECT w.id, w.saldo_actual
      INTO v_wallet_id, v_saldo
      FROM public.wallets w
     WHERE w.usuario_id = v_usuario_id
       FOR UPDATE;

    IF v_wallet_id IS NULL THEN
        INSERT INTO public.wallets (usuario_id, saldo_actual)
        VALUES (v_usuario_id, 0)
        RETURNING id, saldo_actual INTO v_wallet_id, v_saldo;
    END IF;

    -- 8) Validar overflow antes de acreditar (INTEGER MAX).
    IF v_saldo > 2147483647 - v_monto THEN
        RETURN jsonb_build_object('ok', false, 'motivo', 'saldo_invalido');
    END IF;

    -- 9) Acreditar el saldo (patrón inverso de procesar_pago).
    UPDATE public.wallets
       SET saldo_actual = saldo_actual + v_monto,
           actualizado_en = CURRENT_TIMESTAMP
     WHERE id = v_wallet_id
    RETURNING saldo_actual INTO v_saldo_nuevo;

    -- 10) Registrar el reembolso en el ledger (monto POSITIVO).
    INSERT INTO public.movimientos_wallet (
        wallet_id, pedido_id, tipo, monto, descripcion
    )
    VALUES (
        v_wallet_id, p_pedido_id, 'reembolso', v_monto,
        'Reembolso pedido #' || p_pedido_id::TEXT
    );

    -- 11) Cerrar el pedido: estado canónico + timestamp de cancelación.
    UPDATE public.pedidos
       SET estado       = 'cancelado',
           cancelado_en = CURRENT_TIMESTAMP
     WHERE id = p_pedido_id;

    -- 12) Respuesta estructurada.
    RETURN jsonb_build_object(
        'ok', true,
        'pedido_id', p_pedido_id,
        'estado', 'cancelado',
        'monto_reembolsado', v_monto,
        'saldo_nuevo', v_saldo_nuevo
    );
END;
$$;

-- Permisos explícitos: solo usuarios autenticados (NUNCA anon).
REVOKE ALL ON FUNCTION public.cancelar_pedido(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancelar_pedido(BIGINT) TO authenticated;

-- --------------------------------------------------------------------
-- 2. ELIMINAR DIRECTIVA DE CANCELACIÓN DIRECTA SIN REEMBOLSO
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS "pedidos_update_cancelar_own" ON public.pedidos;

-- --------------------------------------------------------------------
-- 3. ROBUSTECER POLÍTICA DE ACTUALIZACIÓN DE PERFIL EN public.usuarios
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS "usuarios_update_own" ON public.usuarios;
CREATE POLICY "usuarios_update_own" ON public.usuarios
    FOR UPDATE
    TO authenticated
    USING (
        (auth_user_id = auth.uid()) 
        OR ((email)::text = (auth.jwt() ->> 'email'::text))
        OR (id = mi_usuario_id())
    )
    WITH CHECK (
        (auth_user_id = auth.uid()) 
        OR ((email)::text = (auth.jwt() ->> 'email'::text))
        OR (id = mi_usuario_id())
    );

-- --------------------------------------------------------------------
-- 4. RECARGAR SCHEMA CACHE EN POSTGREST
-- --------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
