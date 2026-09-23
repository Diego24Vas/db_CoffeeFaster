-- ============================================================================
-- MIGRACIÓN 0006: DATOS INICIALES - CAFETERÍA, USUARIOS (DUEÑO/EMPLEADO) E INVENTARIO
-- ============================================================================
-- Propósito: Cargar los datos maestros iniciales de la cafetería, cuentas de acceso
-- para Dueño y Empleado (con credenciales Supabase Auth listas para pruebas) y el
-- catálogo base de productos e inventario para sincronizar con todos los integrantes.
--
-- Credenciales creadas:
--   • Dueño:    dueno@coffeefaster.cl    / 123456  (Acceso total, Dashboard, Productos, Inventario)
--   • Empleado: empleado@coffeefaster.cl / 123456  (Acceso KDS y Comandas)
--   • Estudiante: estudiante@coffeefaster.cl / 123456 (Acceso App Móvil)
-- ============================================================================

-- ==========================================
-- 1. UNIVERSIDADES Y CAMPUS SEDES
-- ==========================================

INSERT INTO universidades (id, nombre, rbd, activa) VALUES
    (1, 'Universidad Tecnológica de Chile', 'RBD-10293', true),
    (2, 'Universidad Metropolitana', 'RBD-88471', true)
ON CONFLICT (id) DO UPDATE SET
    nombre = EXCLUDED.nombre,
    rbd = EXCLUDED.rbd,
    activa = EXCLUDED.activa;

INSERT INTO campus_sedes (id, universidad_id, nombre_sede, ciudad, direccion, latitud, longitud, activa) VALUES
    (1, 1, 'Campus Central San Joaquín', 'Santiago', 'Av. Vicuña Mackenna 4860', '-33.4998', '-70.6148', true),
    (2, 1, 'Campus Providencia', 'Santiago', 'Av. Antonio Varas 666', '-33.4350', '-70.6150', true),
    (3, 2, 'Campus El Llano Subercaseaux', 'San Miguel', 'Gran Avenida 4100', '-33.4900', '-70.6500', true)
ON CONFLICT (id) DO UPDATE SET
    nombre_sede = EXCLUDED.nombre_sede,
    ciudad = EXCLUDED.ciudad,
    direccion = EXCLUDED.direccion;

-- ==========================================
-- 2. CAFETERÍAS
-- ==========================================

INSERT INTO cafeterias (id, campus_id, nombre, descripcion, hora_apertura, hora_cierre, telefono, imagen_url, activa) VALUES
    (1, 1, 'Cafetería Central', 'Punto principal de atención, preparación y retiro de pedidos', '08:00:00', '19:00:00', '+5622998877', 'https://images.unsplash.com/photo-1554118811-1e0d58224f24', true),
    (2, 1, 'Cafetería Ingeniería', 'Ubicada en el hall del edificio de ingeniería para atención rápida', '08:30:00', '18:00:00', '+5622998878', 'https://images.unsplash.com/photo-1501339847302-ac426a4a7cbb', true)
ON CONFLICT (id) DO UPDATE SET
    nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion,
    hora_apertura = EXCLUDED.hora_apertura,
    hora_cierre = EXCLUDED.hora_cierre,
    telefono = EXCLUDED.telefono;

-- ==========================================
-- 3. CATEGORÍAS DE PRODUCTOS
-- ==========================================

INSERT INTO categorias (id, nombre, descripcion) VALUES
    (1, 'CAFÉ', 'Granos de especialidad y preparaciones calientes a base de espresso'),
    (2, 'LÁCTEOS', 'Leches enteras, descremadas, vegetales y derivados'),
    (3, 'PANADERÍA', 'Croissants, panes y preparaciones saladas horneadas del día'),
    (4, 'REPOSTERÍA', 'Medialunas, muffins, galletas y dulces artesanales'),
    (5, 'TÉ', 'Té negro, verde, infusiones herbales y Chai'),
    (6, 'INSUMOS', 'Azúcar, jarabes saborizados, cacao y complementos de barra'),
    (7, 'DESECHABLES', 'Vasos térmicos, tapas ecológicas, servilletas y revolvedores'),
    (8, 'BEBIDAS FRÍAS', 'Jugos naturales prensados en frío y aguas minerales')
