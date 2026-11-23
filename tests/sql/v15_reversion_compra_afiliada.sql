-- CAM-264. Ejecutar con psql en la base desechable preparada por pago_afiliado.cjs.
\set ON_ERROR_STOP on
\set AUTOCOMMIT on

DO $$
BEGIN
    IF current_database() !~ '^cf_v08_test_[0-9]+_[0-9]+$' THEN
        RAISE EXCEPTION 'V15 requiere una base temporal del runner de pago afiliado';
    END IF;
END;
$$;

CREATE VIEW public.test_v15_estado AS
WITH compra AS (
    SELECT id, total, pago_estado FROM public.pedidos WHERE usuario_id = 25
)
SELECT jsonb_build_object(
    'saldo', (SELECT saldo_actual FROM public.wallets WHERE usuario_id = 25),
    'stock', (SELECT stock FROM public.productos WHERE id = 401),
    'pedidos', (SELECT count(*) FROM compra),
    'pedidos_pagados', (SELECT count(*) FROM compra WHERE total = 850 AND pago_estado = 'pagado'),
    'detalles', (SELECT count(*) FROM public.detalles_pedido WHERE pedido_id IN (SELECT id FROM compra)),
    'pagos', (SELECT count(*) FROM public.pagos WHERE pedido_id IN (SELECT id FROM compra)),
    'pagos_aprobados', (SELECT count(*) FROM public.pagos
        WHERE pedido_id IN (SELECT id FROM compra) AND estado = 'aprobado' AND monto = 850),
    'movimientos_wallet', (SELECT count(*) FROM public.movimientos_wallet
        WHERE wallet_id = (SELECT id FROM public.wallets WHERE usuario_id = 25)),
    'debitos_compra', (SELECT count(*) FROM public.movimientos_wallet
        WHERE pedido_id IN (SELECT id FROM compra) AND tipo = 'compra' AND monto = -850
          AND wallet_id = (SELECT id FROM public.wallets WHERE usuario_id = 25)),
    'comisiones', (SELECT count(*) FROM public.movimientos_comision WHERE pedido_id IN (SELECT id FROM compra)),
    'comisiones_pendientes', (SELECT count(*) FROM public.movimientos_comision
        WHERE pedido_id IN (SELECT id FROM compra) AND tipo = 'comision' AND estado = 'pendiente'
          AND afiliacion_id = 104 AND base_calculo_clp = 850 AND tasa_comision = 10 AND monto_clp = 85),
    'intentos', (SELECT count(*) FROM afiliados_privado.intentos_pago
        WHERE usuario_id = 25 AND clave = 'v15-rollback')
) AS estado;

SELECT estado AS antes FROM public.test_v15_estado \gset
SELECT public.test_assert(
    :'antes'::jsonb - 'stock' = '{
        "saldo": 100000, "pedidos": 0, "pedidos_pagados": 0, "detalles": 0,
        "pagos": 0, "pagos_aprobados": 0, "movimientos_wallet": 0, "debitos_compra": 0,
        "comisiones": 0, "comisiones_pendientes": 0, "intentos": 0
    }'::jsonb AND (:'antes'::jsonb ->> 'stock')::integer > 0,
    'V15: saldo y stock disponibles, sin compras ni escrituras previas del comprador');
\echo V15 antes: :antes

CREATE FUNCTION public.test_v15_fallar_comision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT FROM public.pedidos WHERE id = NEW.pedido_id AND usuario_id = 25) THEN
        PERFORM public.test_assert(
            EXISTS (SELECT FROM public.movimientos_wallet
                    WHERE pedido_id = NEW.pedido_id AND tipo = 'compra' AND monto = -850)
            AND (SELECT saldo_actual FROM public.wallets WHERE usuario_id = 25) = 99150,
            'V15: el pedido y el débito deben existir al intentar insertar la comisión');
        RAISE EXCEPTION USING ERRCODE = 'P0015', MESSAGE = 'fallo_controlado_v15';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER test_v15_fallar_comision BEFORE INSERT ON public.movimientos_comision
FOR EACH ROW WHEN (NEW.afiliacion_id = 104)
EXECUTE FUNCTION public.test_v15_fallar_comision();

SELECT $pago$SELECT public.procesar_pago(
    1, '[{"producto_id":401,"cantidad":1,"precio_esperado":1000}]'::jsonb,
    '12:30-12:45', 'CAFE-11', 850, 'v15-rollback') AS resultado$pago$ AS confirmar \gset

SET ROLE authenticated;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000025';
\set ON_ERROR_STOP off
:confirmar;
\set fallo :ERROR
\set codigo :LAST_ERROR_SQLSTATE
\set mensaje :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
\echo V15 error observado: :codigo :mensaje

-- Una conexión nueva lee el estado después de que terminó la llamada fallida.
\connect -reuse-previous=on :DBNAME
SELECT public.test_assert(
    :'fallo'::boolean AND :'codigo' = 'P0015' AND :'mensaje' = 'fallo_controlado_v15',
    'V15: se esperaba el fallo controlado al insertar la comisión');
SELECT estado AS despues_fallo FROM public.test_v15_estado \gset
\echo V15 despues del fallo: :despues_fallo
SELECT public.test_assert(:'despues_fallo'::jsonb = :'antes'::jsonb,
    'V15: el fallo debe conservar todo el estado inicial y dejar libre la clave');

DROP TRIGGER test_v15_fallar_comision ON public.movimientos_comision;
DROP FUNCTION public.test_v15_fallar_comision();

SET ROLE authenticated;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000025';
:confirmar \gset compra_
\connect -reuse-previous=on :DBNAME

SELECT estado AS despues_compra FROM public.test_v15_estado \gset
\echo V15 despues de la compra: :despues_compra
SELECT public.test_assert(
    :'compra_resultado'::jsonb @> '{"ok":true,"total_pagado":850,"comision":85,"saldo_restante":99150}'::jsonb
    AND :'despues_compra'::jsonb = '{
        "saldo": 99150, "pedidos": 1, "pedidos_pagados": 1, "detalles": 1,
        "pagos": 1, "pagos_aprobados": 1, "movimientos_wallet": 1, "debitos_compra": 1,
        "comisiones": 1, "comisiones_pendientes": 1, "intentos": 1
    }'::jsonb || jsonb_build_object('stock', (:'antes'::jsonb ->> 'stock')::integer - 1),
    'V15: el reintento debe persistir una compra, un débito y una comisión pendiente');

SET ROLE authenticated;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000025';
:confirmar \gset repetido_
\connect -reuse-previous=on :DBNAME
SELECT public.test_assert(
    :'repetido_resultado'::jsonb = :'compra_resultado'::jsonb
    AND (SELECT estado FROM public.test_v15_estado) = :'despues_compra'::jsonb,
    'V15: repetir la confirmación devuelve el mismo pedido y conserva el estado');

DROP VIEW public.test_v15_estado;
\echo V15 aprobado: reversión completa, un único cobro y una única comisión tras el reintento.
