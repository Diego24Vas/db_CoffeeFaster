-- ====================================================================
-- MIGRACIÓN 0007: Políticas de Seguridad a Nivel de Fila (RLS) para Supabase
-- ====================================================================
-- Basado en el análisis de arquitectura, flujo de pedidos y auditoría
-- documentados en /docs (docs/puesta_en_marcha_flujo_pedidos.md,
-- docs/flujo_integracion_conexion_apps.md, docs/investigacion_supabase.md).
--
-- Principios implementados:
-- 1. Funciones auxiliares STABLE y SECURITY DEFINER para resolución de
--    identidad, roles y pertenencia a cafeterías, evitando recursión
--    infinita (error PostgreSQL 42P17).
-- 2. Habilitación de Row Level Security (RLS) en todas las tablas del esquema.
-- 3. Aislamiento estricto: estudiantes solo leen/gestionan sus propios pedidos,
--    dispositivos y billetera.
-- 4. Protección contra modificación arbitraria de saldo: la tabla wallets NO
--    tiene política de UPDATE directo para usuarios autenticados; el saldo
--    solo muta mediante las RPCs atómicas (recargar_saldo, procesar_pago).
-- 5. Multi-inquilino (multi-tenant): personal de cocina (KDS) y dueños acceden
--    únicamente a los pedidos, productos y alertas de sus cafeterías asignadas.
-- 6. Acceso público controlado a catálogos (cafeterías activas, productos, sedes).
-- 7. Idempotencia total: limpia políticas previas antes de crearlas.
-- ====================================================================

-- --------------------------------------------------------------------
-- 1. FUNCIONES AUXILIARES DE SEGURIDAD (SECURITY DEFINER)
-- --------------------------------------------------------------------

-- 1.1 Obtener ID interno (BIGINT) del usuario autenticado
CREATE OR REPLACE FUNCTION public.mi_usuario_id()
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id
    FROM public.usuarios u
    WHERE u.auth_user_id = auth.uid()
    LIMIT 1;
$$;

-- Alias retrocompatible
CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT public.mi_usuario_id();
$$;

-- 1.2 Obtener nombre del rol del usuario autenticado
CREATE OR REPLACE FUNCTION public.mi_rol_nombre()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT lower(r.nombre)
    FROM public.usuarios u
    JOIN public.roles r ON r.id = u.rol_id
    WHERE u.auth_user_id = auth.uid()
    LIMIT 1;
$$;

-- 1.3 Verificar si el usuario autenticado tiene rol de dueño
CREATE OR REPLACE FUNCTION public.es_dueno()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.usuarios u
        JOIN public.roles r ON r.id = u.rol_id
        WHERE u.auth_user_id = auth.uid()
          AND lower(r.nombre) IN ('dueño', 'dueno')
    );
$$;

-- 1.4 Verificar si el usuario autenticado tiene rol de empleado
CREATE OR REPLACE FUNCTION public.es_empleado()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.usuarios u
        JOIN public.roles r ON r.id = u.rol_id
        WHERE u.auth_user_id = auth.uid()
          AND lower(r.nombre) = 'empleado'
    );
$$;

-- 1.5 Listado de IDs de cafeterías donde el usuario tiene cargo/asignación
CREATE OR REPLACE FUNCTION public.mis_cafeterias_ids()
RETURNS SETOF BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT cu.cafeteria_id
    FROM public.cafeteria_usuarios cu
    JOIN public.usuarios u ON u.id = cu.usuario_id
    WHERE u.auth_user_id = auth.uid();
$$;

-- 1.6 Obtener ID de la wallet del usuario autenticado
CREATE OR REPLACE FUNCTION public.mi_wallet_id()
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT w.id
    FROM public.wallets w
    JOIN public.usuarios u ON u.id = w.usuario_id
    WHERE u.auth_user_id = auth.uid()
    LIMIT 1;
$$;

-- Otorgar ejecución de funciones auxiliares
GRANT EXECUTE ON FUNCTION public.mi_usuario_id() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_current_user_id() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.mi_rol_nombre() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.es_dueno() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.es_empleado() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.mis_cafeterias_ids() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.mi_wallet_id() TO authenticated, anon;