ON CONFLICT (id) DO UPDATE SET
    nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion;

-- ==========================================
-- 4. MÉTODOS DE PAGO
-- ==========================================

INSERT INTO metodos_pago (id, codigo, nombre, tipo, requiere_referencia, activo) VALUES
    (1, 'WEBPAY', 'Webpay Plus / Tarjeta Débito-Crédito', 'ONLINE', true, true),
    (2, 'SALDO_APP', 'Saldo Cuenta CoffeeFaster', 'BILLETERA', false, true),
    (3, 'EFECTIVO', 'Efectivo en Caja', 'PRESENCIAL', false, true),
    (4, 'TRANSFERENCIA', 'Transferencia Bancaria Directa', 'ONLINE', true, true)
ON CONFLICT (id) DO UPDATE SET
    nombre = EXCLUDED.nombre,
    activo = EXCLUDED.activo;

-- ==========================================
-- 4.1 ROLES DE USUARIO
-- ==========================================

INSERT INTO roles (id, nombre, descripcion, activo) VALUES
    (1, 'estudiante', 'Consulta menús, realiza pedidos, paga y retira con QR via Android', true),
    (2, 'empleado', 'Opera el KDS en Windows para preparar y validar retiros QR', true),
    (3, 'dueño', 'Administra productos, stock, personal, métricas y recibe alertas de IA', true)
ON CONFLICT (id) DO UPDATE SET
    nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion,
    activo = EXCLUDED.activo;

-- ==========================================
-- 5. USUARIOS EN SUPABASE AUTH Y TABLA USUARIOS
-- ==========================================
-- Clave para todos los usuarios de prueba: 123456
-- Hash bcrypt correspondiente: $2a$10$5h2J.sQnkORv3Gq7jFG0lexy2YEuVO/cYKzxIGB7.8xc..hDUr37u

DO $$
DECLARE
    dueno_uuid uuid := 'fb364ac2-7bfe-4b8b-b3f7-3521f19ac0f6';
    empleado_uuid uuid := 'e2b1a3c4-5d6e-7f8a-9b0c-1d2e3f4a5b6c';
    estudiante_uuid uuid := 'c3d4e5f6-a7b8-4c9d-0e1f-2a3b4c5d6e7f';
    rol_dueno_id bigint;
    rol_empleado_id bigint;
    rol_estudiante_id bigint;
    dueno_user_id bigint;
    empleado_user_id bigint;
    estudiante_user_id bigint;
