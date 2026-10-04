-- ==========================================
-- MIGRACIÓN 0001: Creación de tablas base
-- Todas las columnas temporales utilizan TIMESTAMPTZ para garantizar
-- coherencia de huso horario UTC universal en toda la plataforma.
-- ==========================================

-- ==========================================
-- 1. TABLAS PRINCIPALES (Sin dependencias)
-- ==========================================

CREATE TABLE universidades (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(255) NOT NULL,
    rbd VARCHAR(100),
    activa BOOLEAN DEFAULT true,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    actualizado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE roles (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(100) UNIQUE NOT NULL,
    descripcion TEXT,
    activo BOOLEAN DEFAULT true
);

CREATE TABLE categorias (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    descripcion TEXT
);

CREATE TABLE metodos_pago (
    id BIGSERIAL PRIMARY KEY,
    codigo VARCHAR(50) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    tipo VARCHAR(50),
    requiere_referencia BOOLEAN DEFAULT false,
    activo BOOLEAN DEFAULT true,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 2. TABLAS DE PRIMER NIVEL (Dependen de las tablas principales)
-- ==========================================

CREATE TABLE campus_sedes (
    id BIGSERIAL PRIMARY KEY,
    universidad_id BIGINT REFERENCES universidades(id) ON DELETE CASCADE,
    nombre_sede VARCHAR(255) NOT NULL,
    ciudad VARCHAR(100),
    direccion VARCHAR(255),
    latitud VARCHAR(50),
    longitud VARCHAR(50),
    activa BOOLEAN DEFAULT true
);

CREATE TABLE usuarios (
    id BIGSERIAL PRIMARY KEY,
    rol_id BIGINT REFERENCES roles(id) ON DELETE SET NULL,
    nombre VARCHAR(100) NOT NULL,
    apellido VARCHAR(100),
    email VARCHAR(255) UNIQUE NOT NULL,
    telefono VARCHAR(50),
    password_hash VARCHAR(255) NOT NULL,
    foto_url TEXT,
    activo BOOLEAN DEFAULT true,
    ultima_conexion TIMESTAMPTZ,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    actualizado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- ==========================================
-- 3. TABLAS DE SEGUNDO NIVEL
-- ==========================================

CREATE TABLE cafeterias (
    id BIGSERIAL PRIMARY KEY,
    campus_id BIGINT REFERENCES campus_sedes(id) ON DELETE CASCADE,
    nombre VARCHAR(255) NOT NULL,
    descripcion TEXT,
    hora_apertura TIME,
    hora_cierre TIME,
    telefono VARCHAR(50),
    imagen_url TEXT,
    activa BOOLEAN DEFAULT true,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    actualizado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE dispositivos (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE CASCADE,
    token_fcm VARCHAR(255) UNIQUE NOT NULL,
    plataforma VARCHAR(50),
    activo BOOLEAN DEFAULT true,
    ultima_conexion TIMESTAMPTZ,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 4. TABLAS DE TERCER NIVEL
-- ==========================================

CREATE TABLE productos (
    id BIGSERIAL PRIMARY KEY,
    cafeteria_id BIGINT REFERENCES cafeterias(id) ON DELETE CASCADE,
    categoria_id BIGINT REFERENCES categorias(id) ON DELETE SET NULL,
    nombre VARCHAR(255) NOT NULL,
    descripcion TEXT,
    precio DECIMAL(10,2) NOT NULL,
    imagen_url TEXT,
    stock INTEGER DEFAULT 0,
    stock_minimo INTEGER DEFAULT 0,
    activo BOOLEAN DEFAULT true,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    actualizado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    eliminado_en TIMESTAMPTZ
);

CREATE TABLE cafeteria_usuarios (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE CASCADE,
    cafeteria_id BIGINT REFERENCES cafeterias(id) ON DELETE CASCADE,
    cargo VARCHAR(100),
    gestiona_inventario BOOLEAN DEFAULT false,
    gestiona_productos BOOLEAN DEFAULT false,
    gestiona_precios BOOLEAN DEFAULT false,
    gestiona_empleados BOOLEAN DEFAULT false,
    gestiona_pedidos_kds BOOLEAN DEFAULT false,
    ve_metricas_dashboard BOOLEAN DEFAULT false,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE configuracion_telegram_dueno (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT UNIQUE NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    cafeteria_id BIGINT NOT NULL REFERENCES cafeterias(id) ON DELETE CASCADE,
    telegram_chat_id BIGINT UNIQUE NOT NULL,
    notificaciones_activas BOOLEAN DEFAULT true,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    actualizado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Billetera virtual por usuario (FR-17)
CREATE TABLE wallets (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT UNIQUE NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    saldo_actual INTEGER NOT NULL DEFAULT 0 CHECK (saldo_actual >= 0),
    moneda VARCHAR(10) NOT NULL DEFAULT 'CLP',
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    actualizado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE pedidos (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE SET NULL,
    cafeteria_id BIGINT REFERENCES cafeterias(id) ON DELETE CASCADE,
    codigo_pedido VARCHAR(100),
    codigo_retiro_diario VARCHAR(50),
    estado VARCHAR(50) NOT NULL,
    pago_estado VARCHAR(50),
    metodo_pago VARCHAR(50),
    franja_retiro VARCHAR(100),
    nota TEXT,
    total DECIMAL(10,2) NOT NULL,
    qr_token VARCHAR(255) UNIQUE,
    qr_usado BOOLEAN DEFAULT false,
    qr_expira_en TIMESTAMPTZ,
    tiempo_estimado_min INTEGER,
    tiempo_real_min INTEGER,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    inicio_preparacion_en TIMESTAMPTZ,
    listo_en TIMESTAMPTZ,
    entregado_en TIMESTAMPTZ,
    cancelado_en TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pedidos_codigo_pedido ON pedidos(codigo_pedido) WHERE codigo_pedido IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_pedidos_codigo_retiro ON pedidos(codigo_retiro_diario) WHERE codigo_retiro_diario IS NOT NULL;

-- ==========================================
-- 5. TABLAS DE CUARTO NIVEL (Dependientes de tercer nivel)
-- ==========================================

-- Libro de movimientos de Wallet
CREATE TABLE movimientos_wallet (
    id BIGSERIAL PRIMARY KEY,
    wallet_id BIGINT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
    tipo VARCHAR(50) NOT NULL CHECK (tipo IN ('recarga', 'compra', 'reembolso')),
    monto INTEGER NOT NULL,
    descripcion TEXT NOT NULL,
    pedido_id BIGINT REFERENCES pedidos(id) ON DELETE SET NULL,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_movimientos_wallet_id ON movimientos_wallet(wallet_id);
CREATE INDEX IF NOT EXISTS idx_movimientos_wallet_creado_en ON movimientos_wallet(creado_en DESC);

CREATE TABLE alertas_stock (
    id BIGSERIAL PRIMARY KEY,
    cafeteria_id BIGINT REFERENCES cafeterias(id) ON DELETE CASCADE,
    producto_id BIGINT REFERENCES productos(id) ON DELETE CASCADE,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE CASCADE,
    stock_actual INTEGER NOT NULL,
    stock_minimo INTEGER NOT NULL,
    mensaje TEXT,
    leida BOOLEAN DEFAULT false,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE movimientos_inventario (
    id BIGSERIAL PRIMARY KEY,
    producto_id BIGINT REFERENCES productos(id) ON DELETE CASCADE,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE SET NULL,
    tipo VARCHAR(50) NOT NULL,
    cantidad INTEGER NOT NULL,
    motivo VARCHAR(255),
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE detalles_pedido (
    id BIGSERIAL PRIMARY KEY,
    pedido_id BIGINT REFERENCES pedidos(id) ON DELETE CASCADE,
    producto_id BIGINT REFERENCES productos(id) ON DELETE SET NULL,
    cantidad INTEGER NOT NULL,
    precio_unitario DECIMAL(10,2) NOT NULL,
    subtotal DECIMAL(10,2) NOT NULL,
    nota VARCHAR(255)
);

CREATE TABLE pagos (
    id BIGSERIAL PRIMARY KEY,
    pedido_id BIGINT UNIQUE REFERENCES pedidos(id) ON DELETE CASCADE,
    metodo_pago_id BIGINT REFERENCES metodos_pago(id) ON DELETE SET NULL,
    monto DECIMAL(10,2) NOT NULL,
    estado VARCHAR(50) NOT NULL,
    es_simulado BOOLEAN DEFAULT false,
    latencia_ms INTEGER,
    referencia_transaccion VARCHAR(255) UNIQUE,
    comprobante_url TEXT,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE logs_validacion_qr (
    id BIGSERIAL PRIMARY KEY,
    cafeteria_id BIGINT REFERENCES cafeterias(id) ON DELETE CASCADE,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE SET NULL,
    pedido_id BIGINT REFERENCES pedidos(id) ON DELETE CASCADE,
    qr_token_leido VARCHAR(255),
    resultado VARCHAR(50),
    motivo_rechazo TEXT,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE logs_auditoria (
    id BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT REFERENCES usuarios(id) ON DELETE SET NULL,
    auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    tipo_evento VARCHAR(50) NOT NULL,
    tabla_afectada VARCHAR(100),
    registro_id BIGINT,
    accion VARCHAR(50) NOT NULL,
    datos_anteriores JSONB,
    datos_nuevos JSONB,
    ip_address INET,
    user_agent TEXT,
    metadata JSONB,
    creado_en TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
