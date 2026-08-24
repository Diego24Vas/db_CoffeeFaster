-- =============================================
-- Migración 0003: Datos de prueba
-- 3 cafeterías, 10 productos c/u, 5 usuarios
-- =============================================

-- ==========================================
-- UNIVERSIDADES
-- ==========================================
INSERT INTO "UNIVERSIDADES" ("id", "nombre", "rbd", "activa") VALUES
(1, 'INACAP Temuco',          '50123', true),
(2, 'Universidad Católica de Temuco (UCT)', '50456', true),
(3, 'Universidad de La Frontera (UFRO)',    '50789', true);

-- ==========================================
-- CAMPUS_SEDES
-- ==========================================
INSERT INTO "CAMPUS_SEDES" ("id", "universidad_id", "nombre_sede", "ciudad", "direccion", "latitud", "longitud") VALUES
(1, 1, 'Sede Temuco',       'Temuco', 'Av. Alemania 02, Temuco',          -38.73965200, -72.59784500),
(2, 2, 'Sede Temuco',       'Temuco', 'Av. San Martín 0450, Temuco',      -38.73512400, -72.60123400),
(3, 3, 'Campus Juan Pablo II', 'Temuco', 'Av. Francisco Salazar 0111, Temuco', -38.74123500, -72.58964700);

-- ==========================================
-- CAFETERÍAS (3 cafeterías universitarias)
-- ==========================================
INSERT INTO "CAFETERIAS" ("id", "campus_id", "nombre", "descripcion", "hora_apertura", "hora_cierre", "telefono", "imagen_url", "activa") VALUES
(1, 1, 'Café INACAP',           'Cafetería del campus INACAP Temuco, frente a la biblioteca', '07:30', '20:00', '+56945212345', 'https://images.unsplash.com/photo-1554118811-1e0d58224f24?w=400', true),
(2, 2, 'Café UCT',              'Cafetería de la Universidad Católica de Temuco',              '08:00', '19:00', '+56945267890', 'https://images.unsplash.com/photo-1559925393-8be0ec4767c8?w=400', true),
(3, 3, 'Café UFRO',             'Cafetería del Campus Juan Pablo II, UFRO',                    '07:00', '21:00', '+56945211122', 'https://images.unsplash.com/photo-1453614512568-c4024d13c247?w=400', true);

-- ==========================================
-- USUARIOS (2 clientes, 2 empleados, 1 dueño)
-- ==========================================
INSERT INTO "USUARIOS" ("id", "rol", "nombre", "apellido", "email", "telefono", "password_hash", "foto_url", "activo", "ultima_conexion") VALUES
(1, 'dueño',   'Carlos',  'Muñoz',     'carlos.munoz@coffee.com',    '+56911111111', '$2b$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ12', 'https://i.pravatar.cc/150?u=carlos',  true, '2026-08-23 08:00:00-04'),
(2, 'empleado','María',   'López',     'maria.lopez@coffee.com',     '+56922222222', '$2b$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ12', 'https://i.pravatar.cc/150?u=maria',   true, '2026-08-23 08:15:00-04'),
(3, 'empleado','Pedro',   'García',    'pedro.garcia@coffee.com',    '+56933333333', '$2b$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ12', 'https://i.pravatar.cc/150?u=pedro',   true, '2026-08-23 08:20:00-04'),
(4, 'cliente', 'Ana',     'Rodríguez', 'ana.rodriguez@alumno.cl',    '+56944444444', '$2b$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ12', 'https://i.pravatar.cc/150?u=ana',     true, '2026-08-23 09:00:00-04'),
(5, 'cliente', 'Jorge',   'Fernández', 'jorge.fernandez@alumno.cl',  '+56955555555', '$2b$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ12', 'https://i.pravatar.cc/150?u=jorge',   true, '2026-08-23 09:30:00-04');

-- ==========================================
-- CATEGORÍAS
-- ==========================================
INSERT INTO "CATEGORIAS" ("id", "nombre", "descripcion") VALUES
(1, 'Bebidas Calientes', 'Café, té, chocolate caliente'),
(2, 'Bebidas Frías',     'Frappé, jugos, smoothies'),
(3, 'Snacks',            'Bocadillos, pastelería, extras'),
(4, 'Comidas',           'Sándwiches, ensaladas, platos'),
(5, 'Postres',           'Tortas, galletas, muffins');