BEGIN
    -- Obtener IDs de roles
    SELECT id INTO rol_dueno_id FROM roles WHERE LOWER(nombre) = 'dueño' LIMIT 1;
    SELECT id INTO rol_empleado_id FROM roles WHERE LOWER(nombre) = 'empleado' LIMIT 1;
    SELECT id INTO rol_estudiante_id FROM roles WHERE LOWER(nombre) = 'estudiante' LIMIT 1;

    -- ----------------------------------------------------
    -- 5.1 DUEÑO (Carlos Dueño)
    -- ----------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'dueno@coffeefaster.cl') THEN
        INSERT INTO auth.users (
            id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user,
            confirmation_token, recovery_token, email_change_token_new, email_change,
            phone_change, phone_change_token, reauthentication_token
        ) VALUES (
            dueno_uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'dueno@coffeefaster.cl', '$2a$10$5h2J.sQnkORv3Gq7jFG0lexy2YEuVO/cYKzxIGB7.8xc..hDUr37u', now(),
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            '{"rol": "dueño", "nombre": "Carlos", "apellido": "Dueño", "email_verified": true}'::jsonb,
            now(), now(), false, '', '', '', '', '', '', ''
        );

        INSERT INTO auth.identities (
            id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
        ) VALUES (
            gen_random_uuid(), dueno_uuid, dueno_uuid::text,
            jsonb_build_object('sub', dueno_uuid::text, 'email', 'dueno@coffeefaster.cl', 'email_verified', true, 'phone_verified', false),
            'email', now(), now(), now()
        );
    ELSE
        UPDATE auth.users
        SET encrypted_password = '$2a$10$5h2J.sQnkORv3Gq7jFG0lexy2YEuVO/cYKzxIGB7.8xc..hDUr37u',
            email_confirmed_at = COALESCE(email_confirmed_at, now()),
            raw_user_meta_data = '{"rol": "dueño", "nombre": "Carlos", "apellido": "Dueño", "email_verified": true}'::jsonb,
            phone = NULL
        WHERE email = 'dueno@coffeefaster.cl';
    END IF;

    -- ----------------------------------------------------
    -- 5.2 EMPLEADO (Ignacio Barista)
    -- ----------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'empleado@coffeefaster.cl') THEN
        INSERT INTO auth.users (
            id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user,
            confirmation_token, recovery_token, email_change_token_new, email_change,
            phone_change, phone_change_token, reauthentication_token
        ) VALUES (
            empleado_uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'empleado@coffeefaster.cl', '$2a$10$5h2J.sQnkORv3Gq7jFG0lexy2YEuVO/cYKzxIGB7.8xc..hDUr37u', now(),
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            '{"rol": "empleado", "nombre": "Ignacio", "apellido": "Barista", "email_verified": true}'::jsonb,
            now(), now(), false, '', '', '', '', '', '', ''
        );

        INSERT INTO auth.identities (
            id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
        ) VALUES (
            gen_random_uuid(), empleado_uuid, empleado_uuid::text,
            jsonb_build_object('sub', empleado_uuid::text, 'email', 'empleado@coffeefaster.cl', 'email_verified', true, 'phone_verified', false),
            'email', now(), now(), now()
        );
    ELSE
        UPDATE auth.users
        SET encrypted_password = '$2a$10$5h2J.sQnkORv3Gq7jFG0lexy2YEuVO/cYKzxIGB7.8xc..hDUr37u',
            email_confirmed_at = COALESCE(email_confirmed_at, now()),
            raw_user_meta_data = '{"rol": "empleado", "nombre": "Ignacio", "apellido": "Barista", "email_verified": true}'::jsonb,
            phone = NULL
        WHERE email = 'empleado@coffeefaster.cl';
    END IF;

    -- ----------------------------------------------------
    -- 5.3 ESTUDIANTE DE PRUEBA (Camila Silva)
    -- ----------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'estudiante@coffeefaster.cl') THEN
        INSERT INTO auth.users (
            id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user,
            confirmation_token, recovery_token, email_change_token_new, email_change,
            phone_change, phone_change_token, reauthentication_token
        ) VALUES (
            estudiante_uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'estudiante@coffeefaster.cl', '$2a$10$5h2J.sQnkORv3Gq7jFG0lexy2YEuVO/cYKzxIGB7.8xc..hDUr37u', now(),
            '{"provider": "email", "providers": ["email"]}'::jsonb,
            '{"rol": "estudiante", "nombre": "Camila", "apellido": "Silva", "email_verified": true}'::jsonb,
            now(), now(), false, '', '', '', '', '', '', ''
        );

        INSERT INTO auth.identities (
            id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
        ) VALUES (
            gen_random_uuid(), estudiante_uuid, estudiante_uuid::text,
            jsonb_build_object('sub', estudiante_uuid::text, 'email', 'estudiante@coffeefaster.cl', 'email_verified', true, 'phone_verified', false),
            'email', now(), now(), now()
        );
    ELSE
        UPDATE auth.users
        SET encrypted_password = '$2a$10$5h2J.sQnkORv3Gq7jFG0lexy2YEuVO/cYKzxIGB7.8xc..hDUr37u',
            email_confirmed_at = COALESCE(email_confirmed_at, now()),
            raw_user_meta_data = '{"rol": "estudiante", "nombre": "Camila", "apellido": "Silva", "email_verified": true}'::jsonb,
            phone = NULL
        WHERE email = 'estudiante@coffeefaster.cl';
    END IF;

    -- ----------------------------------------------------
    -- 5.4 SINCRONIZAR TABLA USUARIOS (Perfil en base de datos)
    -- ----------------------------------------------------
    -- Dueño
    IF NOT EXISTS (SELECT 1 FROM usuarios WHERE email = 'dueno@coffeefaster.cl') THEN
        INSERT INTO usuarios (rol_id, nombre, apellido, email, telefono, password_hash, foto_url, activo, auth_user_id)
        VALUES (
            rol_dueno_id, 'Carlos', 'Dueño', 'dueno@coffeefaster.cl', '+56912345678', '123456',
            'https://images.unsplash.com/photo-1472099645785-5658abf4ff4e', true, dueno_uuid
        ) RETURNING id INTO dueno_user_id;
    ELSE
        UPDATE usuarios
        SET rol_id = rol_dueno_id,
            nombre = 'Carlos',
            apellido = 'Dueño',
            auth_user_id = dueno_uuid,
            activo = true
        WHERE email = 'dueno@coffeefaster.cl'
        RETURNING id INTO dueno_user_id;
    END IF;

    -- Empleado
    IF NOT EXISTS (SELECT 1 FROM usuarios WHERE email = 'empleado@coffeefaster.cl') THEN
        INSERT INTO usuarios (rol_id, nombre, apellido, email, telefono, password_hash, foto_url, activo, auth_user_id)
        VALUES (
            rol_empleado_id, 'Ignacio', 'Barista', 'empleado@coffeefaster.cl', '+56987654321', '123456',
            'https://images.unsplash.com/photo-1534528741775-53994a69daeb', true, empleado_uuid
        ) RETURNING id INTO empleado_user_id;
    ELSE
        UPDATE usuarios
        SET rol_id = rol_empleado_id,
            nombre = 'Ignacio',
            apellido = 'Barista',
            auth_user_id = empleado_uuid,
            activo = true
        WHERE email = 'empleado@coffeefaster.cl'
        RETURNING id INTO empleado_user_id;
    END IF;

    -- Estudiante
    IF NOT EXISTS (SELECT 1 FROM usuarios WHERE email = 'estudiante@coffeefaster.cl') THEN
        INSERT INTO usuarios (rol_id, nombre, apellido, email, telefono, password_hash, foto_url, activo, auth_user_id)
        VALUES (
            rol_estudiante_id, 'Camila', 'Silva', 'estudiante@coffeefaster.cl', '+56911223344', '123456',
            'https://images.unsplash.com/photo-1494790108377-be9c29b29330', true, estudiante_uuid
        ) RETURNING id INTO estudiante_user_id;
    ELSE
        UPDATE usuarios
        SET rol_id = rol_estudiante_id,
            nombre = 'Camila',
            apellido = 'Silva',
            auth_user_id = estudiante_uuid,
            activo = true
        WHERE email = 'estudiante@coffeefaster.cl'
        RETURNING id INTO estudiante_user_id;
    END IF;

    -- ----------------------------------------------------
    -- 5.5 ASIGNAR USUARIOS A LA CAFETERÍA (cafeteria_usuarios)
    -- ----------------------------------------------------
    -- Carlos Dueño (todos los permisos administrativos)
    IF NOT EXISTS (SELECT 1 FROM cafeteria_usuarios WHERE usuario_id = dueno_user_id AND cafeteria_id = 1) THEN
        INSERT INTO cafeteria_usuarios (
            usuario_id, cafeteria_id, cargo,
            gestiona_inventario, gestiona_productos, gestiona_precios,
            gestiona_empleados, gestiona_pedidos_kds, ve_metricas_dashboard
        ) VALUES (
            dueno_user_id, 1, 'Dueño / Administrador General',
            true, true, true, true, true, true
        );
    ELSE
        UPDATE cafeteria_usuarios SET
            cargo = 'Dueño / Administrador General',
            gestiona_inventario = true,
            gestiona_productos = true,
            gestiona_precios = true,
            gestiona_empleados = true,
            gestiona_pedidos_kds = true,
            ve_metricas_dashboard = true
        WHERE usuario_id = dueno_user_id AND cafeteria_id = 1;
    END IF;

    -- Ignacio Barista (operador de KDS e inventario de cocina)
    IF NOT EXISTS (SELECT 1 FROM cafeteria_usuarios WHERE usuario_id = empleado_user_id AND cafeteria_id = 1) THEN
        INSERT INTO cafeteria_usuarios (
            usuario_id, cafeteria_id, cargo,
            gestiona_inventario, gestiona_productos, gestiona_precios,
            gestiona_empleados, gestiona_pedidos_kds, ve_metricas_dashboard
        ) VALUES (
            empleado_user_id, 1, 'Jefe de Barra / KDS',
            true, false, false, false, true, false
        );
    ELSE
        UPDATE cafeteria_usuarios SET
            cargo = 'Jefe de Barra / KDS',
            gestiona_inventario = true,
            gestiona_pedidos_kds = true
        WHERE usuario_id = empleado_user_id AND cafeteria_id = 1;
    END IF;
