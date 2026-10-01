-- ====================================================================
-- SEED COFFEEFASTER: Datos Iniciales para Desarrollo y Pruebas
-- ====================================================================
-- Este script puebla la base de datos con:
-- 1. Universidades y Sedes (UCT - Temuco)
-- 2. Roles del Sistema (estudiante, empleado, dueño)
-- 3. Categorías de Productos
-- 4. Métodos de Pago
-- 5. Cafeterías (Cafetería Central y sedes complementarias)
-- 6. Productos e Inventario (más de 8 productos con stock, precios y fotos)
-- 7. Movimientos de Inventario Iniciales
-- 8. Credenciales de Prueba en Supabase Auth y Usuarios del Sistema:
--
--    - Dueño:       dueno@coffeefaster.cl        / 123456
--                   maria.gonzalez@cafeteria.com / password123
--
--    - Empleado:    empleado@coffeefaster.cl     / 123456
--                   cocina.central@cafeteria.com / cocina2026
--
--    - Estudiante:  camilo.pago@alu.uct.cl       / pruebapago2026  (Saldo: $50.000 CLP)
--                   estudiante@alu.uct.cl        / 123456          (Saldo: $30.000 CLP)
--
-- 9. Asignación de Roles en Cafeterías (cafeteria_usuarios)
-- 10. Billeteras Virtuales (wallets) y movimientos iniciales
-- 11. Configuración de Telegram para Dueño
-- ====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- --------------------------------------------------------------------
-- 1. UNIVERSIDADES Y CAMPUS
-- --------------------------------------------------------------------
INSERT INTO public.universidades (id, nombre, rbd, activa)
VALUES (1, 'Universidad Católica de Temuco', '12345-6', true)
ON CONFLICT (id) DO UPDATE 
SET nombre = EXCLUDED.nombre, rbd = EXCLUDED.rbd, activa = true;

SELECT setval('universidades_id_seq', (SELECT GREATEST(MAX(id), 1) FROM public.universidades));

INSERT INTO public.campus_sedes (id, universidad_id, nombre_sede, ciudad, direccion, activa)
VALUES 
  (1, 1, 'Campus San Francisco', 'Temuco', 'Manuel Montt 056', true),
  (2, 1, 'Campus San Juan Pablo II', 'Temuco', 'Rudecindo Ortega 02950', true)
ON CONFLICT (id) DO UPDATE 
SET universidad_id = EXCLUDED.universidad_id,
    nombre_sede = EXCLUDED.nombre_sede,
    ciudad = EXCLUDED.ciudad,
    direccion = EXCLUDED.direccion,
    activa = true;

SELECT setval('campus_sedes_id_seq', (SELECT GREATEST(MAX(id), 2) FROM public.campus_sedes));

-- --------------------------------------------------------------------
-- 2. ROLES DEL SISTEMA
-- --------------------------------------------------------------------
INSERT INTO public.roles (id, nombre, descripcion, activo)
VALUES 
  (1, 'estudiante', 'Estudiante universitario y cliente de la cafetería', true),
  (2, 'empleado', 'Personal de cocina y atención de pedidos (KDS)', true),
  (3, 'dueño', 'Administrador y dueño de cafetería con control total', true)
ON CONFLICT (id) DO UPDATE 
SET nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion,
    activo = true;

SELECT setval('roles_id_seq', (SELECT GREATEST(MAX(id), 3) FROM public.roles));

-- --------------------------------------------------------------------
-- 3. CATEGORÍAS DE PRODUCTOS
-- --------------------------------------------------------------------
INSERT INTO public.categorias (id, nombre, descripcion)
VALUES 
  (1, 'Café y Té', 'Bebidas calientes preparadas a base de café de grano e infusiones'),
  (2, 'Bebidas Frías', 'Bebidas refrescantes, cold brews, jugos naturales y bebidas en botella'),
  (3, 'Repostería', 'Pastelería dulce artesanal, galletas, muffins y tortas'),
  (4, 'Salados', 'Sándwiches preparados en pan artesanal, empanadas y snacks salados'),
  (5, 'Extras', 'Adicionales, leches vegetales, jarabes y productos complementarios')