-- ==========================================
-- CAFETERÍA_USUARIOS (relación dueño/empleado ↔ cafetería)
-- ==========================================
INSERT INTO "CAFETERIA_USUARIOS" ("id", "usuario_id", "cafeteria_id", "cargo", "gestiona_inventario", "gestiona_productos", "gestiona_precios", "gestiona_pedidos_kds") VALUES
(1, 1, 1, 'dueño',    true, true, true, true),
(2, 2, 1, 'empleado', true, false, false, true),
(3, 3, 2, 'empleado', true, false, false, true);

-- ==========================================
-- PRODUCTOS — Coffee&Go INACAP (cafetería 1)
-- ==========================================
INSERT INTO "PRODUCTOS" ("id", "cafeteria_id", "categoria_id", "nombre", "descripcion", "precio", "imagen_url", "stock", "stock_minimo", "activo") VALUES
-- Bebidas Calientes (cat 1)
(1,  1, 1, 'Café Americano',       'Café filtrado negro, 250ml',                   1500.00, 'https://images.unsplash.com/photo-1541167760496-1628856ab772?w=300', 50, 10, true),
(2,  1, 1, 'Cappuccino',           'Espresso con espuma de leche, 300ml',          2200.00, 'https://images.unsplash.com/photo-1572442388796-11668a67e53d?w=300', 40, 10, true),
(3,  1, 1, 'Latte',                'Café con leche cremosa, 350ml',                2400.00, 'https://images.unsplash.com/photo-1461023058943-07fcbe16d735?w=300', 40, 10, true),
-- Bebidas Frías (cat 2)
(4,  1, 2, 'Frappé de Café',       'Café helado batido con crema, 400ml',         2800.00, 'https://images.unsplash.com/photo-1461023058943-07fcbe16d735?w=300', 30, 8,  true),
(5,  1, 2, 'Smoothie de Frutos',   'Frutos rojos batidos con yogur, 400ml',       3000.00, 'https://images.unsplash.com/photo-1553530666-ba11a7da3888?w=300', 25, 8,  true),
-- Snacks (cat 3)
(6,  1, 3, 'Croissant de Jamón',   'Croissant hojaldrado relleno de jamón',       1800.00, 'https://images.unsplash.com/photo-1555507036-ab1f4038024a?w=300', 20, 5,  true),
(7,  1, 3, 'Muffin de Arándano',   'Muffin esponjoso con arándanos frescos',      1500.00, 'https://images.unsplash.com/photo-1607920591413-4ec007e70023?w=300', 25, 5,  true),
-- Comidas (cat 4)
(8,  1, 4, 'Sándwich Club',        'Triple sándwich de pollo, tocino y palta',    3500.00, 'https://images.unsplash.com/photo-1528735602780-2552fd46c7af?w=300', 15, 5,  true),
(9,  1, 4, 'Wrap de Pollo',        'Tortilla integral con pollo a la plancha',    3200.00, 'https://images.unsplash.com/photo-1626700051175-6818013e1d4f?w=300', 15, 5,  true),
-- Postres (cat 5)
(10, 1, 5, 'Torta de Chocolate',   'Porción de torta húmeda de chocolate 70%',    2500.00, 'https://images.unsplash.com/photo-1578985545062-69928b1d9587?w=300', 10, 3,  true);

