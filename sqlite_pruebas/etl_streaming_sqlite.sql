-- ETL en SQLite (mismo orden que sp_cargar_telemetria de SQL Server)
-- 1) Limpiar
UPDATE stg_telemetria SET estado_carga='rechazado', motivo_rechazo = CASE
    WHEN device IS NULL OR trim(device)='' THEN 'sin dispositivo'
    WHEN fecha_evento IS NULL THEN 'sin fecha'
    WHEN fecha_evento > datetime('now','+1 day') THEN 'fecha en el futuro'
    WHEN latencia IS NULL OR latencia<0 OR latencia>5000 THEN 'latencia fuera de rango'
    WHEN tiempo_respuesta IS NULL OR tiempo_respuesta<0 THEN 'tiempo de respuesta invalido'
    WHEN paquetes_perdidos<0 THEN 'paquetes negativos'
    WHEN pais IS NULL OR estado IS NULL OR ciudad IS NULL THEN 'sin ubicacion'
    ELSE 'error desconocido' END
WHERE estado_carga='pendiente' AND (
    device IS NULL OR trim(device)='' OR fecha_evento IS NULL OR fecha_evento > datetime('now','+1 day')
    OR latencia IS NULL OR latencia<0 OR latencia>5000 OR tiempo_respuesta IS NULL OR tiempo_respuesta<0
    OR paquetes_perdidos<0 OR pais IS NULL OR estado IS NULL OR ciudad IS NULL
    OR (nombre_error IS NOT NULL AND nombre_error NOT IN (SELECT nombre_error FROM dim_error)));
UPDATE stg_telemetria SET controles=NULL WHERE estado_carga='pendiente' AND controles IS NOT NULL AND json_valid(controles)=0;
UPDATE stg_telemetria SET paquetes_perdidos=0 WHERE estado_carga='pendiente' AND paquetes_perdidos IS NULL;
UPDATE stg_telemetria SET genero='prefiero no decir' WHERE estado_carga='pendiente' AND (genero IS NULL OR genero NOT IN ('femenino','masculino','otro','prefiero no decir'));
UPDATE stg_telemetria SET rango_edad=NULL WHERE estado_carga='pendiente' AND rango_edad NOT IN ('15-17','18-24','25-34','35+');
UPDATE stg_telemetria SET experiencia_vr=NULL WHERE estado_carga='pendiente' AND experiencia_vr NOT IN ('ninguna','basica','frecuente');
-- 2) Transformar
INSERT OR IGNORE INTO dim_tiempo (fecha,anio,mes,semana,dia,hora)
SELECT DISTINCT strftime('%Y-%m-%d %H:00:00',fecha_evento), CAST(strftime('%Y',fecha_evento) AS INT),
       CAST(strftime('%m',fecha_evento) AS INT), CAST(strftime('%W',fecha_evento) AS INT)+1,
       CAST(strftime('%d',fecha_evento) AS INT), CAST(strftime('%H',fecha_evento) AS INT)
FROM stg_telemetria WHERE estado_carga='pendiente';
INSERT OR IGNORE INTO dim_ubicacion (pais,estado,ciudad)
SELECT DISTINCT pais,estado,ciudad FROM stg_telemetria WHERE estado_carga='pendiente';
INSERT INTO dim_usuario (rango_edad,genero,experiencia_vr)
SELECT DISTINCT s.rango_edad,s.genero,s.experiencia_vr FROM stg_telemetria s
WHERE s.estado_carga='pendiente' AND NOT EXISTS (SELECT 1 FROM dim_usuario d
  WHERE IFNULL(d.rango_edad,'')=IFNULL(s.rango_edad,'') AND d.genero=s.genero AND IFNULL(d.experiencia_vr,'')=IFNULL(s.experiencia_vr,''));
-- 3) Cargar
INSERT INTO datos_telemetria (device,id_tiempo,id_ubicacion,id_perfil,id_error,latencia,tiempo_respuesta,paquetes_perdidos,controles)
SELECT s.device,ti.id_tiempo,u.id_ubicacion,p.id_perfil,e.id_error,s.latencia,s.tiempo_respuesta,s.paquetes_perdidos,s.controles
FROM stg_telemetria s
JOIN dim_tiempo ti ON ti.fecha=strftime('%Y-%m-%d %H:00:00',s.fecha_evento)
JOIN dim_ubicacion u ON u.pais=s.pais AND u.estado=s.estado AND u.ciudad=s.ciudad
JOIN dim_usuario p ON IFNULL(p.rango_edad,'')=IFNULL(s.rango_edad,'') AND p.genero=s.genero AND IFNULL(p.experiencia_vr,'')=IFNULL(s.experiencia_vr,'')
LEFT JOIN dim_error e ON e.nombre_error=s.nombre_error
WHERE s.estado_carga='pendiente';
UPDATE stg_telemetria SET estado_carga='cargado' WHERE estado_carga='pendiente';
