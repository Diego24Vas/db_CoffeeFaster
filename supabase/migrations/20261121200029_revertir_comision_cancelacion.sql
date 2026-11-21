-- V09 / CAM-177. Conserva el contrato y la reposición de stock de la RPC vigente.
BEGIN;
CREATE OR REPLACE FUNCTION afiliados_privado.cancelar_pedido(
  p_pedido_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  v_stock_descontado boolean;
  v_comision public.movimientos_comision;
  v_detalle RECORD;
  v_stock INTEGER;
BEGIN
  -- 1) Resolver el usuario autenticado (id interno desde auth.uid()).
  v_usuario_id := public.mi_usuario_id();

  IF v_usuario_id IS NULL THEN
    RAISE EXCEPTION 'sin_sesion'
      USING ERRCODE = '42501',
            HINT    = 'La sesion no tiene usuario interno asociado.';
  END IF;

  IF p_pedido_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'pedido_no_encontrado');
  END IF;

  -- 2) Bloquear el pedido (serializa cancelaciones concurrentes).
  SELECT p.usuario_id, p.estado, p.total, p.stock_descontado
    INTO v_ped_usuario_id, v_estado, v_total, v_stock_descontado
    FROM public.pedidos p
   WHERE p.id = p_pedido_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'pedido_no_encontrado');
  END IF;

  -- 3) Solo el propietario puede cancelar.
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

  -- 6) La Wallet usa INTEGER (CLP): el total debe ser entero y caber en INTEGER.
  IF v_total <> trunc(v_total) OR v_total > 2147483647 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'monto_no_entero');
  END IF;

  v_monto := v_total::INTEGER;

  -- La marca se escribe solo en la compra que descontó stock; no inferirla
  -- del estado, fecha, pago ni del formato de las credenciales.
  IF v_stock_descontado THEN
    IF NOT EXISTS (SELECT 1 FROM public.detalles_pedido WHERE pedido_id=p_pedido_id)
       OR EXISTS (SELECT 1 FROM public.detalles_pedido WHERE pedido_id=p_pedido_id
                  AND (producto_id IS NULL OR cantidad IS NULL OR cantidad <= 0)) THEN
      RAISE EXCEPTION 'Detalles inválidos para reponer stock' USING ERRCODE='23514';
    END IF;
    FOR v_detalle IN
      SELECT producto_id, sum(cantidad)::BIGINT AS cantidad
      FROM public.detalles_pedido WHERE pedido_id=p_pedido_id
      GROUP BY producto_id ORDER BY producto_id
    LOOP
      SELECT stock INTO v_stock FROM public.productos
      WHERE id=v_detalle.producto_id FOR UPDATE;
      IF NOT FOUND OR v_stock IS NULL OR v_stock < 0
         OR v_detalle.cantidad > 2147483647::BIGINT - v_stock THEN
        RAISE EXCEPTION 'No se puede reponer stock del producto %', v_detalle.producto_id
          USING ERRCODE='23514';
      END IF;
    END LOOP;
  END IF;

  -- 7) Bloquear la Wallet del usuario.
  SELECT w.id, w.saldo_actual
    INTO v_wallet_id, v_saldo
    FROM public.wallets w
   WHERE w.usuario_id = v_usuario_id
     FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_wallet');
  END IF;

  -- 8) Validar overflow antes de acreditar (INTEGER MAX).
  IF v_saldo IS NULL OR v_saldo > 2147483647 - v_monto THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'saldo_invalido');
  END IF;

  -- El pedido bloqueado serializa cancelación y transición de entrega.
  -- Una comisión disponible en un pedido cancelable indica una inconsistencia.
  SELECT * INTO v_comision FROM public.movimientos_comision
  WHERE pedido_id = p_pedido_id AND tipo = 'comision' FOR UPDATE;
  IF FOUND AND v_comision.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Estado de comisión incompatible con la cancelación'
      USING ERRCODE = '23514';
  END IF;

  IF v_stock_descontado THEN
    UPDATE public.productos p SET stock=p.stock+d.cantidad::INTEGER
    FROM (SELECT producto_id, sum(cantidad)::BIGINT AS cantidad
          FROM public.detalles_pedido WHERE pedido_id=p_pedido_id GROUP BY producto_id) d
    WHERE p.id=d.producto_id;
  END IF;

  -- 9) Acreditar el saldo (patron inverso de procesar_pago).
  UPDATE public.wallets
     SET saldo_actual = saldo_actual + v_monto
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

  -- No recalcular importes desde la campaña ni exigir código activo/vigencia.
  -- El trigger diferido obliga a confirmar original y compensación juntos.
  IF v_comision.id IS NOT NULL THEN
    UPDATE public.movimientos_comision SET estado = 'revertida'
    WHERE id = v_comision.id;
    INSERT INTO public.movimientos_comision (
      afiliacion_id, pedido_id, tipo, estado, base_calculo_clp,
      tasa_comision, monto_clp, movimiento_origen_id
    ) VALUES (
      v_comision.afiliacion_id, p_pedido_id, 'reversion', 'revertida',
      v_comision.base_calculo_clp, v_comision.tasa_comision,
      -v_comision.monto_clp, v_comision.id
    );
  END IF;

  -- 11) Cerrar el pedido: estado canonico + timestamp de cancelacion.
  UPDATE public.pedidos
     SET estado       = 'cancelado',
         stock_descontado = false,
         cancelado_en = CURRENT_TIMESTAMP
   WHERE id = p_pedido_id;

  -- 12) Respuesta.
  RETURN jsonb_build_object(
    'ok', true,
    'pedido_id', p_pedido_id,
    'estado', 'cancelado',
    'monto_reembolsado', v_monto,
    'saldo_nuevo', v_saldo_nuevo
  );
END;
$$;

REVOKE ALL ON FUNCTION afiliados_privado.cancelar_pedido(bigint) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION afiliados_privado.cancelar_pedido(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancelar_pedido(p_pedido_id bigint)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$
  SELECT afiliados_privado.cancelar_pedido(p_pedido_id);
$$;
REVOKE ALL ON FUNCTION public.cancelar_pedido(bigint) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancelar_pedido(bigint) TO authenticated;
DROP POLICY IF EXISTS pedidos_update_cancelar_own ON public.pedidos;
COMMENT ON FUNCTION public.cancelar_pedido(bigint) IS
  'V09 / CAM-177: cancelación, stock, reembolso y reversión de comisión históricos en una transacción autenticada.';
NOTIFY pgrst, 'reload schema';
COMMIT;