-- ==========================================
-- PRODUCTOS — El Rincón del Café UNAB (cafetería 2)
-- ==========================================
INSERT INTO "PRODUCTOS" ("id", "cafeteria_id", "categoria_id", "nombre", "descripcion", "precio", "imagen_url", "stock", "stock_minimo", "activo") VALUES
-- Bebidas Calientes (cat 1)
(11, 2, 1, 'Espresso Doble',       'Dshot de espresso intenso, 60ml',             1800.00, 'https://images.unsplash.com/photo-1510707577719-ae7c14805e3a?w=300', 60, 10, true),
(12, 2, 1, 'Chocolate Caliente',   'Chocolate con leche y malvaviscos, 300ml',    2500.00, 'https://images.unsplash.com/photo-1542990253-0d0f5be5f0ed?w=300', 35, 8,  true),
(13, 2, 1, 'Té Chai Latte',        'Té chai especiado con leche, 300ml',          2300.00, 'https://images.unsplash.com/photo-1564890369478-c89ca6d9cde9?w=300', 30, 8,  true),
-- Bebidas Frías (cat 2)
(14, 2, 2, 'Iced Matcha Latte',    'Matcha con leche fría y hielo, 400ml',        3200.00, 'https://images.unsplash.com/photo-1536256263959-770b48d82b0a?w=300', 25, 8,  true),
(15, 2, 2, 'Limonada con Hierbabuena', 'Limonada fresca con hierbabuena, 500ml', 2000.00, 'https://images.unsplash.com/photo-1621263764928-df1444c5e859?w=300', 30, 8,  true),
-- Snacks (cat 3)
(16, 2, 3, 'Baguette de Queso',    'Baguette francés con queso gratinado',       2000.00, 'https://images.unsplash.com/photo-1549931319-a545dcf3bc73?w=300', 20, 5,  true),
(17, 2, 3, 'Brownie de Nuez',      'Brownie denso con nueces tostadas',           1800.00, 'https://images.unsplash.com/photo-1606313564200-e75d5e30476c?w=300', 20, 5,  true),
-- Comidas (cat 4)
(18, 2, 4, 'Ensalada Caesar',      'Lechuga, pollo, crutones y aderezo Caesar',  3800.00, 'https://images.unsplash.com/photo-1550304943-4f24f54ddde9?w=300', 12, 5,  true),
(19, 2, 4, 'Panini de Vegetales',  'Panini integral con vegetales asados',       3000.00, 'https://images.unsplash.com/photo-1528735602780-2552fd46c7af?w=300', 15, 5,  true),
-- Postres (cat 5)
(20, 2, 5, 'Cheesecake de Frutos', 'Porción de cheesecake con salsa de frutos',  2800.00, 'https://images.unsplash.com/photo-1533134242443-d4fd215305ad?w=300', 8,  3,  true);

-- ==========================================
-- PRODUCTOS — Café Campus USS (cafetería 3)
-- ==========================================
INSERT INTO "PRODUCTOS" ("id", "cafeteria_id", "categoria_id", "nombre", "descripcion", "precio", "imagen_url", "stock", "stock_minimo", "activo") VALUES
-- Bebidas Calientes (cat 1)
(21, 3, 1, 'Cold Brew',             'Café frío de extracción lenta, 350ml',        2500.00, 'https://images.unsplash.com/photo-1461023058943-07fcbe16d735?w=300', 35, 10, true),
(22, 3, 1, 'Affogato',             'Helado de vainilla con shot de espresso',    2800.00, 'https://images.unsplash.com/photo-1579992357154-faf4bde95b3d?w=300', 20, 5,  true),
(23, 3, 1, 'Cortado',              'Espresso con un toque de leche, 150ml',       1600.00, 'https://images.unsplash.com/photo-1514432324607-a09d9b4aefda?w=300', 50, 10, true),
-- Bebidas Frías (cat 2)
(24, 3, 2, 'Té Helado de Durazno', 'Té helado sabor durazno, 500ml',             2200.00, 'https://images.unsplash.com/photo-1556679343-c7306c1976bc?w=300', 30, 8,  true),
(25, 3, 2, 'Jugo Verde Detox',     'Espinaca, manzana, apio y jengibre, 400ml',  3000.00, 'https://images.unsplash.com/photo-1610970881699-44a5587cabec?w=300', 20, 5,  true),
-- Snacks (cat 3)
(26, 3, 3, 'Empanada de Pino',     'Empanada al horno rellena de pino casero',   2000.00, 'https://images.unsplash.com/photo-1604908176997-125f25cc6f3d?w=300', 25, 8,  true),
(27, 3, 3, 'Sopaipilla con Mostaza','Sopaipilla frita con mostaza casera',       800.00,  'https://images.unsplash.com/photo-1626198226928-2f3341f48768?w=300', 30, 10, true),
-- Comidas (cat 4)
(28, 3, 4, 'Completo Italiano',    'Hot dog completo con palta, tomate y mayo',  3500.00, 'https://images.unsplash.com/photo-1612392062121-5408cbf512d7?w=300', 15, 5,  true),
(29, 3, 4, 'Bowl de Quinoa',       'Quinoa, vegetales grillados y aderezo tahini',4200.00,'https://images.unsplash.com/photo-1512621776951-a57141f2eefd?w=300', 10, 3,  true),
-- Postres (cat 5)
(30, 3, 5, 'Tres Leches',          'Porción de torta tres leches cremosa',       2600.00, 'https://images.unsplash.com/photo-1571115177098-24ec42ed204d?w=300', 10, 3,  true);
