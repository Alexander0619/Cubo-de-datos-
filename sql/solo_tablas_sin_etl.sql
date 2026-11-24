-- ============================================================
-- Streaming de PC a Oculus - Creación de la base de datos (SQL Server)
-- Solo creación: base de datos y tablas
-- ============================================================
IF DB_ID(N'StreamingOculus') IS NULL
    CREATE DATABASE StreamingOculus;
GO
USE StreamingOculus;
GO

-- Dimensión: perfil del usuario
CREATE TABLE dbo.dim_usuario (
    id_perfil       INT IDENTITY(1,1) PRIMARY KEY,
    rango_edad      NVARCHAR(10) NULL CONSTRAINT CK_dim_usuario_edad CHECK (rango_edad IN (N'15-17', N'18-24', N'25-34', N'35+')),
    genero          NVARCHAR(20) NOT NULL DEFAULT (N'prefiero no decir')
                    CHECK (genero IN (N'femenino', N'masculino', N'otro', N'prefiero no decir')),
    experiencia_vr  NVARCHAR(10) NULL CHECK (experiencia_vr IN (N'ninguna', N'basica', N'frecuente'))
);
GO

-- Dimensión: ubicación
CREATE TABLE dbo.dim_ubicacion (
    id_ubicacion    INT IDENTITY(1,1) PRIMARY KEY,
    pais            NVARCHAR(60) NOT NULL,
    estado          NVARCHAR(60) NOT NULL,
    ciudad          NVARCHAR(80) NOT NULL,
    UNIQUE (pais, estado, ciudad)
);
GO

-- Dimensión: tiempo
CREATE TABLE dbo.dim_tiempo (
    id_tiempo       INT IDENTITY(1,1) PRIMARY KEY,
    fecha           DATETIME2(0) NOT NULL UNIQUE,
    anio            INT NOT NULL,
    mes             TINYINT NOT NULL CHECK (mes BETWEEN 1 AND 12),
    semana          TINYINT NOT NULL CHECK (semana BETWEEN 1 AND 53),
    dia             TINYINT NOT NULL CHECK (dia BETWEEN 1 AND 31),
    hora            TINYINT NOT NULL CHECK (hora BETWEEN 0 AND 23)
);
GO

-- Dimensión: tipo de error
CREATE TABLE dbo.dim_error (
    id_error         INT IDENTITY(1,1) PRIMARY KEY,
    categoria_error  NVARCHAR(20) NOT NULL CHECK (categoria_error IN (N'red', N'dispositivo', N'autenticacion')),
    nombre_error     NVARCHAR(60) NOT NULL UNIQUE,
    descripcion      NVARCHAR(200) NULL
);
GO

-- Tabla de login (fuera de la estrella)
-- Cuentas locales: password guarda la sal y la mitad R del secreto ("sal$R").
-- Cuentas externas (Microsoft, Google): password es NULL y se guarda id_externo.
-- encuesta_estado controla la encuesta opcional del primer uso.
CREATE TABLE dbo.usuarios (
    id_usuario      INT IDENTITY(1,1) PRIMARY KEY,
    id_perfil       INT NULL REFERENCES dbo.dim_usuario (id_perfil) ON DELETE SET NULL,
    nombre_usuario  NVARCHAR(50)  NOT NULL UNIQUE,
    email           NVARCHAR(120) NOT NULL UNIQUE,
    password        NVARCHAR(300) NULL,
    proveedor       NVARCHAR(12)  NOT NULL CONSTRAINT DF_usuarios_proveedor DEFAULT (N'local')
                    CONSTRAINT CK_usuarios_proveedor CHECK (proveedor IN (N'local', N'microsoft', N'google')),
    id_externo      NVARCHAR(128) NULL,
    encuesta_estado NVARCHAR(12)  NOT NULL CONSTRAINT DF_usuarios_encuesta DEFAULT (N'pendiente')
                    CONSTRAINT CK_usuarios_encuesta CHECK (encuesta_estado IN (N'pendiente', N'pospuesta', N'completada')),
    creado_en       DATETIME2(0)  NOT NULL CONSTRAINT DF_usuarios_creado DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_usuarios_credencial CHECK (
        (proveedor = N'local' AND password IS NOT NULL) OR (proveedor <> N'local' AND id_externo IS NOT NULL))
);
GO
CREATE UNIQUE INDEX ux_usuarios_externo ON dbo.usuarios (proveedor, id_externo) WHERE id_externo IS NOT NULL;
GO

-- Registro de aceptación de los términos (quién, cuándo y qué versión)
CREATE TABLE dbo.consentimientos (
    id_consentimiento   BIGINT IDENTITY(1,1) PRIMARY KEY,
    id_usuario          INT NULL REFERENCES dbo.usuarios (id_usuario) ON DELETE SET NULL,
    version_terminos    NVARCHAR(10) NOT NULL,
    aceptado_en         DATETIME2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
    segundos_en_pantalla INT NULL CHECK (segundos_en_pantalla >= 0),
    llego_al_final      BIT NULL
);
GO
CREATE UNIQUE INDEX ux_consent_usuario_version ON dbo.consentimientos (id_usuario, version_terminos) WHERE id_usuario IS NOT NULL;
GO