ON CONFLICT (id) DO UPDATE 
SET nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion;

SELECT setval('categorias_id_seq', (SELECT GREATEST(MAX(id), 5) FROM public.categorias));

-- --------------------------------------------------------------------
-- 4. MÉTODOS DE PAGO
-- --------------------------------------------------------------------
INSERT INTO public.metodos_pago (id, codigo, nombre, tipo, requiere_referencia, activo)
VALUES 
  (1, 'WALLET', 'Billetera CoffeeFast', 'digital', false, true),
  (2, 'EFECTIVO', 'Pago en Mostrador (Efectivo)', 'presencial', false, true),
  (3, 'WEBPAY', 'WebPay / Tarjetas Débito y Crédito', 'pasarela', true, true),
  (4, 'TRANSFERENCIA', 'Transferencia Bancaria', 'transferencia', true, true)
ON CONFLICT (id) DO UPDATE 
SET codigo = EXCLUDED.codigo,
    nombre = EXCLUDED.nombre,
    tipo = EXCLUDED.tipo,
    requiere_referencia = EXCLUDED.requiere_referencia,
    activo = true;

SELECT setval('metodos_pago_id_seq', (SELECT GREATEST(MAX(id), 4) FROM public.metodos_pago));

-- --------------------------------------------------------------------
-- 5. CAFETERÍAS
-- --------------------------------------------------------------------
INSERT INTO public.cafeterias (id, campus_id, nombre, descripcion, hora_apertura, hora_cierre, telefono, imagen_url, activa)
VALUES 
  (
    1, 
    1, 
    'Cafetería Central', 
    'Cafetería principal del campus San Francisco, ubicada en el edificio central. Cafés de especialidad, sándwiches frescos y repostería artesanal.',
    '07:30:00'::time, 
    '20:30:00'::time, 
    '+56 45 220 5000', 
    'https://images.unsplash.com/photo-1554118811-1e0d58224f24?w=800', 
    true
  ),
  (
    2, 
    1, 
    'Café Ingeniería', 
    'Especializada en café de grano de alta gama y opciones rápidas para estudiantes de la facultad de Ingeniería.',
    '08:00:00'::time, 
    '19:00:00'::time, 
    '+56 45 220 5111', 
    'https://images.unsplash.com/photo-1501339847302-ac426a4a7cbb?w=800', 
    true
  ),
  (
    3, 
    2, 
    'Biblioteca Café', 
    'Espacio tranquilo de estudio y cafetería ubicado dentro de la biblioteca del campus San Juan Pablo II.',
    '08:30:00'::time, 
    '21:00:00'::time, 
    '+56 45 220 5222', 
    'https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?w=800', 
    true
  )
ON CONFLICT (id) DO UPDATE 
SET campus_id = EXCLUDED.campus_id,
    nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion,
    hora_apertura = EXCLUDED.hora_apertura,
    hora_cierre = EXCLUDED.hora_cierre,
    telefono = EXCLUDED.telefono,
    imagen_url = EXCLUDED.imagen_url,
    activa = true;

SELECT setval('cafeterias_id_seq', (SELECT GREATEST(MAX(id), 3) FROM public.cafeterias));

