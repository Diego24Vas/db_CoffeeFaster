-- ====================================================================
-- MIGRACIÓN 0006: Funciones y Triggers para Wallet y Procesamiento de Pagos
-- Implementa:
-- 1. get_current_user_id() / mi_usuario_id() para traducir auth.uid() a usuarios.id
-- 2. Trigger on_usuario_wallet para crear billetera automática con saldo 0
-- 3. Trigger on_wallet_updated para mantener actualizado_en
-- 4. Trigger trg_pedidos_codigo y función generar_codigo_pedido() para códigos legibles
-- 5. Función generar_token_retiro() para QR y códigos de retiro seguros
-- 6. RPC recargar_saldo() con control de topes y bloqueo FOR UPDATE
-- 7. RPC procesar_pago() transacción atómica de compra con Wallet
-- ====================================================================

-- --------------------------------------------------------------------
-- 1. Helper de Identidad de Sesión
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN (SELECT id FROM public.usuarios WHERE auth_user_id = auth.uid());
END;
$$;

-- Alias de compatibilidad
CREATE OR REPLACE FUNCTION public.mi_usuario_id()
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN public.get_current_user_id();
END;
$$;

-- --------------------------------------------------------------------
-- 2. Trigger: Creación automática de Wallet al registrar usuario
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_wallet_automatica()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.wallets (usuario_id, saldo_actual)
    VALUES (NEW.id, 0)
    ON CONFLICT (usuario_id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_usuario_wallet ON public.usuarios;
CREATE TRIGGER on_usuario_wallet
    AFTER INSERT ON public.usuarios
    FOR EACH ROW
    EXECUTE FUNCTION public.crear_wallet_automatica();

-- Backfill para usuarios ya creados previamente
INSERT INTO public.wallets (usuario_id, saldo_actual)
SELECT id, 0 FROM public.usuarios
ON CONFLICT (usuario_id) DO NOTHING;

-- --------------------------------------------------------------------
-- 3. Trigger: Actualizar timestamp de modificación en Wallet
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_wallet_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.actualizado_en = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_wallet_updated ON public.wallets;
CREATE TRIGGER on_wallet_updated
    BEFORE UPDATE ON public.wallets
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_wallet_updated_at();

-- --------------------------------------------------------------------
-- 4. Generador de código visible del pedido (ej. 91-AW1)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generar_codigo_pedido(p_id BIGINT)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $$
DECLARE
    v_alfabeto CONSTANT TEXT := 'ABCDEFGHJKMNPQRSTVWXYZ';
    v_codigo   TEXT;
    v_intentos INTEGER := 0;
BEGIN
    LOOP
        v_codigo := p_id::TEXT || '-';
        FOR i IN 1..3 LOOP
            v_codigo := v_codigo || substr(
                v_alfabeto,
                1 + floor(random() * length(v_alfabeto))::INTEGER,
                1
            );
        END LOOP;

        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM public.pedidos WHERE codigo_pedido = v_codigo
        );

        v_intentos := v_intentos + 1;
        IF v_intentos > 50 THEN
            RAISE EXCEPTION 'No se pudo generar un codigo de pedido unico para el id %', p_id;
        END IF;
    END LOOP;

    RETURN v_codigo;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_pedidos_codigo()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NEW.codigo_pedido IS NULL THEN
        NEW.codigo_pedido := public.generar_codigo_pedido(NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pedidos_codigo ON public.pedidos;
CREATE TRIGGER trg_pedidos_codigo
    BEFORE INSERT ON public.pedidos
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_pedidos_codigo();

-- --------------------------------------------------------------------
-- 5. Generador de Tokens de Retiro (QR y Contingencia legible)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generar_token_retiro(
    p_prefijo  TEXT,
    p_longitud INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $$
DECLARE
    v_alfabeto CONSTANT TEXT := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    v_token    TEXT;
BEGIN
    v_token := p_prefijo;
    FOR i IN 1..p_longitud LOOP
        v_token := v_token || substr(
            v_alfabeto,
            1 + floor(random() * length(v_alfabeto))::INTEGER,
            1
        );
    END LOOP;
    RETURN v_token;
END;
$$;

-- --------------------------------------------------------------------
-- 6. RPC: Recarga de Saldo en Wallet con Topes
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recargar_saldo(p_monto BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario_id    BIGINT;
    v_wallet_id     BIGINT;
    v_saldo_actual  INTEGER;
    v_saldo_nuevo   INTEGER;
    v_monto         INTEGER;
    v_recargado_hoy INTEGER := 0;
    v_tope_operacion  CONSTANT INTEGER := 100000;   -- $100.000 por operacion
    v_tope_diario     CONSTANT INTEGER := 200000;   -- $200.000 maximo acumulado por dia
BEGIN
    IF p_monto IS NULL OR p_monto <= 0 THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'monto_invalido',
            'mensaje', 'El monto de recarga debe ser mayor a 0.'
        );
    END IF;

    v_monto := p_monto::INTEGER;

    IF v_monto > v_tope_operacion THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'monto_excede_tope',
            'mensaje', 'La recarga supera el maximo permitido por operacion ($100.000).'
        );
    END IF;

    v_usuario_id := public.get_current_user_id();

    IF v_usuario_id IS NULL THEN
        RAISE EXCEPTION 'Tu sesion no tiene usuario interno vinculado (auth_user_id)'
            USING ERRCODE = '42501';
    END IF;

    -- Validar tope acumulado diario
    SELECT COALESCE(SUM(m.monto), 0)::INTEGER
      INTO v_recargado_hoy
    FROM public.movimientos_wallet m
    JOIN public.wallets w ON w.id = m.wallet_id
    WHERE w.usuario_id = v_usuario_id
      AND m.tipo = 'recarga'
      AND m.creado_en >= date_trunc('day', CURRENT_TIMESTAMP);

    IF v_recargado_hoy + v_monto > v_tope_diario THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'tope_diario_superado',
            'mensaje', 'Superaste el maximo de recarga permitido por dia ($200.000).',
            'recargado_hoy', v_recargado_hoy,
            'tope_diario', v_tope_diario
        );
    END IF;

    -- Bloqueo con FOR UPDATE de la fila
    SELECT id, saldo_actual INTO v_wallet_id, v_saldo_actual
    FROM public.wallets
    WHERE usuario_id = v_usuario_id
    FOR UPDATE;

    IF v_wallet_id IS NULL THEN
        INSERT INTO public.wallets (usuario_id, saldo_actual)
        VALUES (v_usuario_id, 0)
        RETURNING id, saldo_actual INTO v_wallet_id, v_saldo_actual;
    END IF;

    v_saldo_nuevo := v_saldo_actual + v_monto;

    UPDATE public.wallets
    SET saldo_actual = v_saldo_nuevo,
        actualizado_en = CURRENT_TIMESTAMP
    WHERE id = v_wallet_id;

    INSERT INTO public.movimientos_wallet (wallet_id, tipo, monto, descripcion)
    VALUES (v_wallet_id, 'recarga', v_monto, 'Recarga de saldo');

    RETURN jsonb_build_object(
        'ok', true,
        'saldo_anterior', v_saldo_actual,
        'saldo_nuevo', v_saldo_nuevo,
        'monto', v_monto,
        'mensaje', 'Recarga realizada correctamente.'
    );
