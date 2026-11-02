-- T16: registro/idempotencia de anuncios de voz del KDS.
-- El esquema sigue el contrato usado por supabase/functions/voz-pedido:
-- reserva en_curso, finaliza emitido/fallido y permite reintentar fallidos.

CREATE TABLE IF NOT EXISTS public.anuncios_pedido (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pedido_id    bigint NOT NULL UNIQUE REFERENCES public.pedidos(id) ON DELETE CASCADE,
    cafeteria_id bigint NOT NULL REFERENCES public.cafeterias(id) ON DELETE CASCADE,
    usuario_id   bigint REFERENCES public.usuarios(id) ON DELETE SET NULL,
    canal        varchar(20) NOT NULL DEFAULT 'elevenlabs',
    modelo       varchar(80),
    voz          varchar(60),
    estado       varchar(20) NOT NULL DEFAULT 'en_curso'
                 CHECK (estado IN ('en_curso', 'emitido', 'fallido')),
    detalle      text,
    caracteres   integer CHECK (caracteres IS NULL OR caracteres >= 0),
    creado_en    timestamptz NOT NULL DEFAULT now(),
    emitido_en   timestamptz
);

-- CREATE TABLE IF NOT EXISTS no repara una tabla preexistente creada por un
-- fix local antiguo. Agrega las columnas que la Edge Function realmente usa,
-- sin renombrar ni borrar columnas legadas.
ALTER TABLE public.anuncios_pedido
    ADD COLUMN IF NOT EXISTS estado varchar(20) NOT NULL DEFAULT 'en_curso',
    ADD COLUMN IF NOT EXISTS voz varchar(60),
    ADD COLUMN IF NOT EXISTS detalle text,
    ADD COLUMN IF NOT EXISTS caracteres integer,
    ADD COLUMN IF NOT EXISTS creado_en timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS emitido_en timestamptz;

COMMENT ON TABLE public.anuncios_pedido IS
    'Control idempotente de anuncios de voz del KDS. La Edge Function voz-pedido escribe con service_role.';
COMMENT ON COLUMN public.anuncios_pedido.pedido_id IS
    'UNIQUE evita reservas duplicadas para el mismo pedido; una fila fallida puede reutilizarse en reintento.';

CREATE INDEX IF NOT EXISTS idx_anuncios_pedido_cafeteria_creado
    ON public.anuncios_pedido (cafeteria_id, creado_en DESC);
CREATE INDEX IF NOT EXISTS idx_anuncios_pedido_estado_creado
    ON public.anuncios_pedido (estado, creado_en DESC);

ALTER TABLE public.anuncios_pedido ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.anuncios_pedido FROM anon, authenticated;
GRANT SELECT ON public.anuncios_pedido TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.anuncios_pedido TO service_role;

DROP POLICY IF EXISTS anuncios_pedido_select_empleado ON public.anuncios_pedido;
DROP POLICY IF EXISTS anuncios_pedido_select_dueno ON public.anuncios_pedido;
DROP POLICY IF EXISTS anuncios_pedido_select_operador_cafeteria ON public.anuncios_pedido;
CREATE POLICY anuncios_pedido_select_operador_cafeteria
    ON public.anuncios_pedido FOR SELECT TO authenticated
    USING (
        (public.es_empleado() OR public.es_dueno())
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

-- No hay politicas de escritura para anon/authenticated: la Edge Function usa
-- service_role, que opera sin depender de permisos del cliente ni de RLS.