END $$;

-- ==========================================
-- 6. INVENTARIO Y CATÁLOGO DE PRODUCTOS
-- ==========================================

INSERT INTO productos (id, cafeteria_id, categoria_id, nombre, descripcion, precio, imagen_url, stock, stock_minimo, activo) VALUES
    (1,  1, 1, 'Café Americano', 'Espresso doble rebajado con agua caliente a temperatura ideal', 1800.00, 'https://images.unsplash.com/photo-1514432324607-a09d9b4aefdd', 45, 15, true),
    (2,  1, 1, 'Capuchino Italiano', 'Espresso intenso, leche vaporizada y suave espuma cremosa', 2400.00, 'https://images.unsplash.com/photo-1572442388796-11668ba67e53', 35, 12, true),
    (3,  1, 1, 'Latte Vainilla', 'Café espresso con leche texturizada y extracto natural de vainilla', 2600.00, 'https://images.unsplash.com/photo-1561882468-9110e03e0f78', 30, 10, true),
    (4,  1, 1, 'Espresso Doble', 'Extracción pura de café tostado medio con notas a avellana y chocolate', 2000.00, 'https://images.unsplash.com/photo-1510591509098-f4fdc6d0ff04', 40, 10, true),
    (5,  1, 5, 'Té Chai Latte', 'Té negro especiado con cardamomo, canela, clavo de olor y leche', 2200.00, 'https://images.unsplash.com/photo-1576092768241-dec231879fc3', 35, 10, true),
    (6,  1, 5, 'Té Verde Matcha', 'Té verde ceremonial japonés rico en antioxidantes batido en leche', 2500.00, 'https://images.unsplash.com/photo-1536256263959-770b48d82b0a', 20, 8, true),
    (7,  1, 3, 'Croissant de Mantequilla', 'Hojaldre francés crujiente horneado diariamente con mantequilla pura', 2000.00, 'https://images.unsplash.com/photo-1555507036-ab1f4038808a', 25, 10, true),
    (8,  1, 3, 'Sándwich Ave Mayo', 'Pechuga desmenuzada, mayonesa artesanal y ciboulette en pan ciabatta', 2800.00, 'https://images.unsplash.com/photo-1528735602780-2552fd46c7af', 20, 8, true),
    (9,  1, 4, 'Medialuna Artesanal', 'Medialuna dulce de masa suave pincelada con almíbar tibio', 1200.00, 'https://images.unsplash.com/photo-1509440159596-0249088772ff', 15, 10, true),
    (10, 1, 4, 'Muffin de Arándanos', 'Bizcocho húmedo esponjoso con arándanos frescos enteros', 1800.00, 'https://images.unsplash.com/photo-1607958996333-41aef7caefaa', 25, 10, true),
    (11, 1, 4, 'Galleta Choco Chips', 'Galleta crocante con chips de chocolate belga semi amargo', 1600.00, 'https://images.unsplash.com/photo-1499636136210-6f4ee915583e', 30, 10, true),
    (12, 1, 2, 'Leche Entera 1L', 'Insumo de barra: Leche líquida entera pasteurizada', 1400.00, '', 15, 8, true),
    (13, 1, 2, 'Bebida de Almendras 1L', 'Insumo de barra: Leche vegetal de almendras sin azúcar añadida', 2200.00, '', 10, 5, true),
    (14, 1, 6, 'Chocolate en Polvo 1kg', 'Insumo para moccaccino y chocolate caliente artesanal', 4500.00, '', 8, 4, true),
    (15, 1, 6, 'Azúcar Rubia 1kg', 'Insumo complementario de barra', 1200.00, '', 25, 10, true),
    (16, 1, 7, 'Vaso Térmico 12 oz (Pack 50)', 'Vaso de polipapel biodegradable para bebidas calientes medianas', 4500.00, '', 12, 5, true),
    (17, 1, 8, 'Jugo Naranja Natural 350ml', 'Jugo recién exprimido 100% fruta natural sin preservantes', 2500.00, 'https://images.unsplash.com/photo-1613478223719-2ab802602423', 18, 6, true)
