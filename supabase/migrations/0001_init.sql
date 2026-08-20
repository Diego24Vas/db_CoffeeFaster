CREATE TABLE "UNIVERSIDADES" (
  "id" bigint PRIMARY KEY,
  "nombre" varchar,
  "rbd" varchar,
  "activa" boolean DEFAULT true
);

CREATE TABLE "CAMPUS_SEDES" (
  "id" bigint PRIMARY KEY,
  "universidad_id" bigint,
  "nombre_sede" varchar,
  "ciudad" varchar,
  "direccion" varchar,
  "latitud" numeric(10,8),
  "longitud" numeric(10,8)
);

CREATE TABLE "CAFETERIAS" (
  "id" bigint PRIMARY KEY,
  "campus_id" bigint,
  "nombre" varchar,
  "descripcion" varchar,
  "hora_apertura" time,
  "hora_cierre" time,
  "telefono" varchar,
  "imagen_url" varchar,
  "activa" boolean DEFAULT true
);

CREATE TABLE "USUARIOS" (
  "id" bigint PRIMARY KEY,
  "rol" varchar,
  "nombre" varchar,
  "apellido" varchar,
  "email" varchar UNIQUE,
  "telefono" varchar,
  "password_hash" varchar,
  "foto_url" varchar,
  "activo" boolean DEFAULT true,
  "ultima_conexion" timestamptz,
  "creado_en" timestamptz DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE "CAFETERIA_USUARIOS" (
  "id" bigint PRIMARY KEY,
  "usuario_id" bigint,
  "cafeteria_id" bigint,
  "cargo" varchar,
  "gestiona_inventario" boolean,
  "gestiona_productos" boolean,
  "gestiona_precios" boolean,
  "gestiona_pedidos_kds" boolean,
  "creado_en" timestamptz DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE "CATEGORIAS" (
  "id" bigint PRIMARY KEY,
  "nombre" varchar,
  "descripcion" varchar
);

CREATE TABLE "PRODUCTOS" (
  "id" bigint PRIMARY KEY,
  "cafeteria_id" bigint,
  "categoria_id" bigint,
  "nombre" varchar,
  "descripcion" text,
  "precio" numeric(10,2),
  "imagen_url" varchar,
  "stock" int DEFAULT 0,
  "stock_minimo" int DEFAULT 0,
  "activo" boolean DEFAULT true
);

CREATE TABLE "MOVIMIENTOS_INVENTARIO" (
  "id" bigint PRIMARY KEY,
  "producto_id" bigint,
  "usuario_id" bigint,
  "tipo" varchar,
  "cantidad" int,
  "motivo" varchar,
  "creado_en" timestamptz DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE "PEDIDOS" (
  "id" bigint PRIMARY KEY,
  "usuario_id" bigint,
  "cafeteria_id" bigint,
  "estado" varchar,
  "metodo_pago" varchar,
  "pago_estado" varchar,
  "nota" varchar,
  "total" numeric(10,2),
  "qr_token" varchar UNIQUE,
  "tiempo_estimado_min" int,
  "tiempo_real_min" int,
  "creado_en" timestamptz DEFAULT CURRENT_TIMESTAMP,
  "inicio_preparacion_en" timestamptz,
  "completado_en" timestamptz
);

CREATE TABLE "PAGOS" (
  "id" bigint PRIMARY KEY,
  "pedido_id" bigint,
  "monto" numeric(10,2),
  "estado" varchar,
  "referencia_transaccion" varchar UNIQUE,
  "comprobante_url" varchar,
  "creado_en" timestamptz DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE "DETALLES_PEDIDO" (
  "id" bigint PRIMARY KEY,
  "pedido_id" bigint,
  "producto_id" bigint,
  "cantidad" int,
  "precio_unitario" numeric(10,2),
  "subtotal" numeric(10,2),
  "nota" varchar
);

CREATE TABLE "DISPOSITIVOS" (
  "id" bigint PRIMARY KEY,
  "usuario_id" bigint,
  "token_fcm" varchar UNIQUE,
  "plataforma" varchar,
  "ultima_conexion" timestamptz,
  "creado_en" timestamptz DEFAULT CURRENT_TIMESTAMP
);

-- Comentarios
COMMENT ON COLUMN "UNIVERSIDADES"."nombre" IS 'INACAP, UNAB, USS...';
COMMENT ON COLUMN "CAMPUS_SEDES"."nombre_sede" IS 'Sede Santiago | Sede Osorno';
COMMENT ON COLUMN "CAMPUS_SEDES"."ciudad" IS 'Santiago | Osorno | Valdivia';
COMMENT ON COLUMN "CAMPUS_SEDES"."latitud" IS 'GPS de la sede';
COMMENT ON COLUMN "CAMPUS_SEDES"."longitud" IS 'GPS de la sede';
COMMENT ON COLUMN "USUARIOS"."rol" IS 'cliente | dueño | empleado | superadmin';
COMMENT ON COLUMN "CAFETERIA_USUARIOS"."usuario_id" IS 'dueño o empleado';
COMMENT ON COLUMN "CAFETERIA_USUARIOS"."cargo" IS 'dueño | empleado';
COMMENT ON COLUMN "CATEGORIAS"."nombre" IS 'bebidas | snacks | comidas';
COMMENT ON COLUMN "PRODUCTOS"."stock" IS 'inventario disponible';
COMMENT ON COLUMN "PRODUCTOS"."stock_minimo" IS 'alerta de reposición';
COMMENT ON COLUMN "MOVIMIENTOS_INVENTARIO"."usuario_id" IS 'responsable del movimiento';
COMMENT ON COLUMN "MOVIMIENTOS_INVENTARIO"."tipo" IS 'entrada | venta | ajuste | merma';
COMMENT ON COLUMN "PEDIDOS"."estado" IS 'pendiente | preparando | listo | entregado | cancelado';
COMMENT ON COLUMN "PEDIDOS"."metodo_pago" IS 'tarjeta | efectivo | yape';
COMMENT ON COLUMN "PEDIDOS"."pago_estado" IS 'pendiente | pagado | reembolsado';
COMMENT ON COLUMN "PEDIDOS"."nota" IS 'comentarios del cliente';
COMMENT ON COLUMN "PEDIDOS"."qr_token" IS 'token de retiro';
COMMENT ON COLUMN "PEDIDOS"."tiempo_real_min" IS 'calibra el estimador de colas';
COMMENT ON COLUMN "PAGOS"."estado" IS 'pendiente | pagado | fallido | reembolsado';
COMMENT ON COLUMN "PAGOS"."comprobante_url" IS 'PDF de boleta digital';
COMMENT ON COLUMN "DETALLES_PEDIDO"."precio_unitario" IS 'precio congelado al momento del pedido';
COMMENT ON COLUMN "DETALLES_PEDIDO"."nota" IS 'opciones por línea (sin hielo, etc.)';
COMMENT ON COLUMN "DISPOSITIVOS"."plataforma" IS 'android | windows';

-- Llaves Foráneas
ALTER TABLE "CAMPUS_SEDES" ADD FOREIGN KEY ("universidad_id") REFERENCES "UNIVERSIDADES" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "CAFETERIAS" ADD FOREIGN KEY ("campus_id") REFERENCES "CAMPUS_SEDES" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "CAFETERIA_USUARIOS" ADD FOREIGN KEY ("cafeteria_id") REFERENCES "CAFETERIAS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "PRODUCTOS" ADD FOREIGN KEY ("cafeteria_id") REFERENCES "CAFETERIAS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "PEDIDOS" ADD FOREIGN KEY ("cafeteria_id") REFERENCES "CAFETERIAS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "PEDIDOS" ADD FOREIGN KEY ("usuario_id") REFERENCES "USUARIOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "CAFETERIA_USUARIOS" ADD FOREIGN KEY ("usuario_id") REFERENCES "USUARIOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "DISPOSITIVOS" ADD FOREIGN KEY ("usuario_id") REFERENCES "USUARIOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "MOVIMIENTOS_INVENTARIO" ADD FOREIGN KEY ("usuario_id") REFERENCES "USUARIOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "PRODUCTOS" ADD FOREIGN KEY ("categoria_id") REFERENCES "CATEGORIAS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "DETALLES_PEDIDO" ADD FOREIGN KEY ("producto_id") REFERENCES "PRODUCTOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "MOVIMIENTOS_INVENTARIO" ADD FOREIGN KEY ("producto_id") REFERENCES "PRODUCTOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "DETALLES_PEDIDO" ADD FOREIGN KEY ("pedido_id") REFERENCES "PEDIDOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;

-- ¡ESTA ES LA LÍNEA CORREGIDA!
ALTER TABLE "PAGOS" ADD FOREIGN KEY ("pedido_id") REFERENCES "PEDIDOS" ("id") DEFERRABLE INITIALLY IMMEDIATE;