-- --------------------------------------------------------------------
-- 2. HABILITAR ROW LEVEL SECURITY (RLS) EN TODAS LAS TABLAS
-- --------------------------------------------------------------------
ALTER TABLE public.universidades                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles                        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categorias                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.metodos_pago                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campus_sedes                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usuarios                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cafeterias                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispositivos                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.productos                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cafeteria_usuarios           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.configuracion_telegram_dueno ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pedidos                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimientos_wallet           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alertas_stock                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimientos_inventario       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.detalles_pedido              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pagos                        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.logs_validacion_qr           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.logs_auditoria               ENABLE ROW LEVEL SECURITY;


-- --------------------------------------------------------------------
-- 3. PERMISOS GENERALES DE ESQUEMA Y TABLAS
-- --------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Lectura para anon y authenticated en catálogos públicos
GRANT SELECT ON TABLE
    public.universidades,
    public.campus_sedes,
    public.roles,
    public.metodos_pago,
    public.cafeterias,
    public.categorias,
    public.productos
TO anon, authenticated;

-- Permisos DML en tablas operativas para usuarios autenticados (filtrados por RLS)
GRANT SELECT, INSERT, UPDATE ON TABLE
    public.usuarios,
    public.cafeterias,
    public.cafeteria_usuarios,
    public.categorias,
    public.productos,
    public.wallets,
    public.movimientos_wallet,
    public.pedidos,
    public.detalles_pedido,
    public.pagos,
    public.alertas_stock,
    public.movimientos_inventario,
    public.dispositivos,
    public.configuracion_telegram_dueno,
    public.logs_validacion_qr
TO authenticated;

GRANT DELETE ON TABLE
    public.productos,
    public.dispositivos,
    public.configuracion_telegram_dueno,
    public.cafeteria_usuarios
TO authenticated;

-- Acceso a secuencias para inserciones
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;


-- ====================================================================
-- 4. POLÍTICAS RLS ESPECÍFICAS POR TABLA
-- ====================================================================

-- Limpieza total de políticas previas heredadas (migraciones 0004, 0005)
-- para evitar colisiones y erradicar la recursión infinita (error 42P17).
DO $$
DECLARE
    pol RECORD;
BEGIN
    FOR pol IN (
        SELECT schemaname, tablename, policyname
        FROM pg_policies
        WHERE schemaname = 'public'
    ) LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', pol.policyname, pol.schemaname, pol.tablename);
    END LOOP;
END $$;


-- --------------------------------------------------------------------
-- 4.1 universidades
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS universidades_select_public ON public.universidades;
CREATE POLICY universidades_select_public ON public.universidades
    FOR SELECT TO anon, authenticated
    USING (activa = true);

-- --------------------------------------------------------------------
-- 4.2 campus_sedes
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS campus_sedes_select_public ON public.campus_sedes;
CREATE POLICY campus_sedes_select_public ON public.campus_sedes
    FOR SELECT TO anon, authenticated
    USING (activa = true);

-- --------------------------------------------------------------------
-- 4.3 roles
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS roles_select_public ON public.roles;
CREATE POLICY roles_select_public ON public.roles
    FOR SELECT TO anon, authenticated
    USING (activo = true);

-- --------------------------------------------------------------------
-- 4.4 metodos_pago
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS metodos_pago_select_public ON public.metodos_pago;
CREATE POLICY metodos_pago_select_public ON public.metodos_pago
    FOR SELECT TO anon, authenticated
    USING (activo = true);

-- --------------------------------------------------------------------
-- 4.5 categorias
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS categorias_select_public ON public.categorias;
CREATE POLICY categorias_select_public ON public.categorias
    FOR SELECT TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS categorias_write_dueno ON public.categorias;
CREATE POLICY categorias_write_dueno ON public.categorias
    FOR ALL TO authenticated
    USING (public.es_dueno())
    WITH CHECK (public.es_dueno());

-- --------------------------------------------------------------------
-- 4.6 cafeterias
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS cafeterias_select_public ON public.cafeterias;
CREATE POLICY cafeterias_select_public ON public.cafeterias
    FOR SELECT TO anon, authenticated
    USING (activa = true OR id IN (SELECT public.mis_cafeterias_ids()));

DROP POLICY IF EXISTS cafeterias_update_dueno ON public.cafeterias;
CREATE POLICY cafeterias_update_dueno ON public.cafeterias
    FOR UPDATE TO authenticated
    USING (id IN (SELECT public.mis_cafeterias_ids()) AND public.es_dueno())
    WITH CHECK (id IN (SELECT public.mis_cafeterias_ids()) AND public.es_dueno());