-- --------------------------------------------------------------------
-- 6. PRODUCTOS DE INVENTARIO
-- --------------------------------------------------------------------
-- Cafetería Central (Cafetería principal con 8 productos de inventario completo)
INSERT INTO public.productos (id, cafeteria_id, categoria_id, nombre, descripcion, precio, stock, stock_minimo, imagen_url, activo)
VALUES 
  (1, 1, 1, 'Café Americano', 'Café negro clásico preparado con granos 100% arábica tostado medio de origen colombiano.', 2000.00, 60, 10, 'https://images.unsplash.com/photo-1514432324607-a09d9b4aefdd?w=600', true),
  (2, 1, 1, 'Café Latte', 'Doble shot de espresso con abundante leche vaporizada y suave microespuma artesanal.', 2600.00, 50, 10, 'https://images.unsplash.com/photo-1570968915860-54d5c301fa9f?w=600', true),
  (3, 1, 1, 'Cappuccino Clásico', 'Equilibrio perfecto de café espresso, leche texturizada y capa de espuma con toque de cacao.', 2800.00, 40, 8, 'https://images.unsplash.com/photo-1534778101976-62847782c213?w=600', true),
  (4, 1, 2, 'Iced Latte Caramelo', 'Café espresso servido en frío sobre cubos de hielo, leche fresca y salsa de caramelo.', 3200.00, 30, 5, 'https://images.unsplash.com/photo-1517701550927-30cf4ba1dba5?w=600', true),
  (5, 1, 3, 'Croissant de Almendras', 'Hojaldre francés crujiente horneado con mantequilla natural y relleno de crema de almendras tostadas.', 2800.00, 25, 5, 'https://images.unsplash.com/photo-1555507036-ab1f4038808a?w=600', true),
  (6, 1, 3, 'Muffin de Arándanos', 'Muffin esponjoso tradicional horneado con arándanos frescos de la Región de La Araucanía.', 1800.00, 35, 6, 'https://images.unsplash.com/photo-1586985289688-ca3cf47d3e6e?w=600', true),
  (7, 1, 4, 'Sándwich Mechada Queso', 'Carne mechada de cocción lenta con queso gouda fundido en pan ciabatta artesanal tostado.', 4500.00, 20, 5, 'https://images.unsplash.com/photo-1528735602780-2552fd46c7af?w=600', true),
  (8, 1, 4, 'Empanada de Pino', 'Tradicional empanada chilena al horno, con pino de carne picada, cebolla, aceituna y huevo duro.', 2500.00, 40, 10, 'https://images.unsplash.com/photo-1628840042765-356cda07504e?w=600', true),

  -- Productos complementarios en Café Ingeniería
  (9, 2, 1, 'Espresso Doble', 'Doble extracción de espresso italiano intenso con crema densa.', 1800.00, 70, 15, 'https://images.unsplash.com/photo-1510591509098-f4fdc6d0ff04?w=600', true),
  (10, 2, 1, 'Flat White', 'Doble ristretto con fina capa de leche cremosa sin exceso de espuma.', 2900.00, 40, 8, 'https://images.unsplash.com/photo-1577968897966-3d4325b36b61?w=600', true),
  (11, 2, 2, 'Cold Brew Concentrado', 'Café infusionado en frío durante 18 horas, refrescante y con baja acidez.', 3000.00, 25, 5, 'https://images.unsplash.com/photo-1517701550927-30cf4ba1dba5?w=600', true),
  (12, 2, 3, 'Brownie de Chocolate 70%', 'Brownie húmedo artesanal elaborado con cacao belga y nueces.', 2200.00, 30, 5, 'https://images.unsplash.com/photo-1606313564200-e75d5e30476c?w=600', true),
  (13, 2, 4, 'Sándwich Ave Palta', 'Pechuga de pollo desmenuzada y palta hass fresca en pan ciabatta recién horneado.', 3800.00, 25, 6, 'https://images.unsplash.com/photo-1528735602780-2552fd46c7af?w=600', true),

  -- Productos complementarios en Biblioteca Café
  (14, 3, 1, 'Té Chai Latte', 'Té negro con especias aromáticas (canela, cardamomo, clavo) y leche texturizada.', 2700.00, 35, 6, 'https://images.unsplash.com/photo-1576092768241-dec231879fc3?w=600', true),
  (15, 3, 1, 'Té Verde Matcha Latte', 'Té verde matcha ceremonial japonés batido con leche al vapor.', 3200.00, 20, 5, 'https://images.unsplash.com/photo-1515823064-d6e0c04616a7?w=600', true),
  (16, 3, 3, 'Tarta de Frambuesa', 'Tartaleta crujiente rellena de crema pastelera y frambuesas frescas del sur.', 3500.00, 15, 3, 'https://images.unsplash.com/photo-1509440159596-0249088772ff?w=600', true),
  (17, 3, 5, 'Barra de Cereal y Avena', 'Barra energética artesanal con miel de ulmo, avena y frutos secos.', 1200.00, 50, 10, 'https://images.unsplash.com/photo-1590080875515-8a3a8dc5735e?w=600', true)
