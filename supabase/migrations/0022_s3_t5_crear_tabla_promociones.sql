-- S3: Gestión de promociones por cafetería.
-- Permite crear promociones generales o asociadas a un producto, con vigencia
-- opcional y acceso limitado al dueño de la cafetería.
BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS ux_productos_cafeteria_id_id
    ON public.productos (cafeteria_id, id);

CREATE TABLE IF NOT EXISTS public.promociones (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cafeteria_id bigint NOT NULL REFERENCES public.cafeterias(id) ON DELETE CASCADE,
    producto_id bigint,
    nombre varchar(120) NOT NULL CHECK (length(btrim(nombre)) BETWEEN 3 AND 120),
    descripcion text,
    descuento_porcentaje numeric(5,2) NOT NULL
        CHECK (descuento_porcentaje BETWEEN 1 AND 99),
    activo boolean NOT NULL DEFAULT true,
    inicio_en timestamptz,
    fin_en timestamptz,
    creado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
    actualizado_en timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT ck_promociones_vigencia CHECK (
        inicio_en IS NULL OR fin_en IS NULL OR fin_en > inicio_en
    ),
    CONSTRAINT fk_promociones_producto_cafeteria
        FOREIGN KEY (cafeteria_id, producto_id)
        REFERENCES public.productos (cafeteria_id, id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_promociones_cafeteria_creado
    ON public.promociones (cafeteria_id, creado_en DESC);

CREATE INDEX IF NOT EXISTS idx_promociones_cafeteria_vigencia
    ON public.promociones (cafeteria_id, activo, inicio_en, fin_en);

COMMENT ON TABLE public.promociones IS
    'Descuentos promocionales de una cafetería, opcionalmente asociados a un producto.';
COMMENT ON COLUMN public.promociones.descuento_porcentaje IS
    'Porcentaje de descuento de 1 a 99, con hasta dos decimales.';

ALTER TABLE public.promociones ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.promociones FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.promociones TO authenticated;
GRANT ALL ON public.promociones TO service_role;

DROP POLICY IF EXISTS promociones_dueno_gestion ON public.promociones;
CREATE POLICY promociones_dueno_gestion ON public.promociones
    FOR ALL TO authenticated
    USING (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    )
    WITH CHECK (
        public.es_dueno()
        AND cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
       AND NOT EXISTS (
            SELECT 1 FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime'
              AND schemaname = 'public'
              AND tablename = 'promociones'
       ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.promociones;
    END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
