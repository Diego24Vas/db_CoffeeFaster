-- S3-T6 / CAM-228: catálogo global de equivalencias, sin asignaciones ni seeds.
BEGIN;

CREATE TABLE public.grupos_equivalentes (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo varchar(80) NOT NULL
        CHECK ((tipo COLLATE "C") ~ '^[a-z][a-z0-9]*(_[a-z0-9]+)*$'),
    presentacion varchar(80) NOT NULL
        CHECK ((presentacion COLLATE "C") ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
    CONSTRAINT grupos_equivalentes_tipo_presentacion_key UNIQUE (tipo, presentacion)
);

COMMENT ON TABLE public.grupos_equivalentes IS
    'S3-T6: combinaciones canónicas globales de tipo y presentación, administradas por el backend.';
COMMENT ON COLUMN public.grupos_equivalentes.tipo IS
    'Código canónico ASCII en minúsculas, con palabras separadas por guion bajo.';
COMMENT ON COLUMN public.grupos_equivalentes.presentacion IS
    'Código canónico de presentación, incluida su cantidad y unidad cuando corresponda; no es texto libre del producto.';

ALTER TABLE public.grupos_equivalentes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.grupos_equivalentes FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.grupos_equivalentes TO authenticated;
-- Sin UPDATE/DELETE: un cliente o servicio no reinterpreta grupos ya asignados.
GRANT SELECT, INSERT ON TABLE public.grupos_equivalentes TO service_role;
REVOKE ALL ON SEQUENCE public.grupos_equivalentes_id_seq FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SEQUENCE public.grupos_equivalentes_id_seq TO service_role;

CREATE POLICY grupos_equivalentes_lectura ON public.grupos_equivalentes
    FOR SELECT TO authenticated USING ((SELECT auth.uid()) IS NOT NULL);

ALTER TABLE public.productos
    ADD COLUMN grupo_equivalente_id bigint,
    ADD CONSTRAINT productos_grupo_equivalente_fkey
        FOREIGN KEY (grupo_equivalente_id) REFERENCES public.grupos_equivalentes(id)
        ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX productos_grupo_equivalente_idx ON public.productos (grupo_equivalente_id)
    WHERE grupo_equivalente_id IS NOT NULL;

COMMENT ON COLUMN public.productos.grupo_equivalente_id IS
    'NULL conserva el producto sin clasificar. Igual grupo implica el mismo tipo y presentación; no se infiere por nombre o categoría.';

NOTIFY pgrst, 'reload schema';
COMMIT;
