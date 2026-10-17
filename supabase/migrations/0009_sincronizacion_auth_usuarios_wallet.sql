-- ====================================================================
-- MIGRACIÓN 0009: Sincronización Automática Auth -> Usuarios -> Wallet (S2-T2)
-- Tarea: S2-T2-Diego Vásquez — Corregir flujo de confirmación de cuenta
--
-- Objetivo:
-- Garantizar que cuando un usuario se registra vía Supabase Auth (GoTrue),
-- se cree automáticamente su fila en public.usuarios y su billetera virtual
-- en public.wallets con saldo inicial 0, eliminando la necesidad de
-- inserciones manuales (seed manual).
--
-- Idempotente: seguro de ejecutar en Supabase SQL Editor o migraciones CLI.
-- ====================================================================

-- --------------------------------------------------------------------
-- 1. FUNCIÓN Y TRIGGER: auth.users -> public.usuarios
-- --------------------------------------------------------------------
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
    -- 1. Determinar rol (por defecto 'estudiante')
    SELECT id INTO v_rol_id FROM public.roles WHERE lower(nombre) = 'estudiante' LIMIT 1;
    IF v_rol_id IS NULL THEN
        SELECT id INTO v_rol_id FROM public.roles ORDER BY id LIMIT 1;
    END IF;

    -- 2. Extraer nombre y apellido desde los metadatos enviados por la app móvil
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

    -- 3. Insertar o sincronizar en public.usuarios
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


-- --------------------------------------------------------------------
-- 2. FUNCIÓN Y TRIGGER: public.usuarios -> public.wallets
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_wallet_automatica()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.wallets (usuario_id, saldo_actual)
    VALUES (NEW.id, 0)
    ON CONFLICT (usuario_id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_usuario_wallet ON public.usuarios;
CREATE TRIGGER on_usuario_wallet
    AFTER INSERT ON public.usuarios
    FOR EACH ROW
    EXECUTE FUNCTION public.crear_wallet_automatica();


-- --------------------------------------------------------------------
-- 3. POLÍTICAS RLS SEGURAS PARA public.usuarios (SIN RECURSIÓN 42P17)
-- --------------------------------------------------------------------
ALTER TABLE public.usuarios ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS usuarios_select_own ON public.usuarios;
CREATE POLICY usuarios_select_own ON public.usuarios
    FOR SELECT TO authenticated
    USING (
        auth_user_id = auth.uid()
        OR email = auth.jwt() ->> 'email'
    );

DROP POLICY IF EXISTS usuarios_update_own ON public.usuarios;
CREATE POLICY usuarios_update_own ON public.usuarios
    FOR UPDATE TO authenticated
    USING (auth_user_id = auth.uid())
    WITH CHECK (auth_user_id = auth.uid());