END;
$$;

-- --------------------------------------------------------------------
-- 7. RPC: Procesar Pago Atómico con Wallet
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.procesar_pago(
    p_cafeteria_id  BIGINT,
    p_items         JSONB,
    p_franja_retiro TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario_id    BIGINT;
    v_wallet_id     BIGINT;
    v_saldo         INTEGER;
    v_total         INTEGER := 0;
    v_item          JSONB;
    v_producto_id   BIGINT;
    v_cantidad      INTEGER;
    v_precio        NUMERIC;
    v_subtotal      NUMERIC;
    v_pedido_id     BIGINT;
    v_metodo_id     BIGINT;
    v_detalles      JSONB := '[]'::jsonb;
    v_faltantes     TEXT := '';
    v_qr_token      TEXT;
    v_codigo        TEXT;
    v_codigo_pedido TEXT;
    v_intento       INTEGER;
BEGIN
    -- 1. Resolver usuario
    v_usuario_id := public.get_current_user_id();

    IF v_usuario_id IS NULL THEN
        RAISE EXCEPTION 'sin_sesion'
            USING ERRCODE = '42501',
                  HINT = 'Tu sesion no tiene usuario interno vinculado.';
    END IF;

    IF p_cafeteria_id IS NULL OR p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'carrito_vacio',
            'mensaje', 'El carrito esta vacio.'
        );
    END IF;

    IF p_franja_retiro IS NULL OR btrim(p_franja_retiro) = '' THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'franja_requerida',
            'mensaje', 'Elige una franja de retiro antes de pagar.'
        );
    END IF;

    -- 2. Recalcular total desde la base de datos (seguridad anti-manipulacion)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_producto_id := (v_item ->> 'producto_id')::BIGINT;
        v_cantidad    := (v_item ->> 'cantidad')::INTEGER;

        IF v_producto_id IS NULL OR v_cantidad IS NULL OR v_cantidad <= 0 THEN
            RETURN jsonb_build_object(
                'ok', false,
                'motivo', 'item_invalido',
                'mensaje', 'El carrito tiene un producto invalido.'
            );
        END IF;

        SELECT precio INTO v_precio
        FROM public.productos
        WHERE id = v_producto_id AND activo = true AND eliminado_en IS NULL;

        IF v_precio IS NULL THEN
            v_faltantes := v_faltantes || v_producto_id || ',';
            CONTINUE;
        END IF;

        v_subtotal := v_precio * v_cantidad;
        v_total := v_total + round(v_subtotal)::INTEGER;

        v_detalles := v_detalles || jsonb_build_array(jsonb_build_object(
            'producto_id',     v_producto_id,
            'cantidad',        v_cantidad,
            'precio_unitario', v_precio,
            'subtotal',        v_subtotal
        ));
    END LOOP;

    IF v_faltantes <> '' THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'producto_no_disponible',
            'mensaje', 'Uno o mas productos ya no estan disponibles.',
            'productos', v_faltantes
        );
    END IF;

    IF v_total <= 0 THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'total_invalido',
            'mensaje', 'El total del pedido no es valido.'
        );
    END IF;

    -- 3. Bloqueo con FOR UPDATE de la Wallet
    SELECT w.id, w.saldo_actual
      INTO v_wallet_id, v_saldo
      FROM public.wallets w
     WHERE w.usuario_id = v_usuario_id
       FOR UPDATE;

    IF v_wallet_id IS NULL THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'sin_wallet',
            'mensaje', 'Tu usuario no tiene Wallet asociada.'
        );
    END IF;

    -- 4. Validar saldo suficiente
    IF v_saldo < v_total THEN
        RETURN jsonb_build_object(
            'ok', false,
            'motivo', 'saldo_insuficiente',
            'mensaje', 'Saldo insuficiente en la Wallet',
            'saldo_disponible', v_saldo,
            'total', v_total,
            'faltante', v_total - v_saldo
        );
    END IF;

    -- 5. Debitar saldo
    UPDATE public.wallets
       SET saldo_actual = saldo_actual - v_total,
           actualizado_en = CURRENT_TIMESTAMP
     WHERE id = v_wallet_id
    RETURNING saldo_actual INTO v_saldo;

    -- 6. Generar tokens únicos de retiro
    v_qr_token := public.generar_token_retiro('CF-', 20);
    FOR v_intento IN 1..5 LOOP
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.pedidos WHERE qr_token = v_qr_token);
        v_qr_token := public.generar_token_retiro('CF-', 20);
    END LOOP;

    v_codigo := public.generar_token_retiro('', 8);
    FOR v_intento IN 1..5 LOOP
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.pedidos WHERE codigo_retiro_diario = v_codigo);
        v_codigo := public.generar_token_retiro('', 8);
    END LOOP;

    -- 7. Insertar Pedido
    INSERT INTO public.pedidos (
        usuario_id, cafeteria_id, total, estado, pago_estado, metodo_pago,
        franja_retiro, qr_token, codigo_retiro_diario, qr_usado
    )
    VALUES (
        v_usuario_id, p_cafeteria_id, v_total, 'pendiente', 'pagado', 'wallet',
        p_franja_retiro, v_qr_token, v_codigo, false
    )
    RETURNING id, codigo_pedido INTO v_pedido_id, v_codigo_pedido;

    -- 8. Insertar Detalles de Pedido
    INSERT INTO public.detalles_pedido (
        pedido_id, producto_id, cantidad, precio_unitario, subtotal
    )
    SELECT
        v_pedido_id,
        (d ->> 'producto_id')::BIGINT,
        (d ->> 'cantidad')::INTEGER,
        (d ->> 'precio_unitario')::NUMERIC,
        (d ->> 'subtotal')::NUMERIC
    FROM jsonb_array_elements(v_detalles) AS d;

    -- 9. Asiento de Pago (con método WALLET)
    SELECT id INTO v_metodo_id
      FROM public.metodos_pago WHERE codigo = 'WALLET' LIMIT 1;

    INSERT INTO public.pagos (
        pedido_id, metodo_pago_id, monto, estado, es_simulado, referencia_transaccion
    )
    VALUES (
        v_pedido_id, v_metodo_id, v_total, 'aprobado', false,
        'wallet-pedido-' || v_pedido_id::TEXT
    );

    -- 10. Movimiento de Wallet
    INSERT INTO public.movimientos_wallet (
        wallet_id, pedido_id, tipo, monto, descripcion
    )
    VALUES (
        v_wallet_id, v_pedido_id, 'compra', -v_total,
        'Compra cafeteria #' || p_cafeteria_id::TEXT
    );

    -- 11. Respuesta con tokens listos para retiro
    RETURN jsonb_build_object(
        'ok', true,
        'pedido_id', v_pedido_id,
        'codigo_pedido', v_codigo_pedido,
        'total', v_total,
        'saldo_restante', v_saldo,
        'estado', 'pendiente',
        'pago_estado', 'pagado',
        'franja_retiro', p_franja_retiro,
        'qr_token', v_qr_token,
        'codigo_retiro_diario', v_codigo
    );
END;
$$;