ON CONFLICT (id) DO UPDATE 
SET cafeteria_id = EXCLUDED.cafeteria_id,
    categoria_id = EXCLUDED.categoria_id,
    nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion,
    precio = EXCLUDED.precio,
    stock = EXCLUDED.stock,
    stock_minimo = EXCLUDED.stock_minimo,
    imagen_url = EXCLUDED.imagen_url,
    activo = true,
    eliminado_en = NULL;

SELECT setval('productos_id_seq', (SELECT GREATEST(MAX(id), 17) FROM public.productos));

-- --------------------------------------------------------------------
-- 7. MOVIMIENTOS DE INVENTARIO (Carga inicial de stock)
-- --------------------------------------------------------------------
INSERT INTO public.movimientos_inventario (producto_id, usuario_id, tipo, cantidad, motivo)
SELECT p.id, NULL, 'ENTRADA', p.stock, 'Carga inicial de inventario del sistema'
FROM public.productos p
WHERE NOT EXISTS (
    SELECT 1 FROM public.movimientos_inventario mi WHERE mi.producto_id = p.id
);

-- --------------------------------------------------------------------
-- 8. USUARIOS, CREDENCIALES DE PRUEBA Y AUTENTICACIÓN
-- --------------------------------------------------------------------
-- Este bloque crea y sincroniza los usuarios en:
--   a) auth.users (Supabase GoTrue, email_confirmed_at, bcrypt)
--   b) auth.identities (identidad 'email' requerida por signInWithPassword)
--   c) public.usuarios (perfil con rol_id, password_hash y auth_user_id)
--   d) public.wallets (billetera virtual asociada con saldo inicial)
--   e) public.cafeteria_usuarios (permisos para KDS y administración)
-- --------------------------------------------------------------------
DO $$
DECLARE
    u RECORD;
    v_user_id UUID;
    v_enc_pass TEXT;
    v_rol_id BIGINT;
    v_cafeteria_central_id BIGINT := 1;
