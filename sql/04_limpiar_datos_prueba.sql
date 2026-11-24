-- Borra los datos de prueba y deja las tablas vacías (conserva el catálogo de errores y los metadatos).
USE StreamingOculus;
GO
DELETE FROM dbo.datos_telemetria;
DELETE FROM dbo.stg_telemetria;
DELETE FROM dbo.res_calidad_estado_hora;
DELETE FROM dbo.meta_etl_log;
DELETE FROM dbo.dim_tiempo;
DELETE FROM dbo.dim_ubicacion;
DELETE FROM dbo.dim_usuario;   -- usuarios.id_perfil pasa a NULL (ON DELETE SET NULL)
DBCC CHECKIDENT ('dbo.datos_telemetria', RESEED, 0);
DBCC CHECKIDENT ('dbo.stg_telemetria', RESEED, 0);
DBCC CHECKIDENT ('dbo.dim_tiempo', RESEED, 0);
DBCC CHECKIDENT ('dbo.dim_ubicacion', RESEED, 0);
DBCC CHECKIDENT ('dbo.dim_usuario', RESEED, 0);
GO