-- Tabla de hechos: una fila por muestra/sesión
-- id_registro permite varias muestras por dispositivo (historia para el cubo).
-- device es un seudónimo del dispositivo (dimensión degenerada), no es llave.
CREATE TABLE dbo.datos_telemetria (
    id_registro        BIGINT IDENTITY(1,1) PRIMARY KEY,
    device             NVARCHAR(64) NOT NULL,
    id_tiempo          INT NOT NULL REFERENCES dbo.dim_tiempo (id_tiempo),
    id_ubicacion       INT NOT NULL REFERENCES dbo.dim_ubicacion (id_ubicacion),
    id_perfil          INT NULL REFERENCES dbo.dim_usuario (id_perfil) ON DELETE SET NULL,
    id_error           INT NULL REFERENCES dbo.dim_error (id_error),
    latencia           FLOAT NOT NULL CHECK (latencia >= 0),
    tiempo_respuesta   FLOAT NOT NULL CHECK (tiempo_respuesta >= 0),
    paquetes_perdidos  INT NOT NULL DEFAULT (0) CHECK (paquetes_perdidos >= 0),
    controles          NVARCHAR(MAX) NULL
);
GO

-- ------------------------------------------------------------
-- Área de preparación (ETL): aquí llega la telemetría cruda de la app.
-- Sin restricciones a propósito: los datos sucios se aceptan aquí y el
-- proceso de carga los limpia o los rechaza con un motivo.
-- ------------------------------------------------------------
CREATE TABLE dbo.stg_telemetria (
    id_stg             BIGINT IDENTITY(1,1) PRIMARY KEY,
    recibido_en        DATETIME2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
    device             NVARCHAR(64)  NULL,
    fecha_evento       DATETIME2(0)  NULL,
    pais               NVARCHAR(60)  NULL,
    estado             NVARCHAR(60)  NULL,
    ciudad             NVARCHAR(80)  NULL,
    rango_edad         NVARCHAR(10)  NULL,
    genero             NVARCHAR(20)  NULL,
    experiencia_vr     NVARCHAR(10)  NULL,
    nombre_error       NVARCHAR(60)  NULL,
    latencia           FLOAT NULL,
    tiempo_respuesta   FLOAT NULL,
    paquetes_perdidos  INT   NULL,
    controles          NVARCHAR(MAX) NULL,
    estado_carga       NVARCHAR(12) NOT NULL DEFAULT (N'pendiente')
                       CHECK (estado_carga IN (N'pendiente', N'cargado', N'rechazado')),
    motivo_rechazo     NVARCHAR(100) NULL
);
GO

-- ------------------------------------------------------------
-- Metadatos: diccionario, jerarquías de conceptos y bitácora del ETL
-- ------------------------------------------------------------
CREATE TABLE dbo.meta_diccionario (
    id_meta          INT IDENTITY(1,1) PRIMARY KEY,
    objeto           NVARCHAR(60)  NOT NULL,   -- tabla o vista
    columna          NVARCHAR(60)  NOT NULL,
    rol              NVARCHAR(12)  NOT NULL CHECK (rol IN (N'llave', N'dimension', N'medida', N'atributo')),
    descripcion      NVARCHAR(200) NOT NULL,
    fuente           NVARCHAR(100) NULL,       -- de dónde viene el dato
    transformacion   NVARCHAR(200) NULL,       -- qué se le hace al cargarlo
    tipo_agregacion  NVARCHAR(12)  NULL CHECK (tipo_agregacion IN (N'distributiva', N'algebraica', N'holistica')),
    nivel_acceso     NVARCHAR(12)  NOT NULL CHECK (nivel_acceso IN (N'operativo', N'analitico', N'restringido')),
    UNIQUE (objeto, columna)
);
GO

CREATE TABLE dbo.meta_jerarquia (
    id_jerarquia     INT IDENTITY(1,1) PRIMARY KEY,
    dimension        NVARCHAR(30) NOT NULL,
    tipo             NVARCHAR(10) NOT NULL CHECK (tipo IN (N'esquema', N'agrupacion')),
    nivel            NVARCHAR(40) NOT NULL,
    orden            TINYINT NOT NULL,         -- 1 = nivel más detallado
    definicion       NVARCHAR(200) NULL,
    UNIQUE (dimension, tipo, orden)
);
GO

CREATE TABLE dbo.meta_etl_log (
    id_log           INT IDENTITY(1,1) PRIMARY KEY,
    ejecutado_en     DATETIME2(0) NOT NULL DEFAULT (SYSUTCDATETIME()),
    leidos           INT NOT NULL,
    cargados         INT NOT NULL,
    rechazados       INT NOT NULL
);
GO

-- Resumen precalculado (cuboide estado x hora) con medidas distributivas
CREATE TABLE dbo.res_calidad_estado_hora (
    estado           NVARCHAR(60) NOT NULL,
    hora             TINYINT NOT NULL,
    sesiones         INT   NOT NULL,   -- count()  distributiva
    suma_latencia    FLOAT NOT NULL,   -- sum()    distributiva
    max_latencia     FLOAT NOT NULL,   -- max()    distributiva
    suma_paquetes    INT   NOT NULL,   -- sum()    distributiva
    PRIMARY KEY (estado, hora)
);
GO
