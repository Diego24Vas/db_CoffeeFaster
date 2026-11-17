-- S3-T4: oportunidades de afiliación disponibles para estudiantes activos.
-- Lectura privilegiada y acotada: no cambia las políticas ni las funciones existentes.
BEGIN;

CREATE FUNCTION public.listar_oportunidades_campana(p_cafeteria_id bigint)
RETURNS TABLE (
    id bigint,
    nombre varchar(150),
    cafeteria_id bigint,
    cafeteria_nombre text,
    tipo varchar(50),
    estado varchar(30),
    vigencia_desde timestamptz,
    vigencia_hasta timestamptz,
    tasa_descuento numeric(5,2),
    tasa_comision numeric(5,2),
    estado_vigencia text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Se requiere una sesión autenticada' USING ERRCODE = '42501';
    END IF;
    IF p_cafeteria_id IS NULL OR p_cafeteria_id <= 0 THEN
        RAISE EXCEPTION 'p_cafeteria_id debe ser un entero positivo' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.usuarios u
        JOIN public.roles r ON r.id = u.rol_id
        WHERE u.auth_user_id = auth.uid() AND u.activo = true
          AND r.activo = true AND lower(r.nombre) = 'estudiante'
    ) THEN
        RAISE EXCEPTION 'Se requiere una cuenta activa de estudiante' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY
    SELECT c.id, c.nombre, c.cafeteria_id, caf.nombre::text, c.tipo, c.estado,
           c.vigencia_desde, c.vigencia_hasta, c.tasa_descuento, c.tasa_comision,
           CASE WHEN c.vigencia_desde > statement_timestamp() THEN 'futura' ELSE 'en_curso' END::text
    FROM public.campanas c
    JOIN public.cafeterias caf ON caf.id = c.cafeteria_id
    WHERE c.cafeteria_id = p_cafeteria_id
      AND c.estado IN ('pendiente_aceptacion', 'activa', 'aceptada')
      AND c.vigencia_hasta > statement_timestamp()
    ORDER BY c.vigencia_desde, c.id;
END;
$$;

REVOKE ALL ON FUNCTION public.listar_oportunidades_campana(bigint) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_oportunidades_campana(bigint) TO authenticated;
COMMENT ON FUNCTION public.listar_oportunidades_campana(bigint) IS
    'S3-T4: lista campañas postulables para estudiantes activos, incluidas futuras; pendiente_aceptacion permanece visible y se distingue por estado_vigencia.';

NOTIFY pgrst, 'reload schema';
COMMIT;
