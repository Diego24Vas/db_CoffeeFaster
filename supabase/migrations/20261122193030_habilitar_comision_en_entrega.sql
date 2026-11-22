BEGIN;

-- C06 instala esta columna por separado en algunos entornos.
ALTER TABLE public.pedidos
    ADD COLUMN IF NOT EXISTS qr_usado boolean NOT NULL DEFAULT false;

CREATE FUNCTION public.confirmar_entrega_pedido(
    p_pedido_id bigint,
    p_cafeteria_id bigint,
    p_credencial text
)
RETURNS SETOF public.pedidos
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_pedido public.pedidos;
BEGIN
    -- ms-pedidos autoriza al empleado. La escritura vuelve a comprobar
    -- la cafetería y la credencial persistidas al confirmar la transición.
    UPDATE public.pedidos AS p
    SET estado = 'entregado', qr_usado = true, entregado_en = clock_timestamp()
    WHERE p.id = p_pedido_id
      AND p.cafeteria_id = p_cafeteria_id
      AND p_credencial <> ''
      AND (
          CASE WHEN pg_typeof(p.qr_token) = 'uuid'::regtype
              THEN replace(p.qr_token::text, '-', '') = lower(replace(p_credencial, '-', ''))
              ELSE p.qr_token::text = p_credencial
          END
          OR p.codigo_retiro_diario = p_credencial
      )
      AND p.estado ~* '^[[:space:]]*listo[[:space:]]*$'
      AND p.qr_usado IS NOT TRUE
    RETURNING p.* INTO v_pedido;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    UPDATE public.movimientos_comision
    SET estado = 'disponible'
    WHERE pedido_id = v_pedido.id AND tipo = 'comision' AND estado = 'pendiente';

    RETURN NEXT v_pedido;
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_entrega_pedido(bigint, bigint, text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirmar_entrega_pedido(bigint, bigint, text)
    TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