BEGIN
    FOR u IN
        SELECT * FROM (VALUES
            -- 1. Dueño principal (App Desktop & Dashboard)
            ('dueno@coffeefaster.cl', '123456', 'Dueño', 'Cafetería', 'dueño', '+56911112222', 0, 'd0000000-0000-0000-0000-000000000001'::uuid),
            -- 2. Dueño alternativo (compatibilidad documentación)
            ('maria.gonzalez@cafeteria.com', 'password123', 'María', 'González', 'dueño', '+56922223333', 0, 'd0000000-0000-0000-0000-000000000002'::uuid),
            -- 3. Empleado principal KDS (App Desktop)
            ('empleado@coffeefaster.cl', '123456', 'Juan', 'Empleado', 'empleado', '+56933334444', 0, 'e0000000-0000-0000-0000-000000000001'::uuid),
            -- 4. Empleado de cocina / KDS (comandas y retiro QR)
            ('cocina.central@cafeteria.com', 'cocina2026', 'Cocina', 'Central', 'empleado', '+56944445555', 0, 'e0000000-0000-0000-0000-000000000002'::uuid),
            -- 5. Estudiante principal (App Móvil / Pedidos y Billetera)
            ('camilo.pago@alu.uct.cl', 'pruebapago2026', 'Camilo', 'Pago', 'estudiante', '+56955556666', 50000, 'a0000000-0000-0000-0000-000000000001'::uuid),
            -- 6. Estudiante alternativo (App Móvil)
            ('estudiante@alu.uct.cl', '123456', 'Camila', 'Estudiante', 'estudiante', '+56966667777', 30000, 'a0000000-0000-0000-0000-000000000002'::uuid)
        ) AS t(email, password, nombre, apellido, rol, telefono, saldo_inicial, uuid_sugerido)
    LOOP
        -- Obtener ID del rol correspondiente
        SELECT id INTO v_rol_id FROM public.roles WHERE lower(nombre) = lower(u.rol) LIMIT 1;

        -- Generar hash bcrypt estándar compatible con Supabase GoTrue y Node.js bcrypt
        v_enc_pass := crypt(u.password, gen_salt('bf', 10));

        -- Comprobar si ya existe en auth.users por email
        SELECT id INTO v_user_id FROM auth.users WHERE email = u.email LIMIT 1;

        IF v_user_id IS NULL THEN
            -- Usar UUID sugerido o generar uno nuevo si está ocupado
            IF EXISTS (SELECT 1 FROM auth.users WHERE id = u.uuid_sugerido) THEN
                v_user_id := gen_random_uuid();
            ELSE
                v_user_id := u.uuid_sugerido;
            END IF;

            INSERT INTO auth.users (
                instance_id,
                id,
                aud,
                role,
                email,
                encrypted_password,
                email_confirmed_at,
                raw_app_meta_data,
                raw_user_meta_data,
                created_at,
                updated_at,
                confirmation_token,
                recovery_token,
                email_change_token_new,
                email_change,
                phone,
                phone_change,
                phone_change_token,
                email_change_token_current,
                reauthentication_token
            ) VALUES (
                '00000000-0000-0000-0000-000000000000',
                v_user_id,
                'authenticated',
                'authenticated',
                u.email,
                v_enc_pass,
                now(),
                '{"provider":"email","providers":["email"]}'::jsonb,
                jsonb_build_object(
                    'sub', v_user_id,
                    'email', u.email,
                    'first_name', u.nombre,
                    'last_name', u.apellido,
                    'nombre', u.nombre,
                    'apellido', u.apellido,
                    'rol', u.rol
                ),
                now(),
                now(),
                '', '', '', '', NULL, '', '', '', ''
            );
        ELSE
            UPDATE auth.users
            SET instance_id = '00000000-0000-0000-0000-000000000000',
                aud = 'authenticated',
                role = 'authenticated',
                encrypted_password = v_enc_pass,
                email_confirmed_at = COALESCE(email_confirmed_at, now()),
                created_at = COALESCE(created_at, now()),
                raw_app_meta_data = '{"provider":"email","providers":["email"]}'::jsonb,
                raw_user_meta_data = jsonb_build_object(
                    'sub', v_user_id,
                    'email', u.email,
                    'first_name', u.nombre,
                    'last_name', u.apellido,
                    'nombre', u.nombre,
                    'apellido', u.apellido,
                    'rol', u.rol
                ),
                updated_at = now(),
                confirmation_token = COALESCE(confirmation_token, ''),
                recovery_token = COALESCE(recovery_token, ''),
                email_change_token_new = COALESCE(email_change_token_new, ''),
                email_change = COALESCE(email_change, ''),
                phone_change = COALESCE(phone_change, ''),
                phone_change_token = COALESCE(phone_change_token, ''),
                email_change_token_current = COALESCE(email_change_token_current, ''),
                reauthentication_token = COALESCE(reauthentication_token, '')
            WHERE id = v_user_id;
        END IF;

        -- Registrar o actualizar la identidad en auth.identities (requerido por GoTrue)
        INSERT INTO auth.identities (
            id,
            user_id,
            provider_id,
            identity_data,
            provider,
            created_at,
            updated_at
        ) VALUES (
            gen_random_uuid(),
            v_user_id,
            v_user_id::text,
            jsonb_build_object(
                'sub', v_user_id,
                'email', u.email,
                'first_name', u.nombre,
                'last_name', u.apellido,
                'nombre', u.nombre,
                'apellido', u.apellido
            ),
            'email',
            now(),
            now()
        )
        ON CONFLICT (provider_id, provider) DO UPDATE
        SET identity_data = EXCLUDED.identity_data,
            updated_at = now();

        -- Sincronizar tabla pública de usuarios (public.usuarios)
        INSERT INTO public.usuarios (
            auth_user_id,
            rol_id,
            nombre,
            apellido,
            email,
            telefono,
            password_hash,
            activo
        ) VALUES (
            v_user_id,
            v_rol_id,
            u.nombre,
            u.apellido,
            u.email,
            u.telefono,
            v_enc_pass,
            true
        )
        ON CONFLICT (email) DO UPDATE
        SET auth_user_id = EXCLUDED.auth_user_id,
            rol_id = EXCLUDED.rol_id,
            nombre = EXCLUDED.nombre,
            apellido = EXCLUDED.apellido,
            telefono = EXCLUDED.telefono,
            password_hash = EXCLUDED.password_hash,
            activo = true;

        -- Configuración de Billetera Virtual (public.wallets)
        INSERT INTO public.wallets (usuario_id, saldo_actual, moneda)
        SELECT usr.id, u.saldo_inicial, 'CLP'
        FROM public.usuarios usr
        WHERE usr.email = u.email
        ON CONFLICT (usuario_id) DO UPDATE
        SET saldo_actual = GREATEST(wallets.saldo_actual, EXCLUDED.saldo_actual);

        -- Registrar movimiento inicial si se le asigna saldo positivo
        IF u.saldo_inicial > 0 THEN
            INSERT INTO public.movimientos_wallet (wallet_id, tipo, monto, descripcion)
            SELECT w.id, 'recarga', u.saldo_inicial, 'Carga inicial de saldo para pruebas de compra y pedidos'
            FROM public.wallets w
            JOIN public.usuarios usr ON usr.id = w.usuario_id
            WHERE usr.email = u.email
              AND NOT EXISTS (
                  SELECT 1 FROM public.movimientos_wallet mw WHERE mw.wallet_id = w.id
              );
        END IF;

        -- Asignación a Cafetería Central para Dueños y Empleados
        IF u.rol IN ('dueño', 'empleado') THEN
            INSERT INTO public.cafeteria_usuarios (
                usuario_id,
                cafeteria_id,
                cargo,
                gestiona_inventario,
                gestiona_productos,
                gestiona_precios,
                gestiona_empleados,
                gestiona_pedidos_kds,
                ve_metricas_dashboard
            )
            SELECT
                usr.id,
                v_cafeteria_central_id,
                CASE WHEN u.rol = 'dueño' THEN 'Administrador General' ELSE 'Encargado Cocina / Barista KDS' END,
                true,                 -- gestiona_inventario
                (u.rol = 'dueño'),    -- gestiona_productos
                (u.rol = 'dueño'),    -- gestiona_precios
                (u.rol = 'dueño'),    -- gestiona_empleados
                true,                 -- gestiona_pedidos_kds
                (u.rol = 'dueño')     -- ve_metricas_dashboard
            FROM public.usuarios usr
            WHERE usr.email = u.email
              AND NOT EXISTS (
                  SELECT 1 FROM public.cafeteria_usuarios cu
                  WHERE cu.usuario_id = usr.id AND cu.cafeteria_id = v_cafeteria_central_id
              );
        END IF;

        -- Asignación de configuración Telegram para el dueño
        IF u.email = 'dueno@coffeefaster.cl' THEN
            INSERT INTO public.configuracion_telegram_dueno (
                usuario_id,
                cafeteria_id,
                telegram_chat_id,
                notificaciones_activas
            )
            SELECT
                usr.id,
                v_cafeteria_central_id,
                123456789,
                true
            FROM public.usuarios usr
            WHERE usr.email = u.email
            ON CONFLICT (usuario_id) DO UPDATE
            SET cafeteria_id = EXCLUDED.cafeteria_id,
                notificaciones_activas = true;
        END IF;

    END LOOP;
END $$;
