-- V07 / CAM-175. Regla confirmada: primera compra por comprador y cafetería,
-- incluido historial sin código. Prevalece sobre la regla global de C01.
-- El bloqueo se conserva hasta COMMIT/ROLLBACK, nunca solo durante la consulta.
BEGIN;
CREATE INDEX pedidos_comprador_cafeteria_pagados_idx ON public.pedidos(usuario_id, cafeteria_id)
WHERE pago_estado = 'pagado' AND estado <> 'cancelado';

CREATE FUNCTION afiliados_privado.tiene_compra_previa(p_usuario bigint, p_cafeteria bigint, p_excluir_pedido bigint DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT EXISTS (SELECT 1 FROM public.pedidos p
 WHERE p.usuario_id = p_usuario AND p.cafeteria_id = p_cafeteria
 AND p.pago_estado = 'pagado' AND p.estado <> 'cancelado'
 AND (p_excluir_pedido IS NULL OR p.id <> p_excluir_pedido));
$$;
REVOKE ALL ON FUNCTION afiliados_privado.tiene_compra_previa(bigint,bigint,bigint) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION afiliados_privado.bloquear_comprador(p_usuario bigint, p_cafeteria bigint)
RETURNS void LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
BEGIN
 IF current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'La compra requiere READ COMMITTED para revalidar después del bloqueo' USING ERRCODE = '25000';
 END IF;
 IF p_usuario IS NULL OR p_cafeteria IS NULL THEN
  RAISE EXCEPTION 'Comprador y cafetería requeridos' USING ERRCODE = '22023';
 END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('V07:' || p_usuario::text || ':' || p_cafeteria::text, 0));
END;
$$;
REVOKE ALL ON FUNCTION afiliados_privado.bloquear_comprador(bigint,bigint) FROM PUBLIC, anon, authenticated, service_role;

-- Incluye pedidos sin código y cambios de pago/estado. V08 debe tomar este mismo
-- bloqueo antes de revalidar y cotizar, después de bloquear la wallet.
CREATE FUNCTION afiliados_privado.serializar_compra()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 IF NEW.usuario_id IS NOT NULL AND NEW.cafeteria_id IS NOT NULL THEN
  PERFORM afiliados_privado.bloquear_comprador(NEW.usuario_id, NEW.cafeteria_id);
 END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION afiliados_privado.serializar_compra() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER serializar_compra_v07 BEFORE INSERT OR UPDATE OF usuario_id, cafeteria_id, pago_estado, estado ON public.pedidos
FOR EACH ROW EXECUTE FUNCTION afiliados_privado.serializar_compra();

CREATE FUNCTION afiliados_privado.validar_primera_compra()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_pedido public.pedidos;
BEGIN
 IF NEW.tipo = 'comision' THEN
  SELECT * INTO STRICT v_pedido FROM public.pedidos WHERE id = NEW.pedido_id;
  PERFORM afiliados_privado.bloquear_comprador(v_pedido.usuario_id, v_pedido.cafeteria_id);
  IF afiliados_privado.tiene_compra_previa(v_pedido.usuario_id, v_pedido.cafeteria_id, v_pedido.id) THEN
   RAISE EXCEPTION 'beneficio_usado' USING ERRCODE = '23514';
  END IF;
 END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION afiliados_privado.validar_primera_compra() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER validar_primera_compra_v07 BEFORE INSERT ON public.movimientos_comision
FOR EACH ROW EXECUTE FUNCTION afiliados_privado.validar_primera_compra();

-- Reutilizar V06 sin copiar su cálculo ni modificar la migración histórica.
DO $actualizar$
DECLARE
 v_def text := pg_get_functiondef('afiliados_privado.cotizar_carrito(bigint,jsonb,text)'::regprocedure);
 v_anterior text := $regla$EXISTS (
                    SELECT 1 FROM public.movimientos_comision m
                    JOIN public.pedidos p ON p.id = m.pedido_id
                    WHERE p.usuario_id = v_comprador AND m.tipo = 'comision' AND m.estado <> 'revertida'
                )$regla$;
BEGIN
 IF strpos(v_def, v_anterior) = 0 THEN
  RAISE EXCEPTION 'La definición de V06 cambió; revise la migración V07';
 END IF;
 EXECUTE replace(v_def, v_anterior, 'afiliados_privado.tiene_compra_previa(v_comprador, p_cafeteria_id)');
END;
$actualizar$;
NOTIFY pgrst, 'reload schema';
COMMIT;