ON CONFLICT (id) DO UPDATE SET
    cafeteria_id = EXCLUDED.cafeteria_id,
    categoria_id = EXCLUDED.categoria_id,
    nombre = EXCLUDED.nombre,
    descripcion = EXCLUDED.descripcion,
    precio = EXCLUDED.precio,
    stock = EXCLUDED.stock,
    stock_minimo = EXCLUDED.stock_minimo,
    activo = EXCLUDED.activo;

-- ==========================================
-- 7. MOVIMIENTOS DE INVENTARIO INICIALES
-- ==========================================

INSERT INTO movimientos_inventario (id, producto_id, usuario_id, tipo, cantidad, motivo) VALUES
    (1, 1, 1, 'ENTRADA', 45, 'Inventario inicial de apertura de cafetería'),
    (2, 2, 1, 'ENTRADA', 35, 'Inventario inicial de apertura de cafetería'),
    (3, 7, 1, 'ENTRADA', 25, 'Inventario inicial de apertura de cafetería'),
    (4, 8, 1, 'ENTRADA', 20, 'Inventario inicial de apertura de cafetería'),
    (5, 12, 1, 'ENTRADA', 15, 'Recepción de stock lácteos proveedor')
ON CONFLICT (id) DO NOTHING;

-- ==========================================
-- 8. SINCRONIZACIÓN DE SECUENCIAS
-- ==========================================
-- Evita errores de clave duplicada al insertar nuevos registros posteriormente

SELECT setval('roles_id_seq', COALESCE((SELECT MAX(id) FROM roles), 1));
SELECT setval('universidades_id_seq', COALESCE((SELECT MAX(id) FROM universidades), 1));
SELECT setval('campus_sedes_id_seq', COALESCE((SELECT MAX(id) FROM campus_sedes), 1));
SELECT setval('cafeterias_id_seq', COALESCE((SELECT MAX(id) FROM cafeterias), 1));
SELECT setval('categorias_id_seq', COALESCE((SELECT MAX(id) FROM categorias), 1));
SELECT setval('metodos_pago_id_seq', COALESCE((SELECT MAX(id) FROM metodos_pago), 1));
SELECT setval('usuarios_id_seq', COALESCE((SELECT MAX(id) FROM usuarios), 1));
SELECT setval('cafeteria_usuarios_id_seq', COALESCE((SELECT MAX(id) FROM cafeteria_usuarios), 1));
SELECT setval('productos_id_seq', COALESCE((SELECT MAX(id) FROM productos), 1));
SELECT setval('movimientos_inventario_id_seq', COALESCE((SELECT MAX(id) FROM movimientos_inventario), 1));
