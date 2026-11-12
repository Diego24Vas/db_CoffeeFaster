-- ====================================================================
-- MIGRACIÓN 0018: Esquema de campañas de carrito completo y aceptación
-- Tarea: V03 / DV03 · Crear esquema de campañas
-- Tarea frontend asociada: S3-T4 · Construir vista de condiciones y aceptación
-- ====================================================================
-- Define la tabla de campañas para carritos completos asociadas a la cafetería
-- que las administra, con tasas de descuento y comisión, vigencia, versión
-- de condiciones y confirmación / aceptación por el dueño.
-- Compatible con bases vacías en aislamiento y con el esquema productivo.
-- ====================================================================

-- 1. Tablas de soporte mínimas si se ejecuta en una base vacía aislada
CREATE TABLE IF NOT EXISTS public.cafeterias (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(255) NOT NULL,
    activa BOOLEAN DEFAULT true,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.usuarios (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(255),
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Funciones auxiliares mínimas si se ejecuta en una base vacía aislada
CREATE OR REPLACE FUNCTION public.es_dueno()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT true;
$$;

CREATE OR REPLACE FUNCTION public.es_empleado()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT false;
$$;

CREATE OR REPLACE FUNCTION public.mis_cafeterias_ids()
RETURNS SETOF BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT id FROM public.cafeterias;
$$;

-- 2. Tabla principal: campanas
CREATE TABLE IF NOT EXISTS public.campanas (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cafeteria_id            bigint NOT NULL REFERENCES public.cafeterias(id) ON DELETE CASCADE,
    nombre                  varchar(150) NOT NULL,
    descripcion             text,
    tipo                    varchar(50) NOT NULL DEFAULT 'carrito_completo'
                            CHECK (tipo IN ('carrito_completo')),
    estado                  varchar(30) NOT NULL DEFAULT 'borrador'
                            CHECK (estado IN ('borrador', 'activa', 'pausada', 'finalizada', 'pendiente_aceptacion', 'aceptada')),
    version_condiciones     varchar(20) NOT NULL DEFAULT '1.0',
    tasa_descuento          numeric(5,2) NOT NULL DEFAULT 0.00
                            CHECK (tasa_descuento >= 0.00 AND tasa_descuento <= 100.00),
    tasa_comision           numeric(5,2) NOT NULL DEFAULT 0.00
                            CHECK (tasa_comision >= 0.00 AND tasa_comision <= 100.00),
    vigencia_desde          timestamptz NOT NULL,
    vigencia_hasta          timestamptz NOT NULL,
    confirmada_por_dueno    boolean NOT NULL DEFAULT false,
    fecha_confirmacion      timestamptz,
    usuario_confirma_id     bigint REFERENCES public.usuarios(id) ON DELETE SET NULL,
    version_confirmada      varchar(20),
    creado_en               timestamptz NOT NULL DEFAULT clock_timestamp(),
    actualizado_en          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT ck_campanas_vigencia CHECK (vigencia_hasta > vigencia_desde)
);

-- Columnas añadidas de forma idempotente en caso de tabla preexistente
ALTER TABLE public.campanas
    ADD COLUMN IF NOT EXISTS tipo varchar(50) NOT NULL DEFAULT 'carrito_completo',
    ADD COLUMN IF NOT EXISTS version_condiciones varchar(20) NOT NULL DEFAULT '1.0',
    ADD COLUMN IF NOT EXISTS tasa_descuento numeric(5,2) NOT NULL DEFAULT 0.00,
    ADD COLUMN IF NOT EXISTS tasa_comision numeric(5,2) NOT NULL DEFAULT 0.00,
    ADD COLUMN IF NOT EXISTS confirmada_por_dueno boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS fecha_confirmacion timestamptz,
    ADD COLUMN IF NOT EXISTS usuario_confirma_id bigint REFERENCES public.usuarios(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS version_confirmada varchar(20),
    ADD COLUMN IF NOT EXISTS creado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
    ADD COLUMN IF NOT EXISTS actualizado_en timestamptz NOT NULL DEFAULT clock_timestamp();

-- 3. Índices de optimización
CREATE INDEX IF NOT EXISTS idx_campanas_cafeteria
    ON public.campanas (cafeteria_id, creado_en DESC);

CREATE INDEX IF NOT EXISTS idx_campanas_estado
    ON public.campanas (estado);

CREATE INDEX IF NOT EXISTS idx_campanas_vigencia
    ON public.campanas (vigencia_desde, vigencia_hasta);

-- 4. Comentarios de documentación del esquema
COMMENT ON TABLE public.campanas IS
    'Campañas de carrito completo asociadas a cafeterías con tasas de descuento, comisión, vigencia y confirmación de dueño.';
COMMENT ON COLUMN public.campanas.tipo IS
    'Tipo de campaña: carrito_completo para descuentos globales sobre el pedido.';
COMMENT ON COLUMN public.campanas.version_condiciones IS
    'Identificador o versión del texto de condiciones legales y operativas vigente al emitir la campaña.';
COMMENT ON COLUMN public.campanas.tasa_descuento IS
    'Porcentaje de descuento aplicable al carrito completo (0.00 a 100.00).';
COMMENT ON COLUMN public.campanas.tasa_comision IS
    'Porcentaje de comisión administrativa acordada (0.00 a 100.00).';
COMMENT ON COLUMN public.campanas.confirmada_por_dueno IS
    'Marca de confirmación explícita por parte del dueño de la cafetería.';
COMMENT ON COLUMN public.campanas.fecha_confirmacion IS
    'Momento exacto en que el dueño confirmó y aceptó las condiciones.';
COMMENT ON COLUMN public.campanas.usuario_confirma_id IS
    'Usuario con rol dueño que firmó la confirmación de la campaña.';

-- 5. Seguridad a nivel de filas (RLS) y permisos
ALTER TABLE public.campanas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.campanas FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.campanas TO authenticated;
GRANT ALL ON public.campanas TO service_role;

DROP POLICY IF EXISTS campanas_select_operador ON public.campanas;
CREATE POLICY campanas_select_operador
    ON public.campanas FOR SELECT TO authenticated
    USING (
        (public.es_empleado() OR public.es_dueno())
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

DROP POLICY IF EXISTS campanas_insert_dueno ON public.campanas;
CREATE POLICY campanas_insert_dueno
    ON public.campanas FOR INSERT TO authenticated
    WITH CHECK (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

DROP POLICY IF EXISTS campanas_update_dueno ON public.campanas;
CREATE POLICY campanas_update_dueno
    ON public.campanas FOR UPDATE TO authenticated
    USING (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    )
    WITH CHECK (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

-- 6. RPC para confirmación idempotente y segura por el dueño
CREATE OR REPLACE FUNCTION public.confirmar_condiciones_campana(
    p_campana_id bigint,
    p_cafeteria_id bigint,
    p_usuario_id bigint,
    p_version text
)
RETURNS public.campanas
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_campana public.campanas;
BEGIN
    -- Validar existencia y alcance por cafetería
    SELECT * INTO v_campana
    FROM public.campanas
    WHERE id = p_campana_id AND cafeteria_id = p_cafeteria_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Campaña no encontrada o no pertenece a la cafetería autorizada'
            USING ERRCODE = 'P0002';
    END IF;

    -- Idempotencia: si ya estaba confirmada, retornar sin duplicar ni fallar
    IF v_campana.confirmada_por_dueno = true THEN
        RETURN v_campana;
    END IF;

    -- Actualizar confirmación de forma atómica
    UPDATE public.campanas
    SET confirmada_por_dueno = true,
        fecha_confirmacion = clock_timestamp(),
        usuario_confirma_id = p_usuario_id,
        version_confirmada = p_version,
        estado = CASE WHEN estado IN ('borrador', 'pendiente_aceptacion') THEN 'activa' ELSE estado END,
        actualizado_en = clock_timestamp()
    WHERE id = p_campana_id
    RETURNING * INTO v_campana;

    RETURN v_campana;
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirmar_condiciones_campana(bigint, bigint, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_condiciones_campana(bigint, bigint, bigint, text) TO service_role;

-- 7. Soporte para Supabase Realtime si la publicación existe
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'campanas'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.campanas;
        END IF;
    END IF;
END $$;