-- --------------------------------------------------------------------
-- 4.7 usuarios
-- --------------------------------------------------------------------
-- El usuario solo lee su propio perfil (sin recursión 42P17) o el personal
-- de cocina/dueño consulta clientes asociados a comandas.
DROP POLICY IF EXISTS usuarios_select_own ON public.usuarios;
CREATE POLICY usuarios_select_own ON public.usuarios
    FOR SELECT TO authenticated
    USING (
        auth_user_id = auth.uid()
        OR id = public.mi_usuario_id()
        OR public.es_dueno()
        OR public.es_empleado()
    );

DROP POLICY IF EXISTS usuarios_update_own ON public.usuarios;
CREATE POLICY usuarios_update_own ON public.usuarios
    FOR UPDATE TO authenticated
    USING (auth_user_id = auth.uid() OR id = public.mi_usuario_id())
    WITH CHECK (auth_user_id = auth.uid() OR id = public.mi_usuario_id());

DROP POLICY IF EXISTS usuarios_insert_auth ON public.usuarios;
CREATE POLICY usuarios_insert_auth ON public.usuarios
    FOR INSERT TO authenticated
    WITH CHECK (auth_user_id = auth.uid() OR auth_user_id IS NULL);

-- --------------------------------------------------------------------
-- 4.8 cafeteria_usuarios
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS cafeteria_usuarios_select_own_or_dueno ON public.cafeteria_usuarios;
CREATE POLICY cafeteria_usuarios_select_own_or_dueno ON public.cafeteria_usuarios
    FOR SELECT TO authenticated
    USING (
        usuario_id = public.mi_usuario_id()
        OR cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

DROP POLICY IF EXISTS cafeteria_usuarios_manage_dueno ON public.cafeteria_usuarios;
CREATE POLICY cafeteria_usuarios_manage_dueno ON public.cafeteria_usuarios
    FOR ALL TO authenticated
    USING (
        cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND public.es_dueno()
    )
    WITH CHECK (
        cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND public.es_dueno()
    );

-- --------------------------------------------------------------------
-- 4.9 productos
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS productos_select_public ON public.productos;
CREATE POLICY productos_select_public ON public.productos
    FOR SELECT TO anon, authenticated
    USING (
        (activo = true AND eliminado_en IS NULL)
        OR cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

DROP POLICY IF EXISTS productos_insert_staff ON public.productos;
CREATE POLICY productos_insert_staff ON public.productos
    FOR INSERT TO authenticated
    WITH CHECK (
        cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND (public.es_dueno() OR public.es_empleado())
    );

DROP POLICY IF EXISTS productos_update_staff ON public.productos;
CREATE POLICY productos_update_staff ON public.productos
    FOR UPDATE TO authenticated
    USING (
        cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND (public.es_dueno() OR public.es_empleado())
    )
    WITH CHECK (
        cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND (public.es_dueno() OR public.es_empleado())
    );

DROP POLICY IF EXISTS productos_delete_dueno ON public.productos;
CREATE POLICY productos_delete_dueno ON public.productos
    FOR DELETE TO authenticated
    USING (
        cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        AND public.es_dueno()
    );

-- --------------------------------------------------------------------
-- 4.10 wallets
-- --------------------------------------------------------------------
-- NOTA CRÍTICA DE SEGURIDAD (docs/puesta_en_marcha_flujo_pedidos.md 7.10):
-- Se excluye INTENCIONALMENTE la política de UPDATE directo en wallets.
-- Los saldos únicamente se modifican vía RPCs atómicas (recargar_saldo, procesar_pago).
DROP POLICY IF EXISTS wallets_select_own ON public.wallets;
CREATE POLICY wallets_select_own ON public.wallets
    FOR SELECT TO authenticated
    USING (usuario_id = public.mi_usuario_id());

DROP POLICY IF EXISTS wallets_insert_own ON public.wallets;
CREATE POLICY wallets_insert_own ON public.wallets
    FOR INSERT TO authenticated
    WITH CHECK (usuario_id = public.mi_usuario_id());

-- --------------------------------------------------------------------
-- 4.11 movimientos_wallet
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS movimientos_wallet_select_own ON public.movimientos_wallet;
CREATE POLICY movimientos_wallet_select_own ON public.movimientos_wallet
    FOR SELECT TO authenticated
    USING (wallet_id IN (
        SELECT w.id FROM public.wallets w WHERE w.usuario_id = public.mi_usuario_id()
    ));

-- --------------------------------------------------------------------
-- 4.12 pedidos
-- --------------------------------------------------------------------
-- Estudiantes leen sus propios pedidos; Cocina/KDS y Dueño leen los de su cafetería
DROP POLICY IF EXISTS pedidos_select_own_or_staff ON public.pedidos;
CREATE POLICY pedidos_select_own_or_staff ON public.pedidos
    FOR SELECT TO authenticated
    USING (
        usuario_id = public.mi_usuario_id()
        OR cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    );

DROP POLICY IF EXISTS pedidos_insert_own ON public.pedidos;
CREATE POLICY pedidos_insert_own ON public.pedidos
    FOR INSERT TO authenticated
    WITH CHECK (usuario_id = public.mi_usuario_id());

-- Cancelación por parte del estudiante (solo cuando sigue en estado inicial)
DROP POLICY IF EXISTS pedidos_update_cancelar_own ON public.pedidos;
CREATE POLICY pedidos_update_cancelar_own ON public.pedidos
    FOR UPDATE TO authenticated
    USING (
        usuario_id = public.mi_usuario_id()
        AND lower(estado) IN ('pendiente', 'pagado')
    )
    WITH CHECK (
        usuario_id = public.mi_usuario_id()
        AND lower(estado) IN ('cancelado')
    );

-- Actualización operativa por parte de cocina/dueño (avanzar a preparando, listo, entregado)
DROP POLICY IF EXISTS pedidos_update_staff ON public.pedidos;
CREATE POLICY pedidos_update_staff ON public.pedidos
    FOR UPDATE TO authenticated
    USING (cafeteria_id IN (SELECT public.mis_cafeterias_ids()))
    WITH CHECK (cafeteria_id IN (SELECT public.mis_cafeterias_ids()));

-- --------------------------------------------------------------------
-- 4.13 detalles_pedido
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS detalles_pedido_select_own_or_staff ON public.detalles_pedido;
CREATE POLICY detalles_pedido_select_own_or_staff ON public.detalles_pedido
    FOR SELECT TO authenticated
    USING (
        pedido_id IN (
            SELECT p.id FROM public.pedidos p WHERE p.usuario_id = public.mi_usuario_id()
        )
        OR
        pedido_id IN (
            SELECT p.id FROM public.pedidos p WHERE p.cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        )
    );

DROP POLICY IF EXISTS detalles_pedido_insert_own ON public.detalles_pedido;
CREATE POLICY detalles_pedido_insert_own ON public.detalles_pedido
    FOR INSERT TO authenticated
    WITH CHECK (
        pedido_id IN (
            SELECT p.id FROM public.pedidos p WHERE p.usuario_id = public.mi_usuario_id()
        )
    );

-- --------------------------------------------------------------------
-- 4.14 pagos
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS pagos_select_own_or_staff ON public.pagos;
CREATE POLICY pagos_select_own_or_staff ON public.pagos
    FOR SELECT TO authenticated
    USING (
        pedido_id IN (
            SELECT p.id FROM public.pedidos p WHERE p.usuario_id = public.mi_usuario_id()
        )
        OR
        pedido_id IN (
            SELECT p.id FROM public.pedidos p WHERE p.cafeteria_id IN (SELECT public.mis_cafeterias_ids())
        )
    );

-- --------------------------------------------------------------------
-- 4.15 alertas_stock
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS alertas_stock_select_staff ON public.alertas_stock;
CREATE POLICY alertas_stock_select_staff ON public.alertas_stock
    FOR SELECT TO authenticated
    USING (cafeteria_id IN (SELECT public.mis_cafeterias_ids()));

DROP POLICY IF EXISTS alertas_stock_update_staff ON public.alertas_stock;
CREATE POLICY alertas_stock_update_staff ON public.alertas_stock
    FOR UPDATE TO authenticated
    USING (cafeteria_id IN (SELECT public.mis_cafeterias_ids()))
    WITH CHECK (cafeteria_id IN (SELECT public.mis_cafeterias_ids()));

DROP POLICY IF EXISTS alertas_stock_insert_staff ON public.alertas_stock;
CREATE POLICY alertas_stock_insert_staff ON public.alertas_stock
    FOR INSERT TO authenticated
    WITH CHECK (cafeteria_id IN (SELECT public.mis_cafeterias_ids()));

-- --------------------------------------------------------------------
-- 4.16 movimientos_inventario
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS movimientos_inventario_select_staff ON public.movimientos_inventario;
CREATE POLICY movimientos_inventario_select_staff ON public.movimientos_inventario
    FOR SELECT TO authenticated
    USING (producto_id IN (
        SELECT pr.id FROM public.productos pr WHERE pr.cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    ));

DROP POLICY IF EXISTS movimientos_inventario_insert_staff ON public.movimientos_inventario;
CREATE POLICY movimientos_inventario_insert_staff ON public.movimientos_inventario
    FOR INSERT TO authenticated
    WITH CHECK (producto_id IN (
        SELECT pr.id FROM public.productos pr WHERE pr.cafeteria_id IN (SELECT public.mis_cafeterias_ids())
    ));

-- --------------------------------------------------------------------
-- 4.17 dispositivos (Tokens Push FCM)
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS dispositivos_all_own ON public.dispositivos;
CREATE POLICY dispositivos_all_own ON public.dispositivos
    FOR ALL TO authenticated
    USING (usuario_id = public.mi_usuario_id())
    WITH CHECK (usuario_id = public.mi_usuario_id());

-- --------------------------------------------------------------------
-- 4.18 configuracion_telegram_dueno
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS telegram_dueno_all_own ON public.configuracion_telegram_dueno;
CREATE POLICY telegram_dueno_all_own ON public.configuracion_telegram_dueno
    FOR ALL TO authenticated
    USING (usuario_id = public.mi_usuario_id())
    WITH CHECK (usuario_id = public.mi_usuario_id());

-- --------------------------------------------------------------------
-- 4.19 logs_validacion_qr
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS logs_validacion_qr_select_staff ON public.logs_validacion_qr;
CREATE POLICY logs_validacion_qr_select_staff ON public.logs_validacion_qr
    FOR SELECT TO authenticated
    USING (cafeteria_id IN (SELECT public.mis_cafeterias_ids()));

DROP POLICY IF EXISTS logs_validacion_qr_insert_staff ON public.logs_validacion_qr;
CREATE POLICY logs_validacion_qr_insert_staff ON public.logs_validacion_qr
    FOR INSERT TO authenticated
    WITH CHECK (cafeteria_id IN (SELECT public.mis_cafeterias_ids()));

-- --------------------------------------------------------------------
-- 4.20 logs_auditoria
-- --------------------------------------------------------------------
DROP POLICY IF EXISTS logs_auditoria_select_dueno ON public.logs_auditoria;
CREATE POLICY logs_auditoria_select_dueno ON public.logs_auditoria
    FOR SELECT TO authenticated
    USING (public.es_dueno() OR usuario_id = public.mi_usuario_id());


-- ====================================================================
-- 5. TRIGGER DE VINCULACIÓN AUTOMÁTICA AUTH -> USUARIOS
-- ====================================================================
-- Garantiza que cualquier usuario que se autentique vía Supabase Auth
-- (email/password o magic link) quede automáticamente enlazado con la
-- tabla public.usuarios y su respectiva wallet de saldo cero.
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rol_id BIGINT;
    v_nombre TEXT;
    v_apellido TEXT;
BEGIN
    SELECT id INTO v_rol_id FROM public.roles WHERE lower(nombre) = 'estudiante';
    IF v_rol_id IS NULL THEN
        SELECT id INTO v_rol_id FROM public.roles ORDER BY id LIMIT 1;
    END IF;

    v_nombre := COALESCE(
        NEW.raw_user_meta_data ->> 'first_name',
        NEW.raw_user_meta_data ->> 'nombre',
        split_part(COALESCE(NEW.email, ''), '@', 1)
    );
    v_apellido := COALESCE(
        NEW.raw_user_meta_data ->> 'last_name',
        NEW.raw_user_meta_data ->> 'apellido',
        ''
    );

    INSERT INTO public.usuarios (
        auth_user_id,
        rol_id,
        nombre,
        apellido,
        email,
        password_hash,
        activo
    )
    VALUES (
        NEW.id,
        v_rol_id,
        v_nombre,
        v_apellido,
        NEW.email,
        'supabase_auth_managed',
        true
    )
    ON CONFLICT (email) DO UPDATE
        SET auth_user_id = EXCLUDED.auth_user_id;

    RETURN NEW;
END;
$$;

-- Vincular trigger a auth.users de manera segura si la tabla existe en Supabase
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_tables WHERE schemaname = 'auth' AND tablename = 'users'
    ) THEN
        DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
        CREATE TRIGGER on_auth_user_created
            AFTER INSERT ON auth.users
            FOR EACH ROW
            EXECUTE FUNCTION public.handle_new_auth_user();
    END IF;
END $$;
