import random, sqlite3, json, datetime as dt
random.seed(7)
# (pais, estado) -> ciudades. Latencia base: el servidor esta en Mexico, asi que los paises lejanos tienen mas latencia.
loc={('Mexico','Nayarit'):['Tepic','Xalisco'],('Mexico','Jalisco'):['Guadalajara','Zapopan','Tlaquepaque'],
     ('Mexico','Sinaloa'):['Culiacan','Mazatlan'],('Mexico','Ciudad de Mexico'):['Coyoacan','Iztapalapa'],
     ('Mexico','Nuevo Leon'):['Monterrey','San Nicolas'],
     ('Estados Unidos','Texas'):['Houston','Austin'],('Estados Unidos','California'):['Los Angeles','San Diego'],
     ('Colombia','Bogota D.C.'):['Bogota'],('Colombia','Antioquia'):['Medellin'],
     ('Peru','Lima'):['Lima'],('Peru','Arequipa'):['Arequipa'],
     ('Chile','Region Metropolitana'):['Santiago'],('Chile','Valparaiso'):['Valparaiso'],
     ('Argentina','Buenos Aires'):['Buenos Aires','La Plata'],('Argentina','Cordoba'):['Cordoba'],
     ('Brasil','Sao Paulo'):['Sao Paulo'],('Espana','Madrid'):['Madrid'],('Espana','Cataluna'):['Barcelona']}
base={('Mexico','Nayarit'):78,('Mexico','Jalisco'):62,('Mexico','Sinaloa'):84,('Mexico','Ciudad de Mexico'):58,('Mexico','Nuevo Leon'):54,
      ('Estados Unidos','Texas'):72,('Estados Unidos','California'):80,('Colombia','Bogota D.C.'):98,('Colombia','Antioquia'):104,
      ('Peru','Lima'):112,('Peru','Arequipa'):124,('Chile','Region Metropolitana'):126,('Chile','Valparaiso'):132,
      ('Argentina','Buenos Aires'):138,('Argentina','Cordoba'):146,('Brasil','Sao Paulo'):134,('Espana','Madrid'):162,('Espana','Cataluna'):168}
peso={k:(.55*w if k[0]=='Mexico' else .45/13) for k,w in
      {('Mexico','Nayarit'):.16,('Mexico','Jalisco'):.26,('Mexico','Sinaloa'):.14,('Mexico','Ciudad de Mexico'):.24,('Mexico','Nuevo Leon'):.20}.items()}
for k in loc:
    peso.setdefault(k,.45/13)
edades=['15-17','18-24','25-34','35+',None]; gens=['femenino','masculino','otro','prefiero no decir']; exps=['ninguna','basica','frecuente']
PAISES=['Mexico','Estados Unidos','Colombia','Peru','Chile','Brasil','Argentina','Espana']
def dispositivo(pais):  # cada pais tiene sus propios dispositivos (Mexico 1-35, los demas 5 c/u)
    i=PAISES.index(pais); lo,hi=(1,35) if i==0 else (31+5*i,35+5*i)
    return f'dev-{random.randint(lo,hi):03d}'
def fila(i):
    pe=random.choices(list(loc),[peso[k] for k in loc])[0]; pais,est=pe; ciu=random.choice(loc[pe])
    d=dt.datetime(2026,8,1)+dt.timedelta(days=random.randint(0,91),hours=random.choices(range(24),[1]*8+[2]*10+[3,4,6,8,9,7])[0],minutes=random.randint(0,59))
    h=d.hour; ed=random.choices(edades,[.06,.36,.28,.15,.15])[0]; ex=random.choices(exps,[.25,.4,.35])[0]
    lat=base[pe]+random.gauss(0,12)+(38 if 20<=h<=23 else 0)+(8 if h in (18,19) else 0)+(12 if ciu in('Iztapalapa','Mazatlan','Xalisco') else 0)
    lat=max(12,lat); resp=lat*0.55+random.gauss(18,6)
    paq=max(0,int(random.gauss(lat/22,2)))
    err=None
    if lat>=150 and random.random()<.7: err='latencia_alta'
    elif paq>=6 and random.random()<.6: err='paquete_perdido'
    elif random.random()<(.10 if (20<=h<=23 and ex=='ninguna') else .035): err='desconexion_bluetooth'
    elif random.random()<.02: err='fallo_decodificacion'
    elif random.random()<.015: err='reconexion_servidor'
    elif random.random()<.01: err='credenciales_invalidas'
    return dict(device=dispositivo(pais),fecha_evento=d.strftime('%Y-%m-%d %H:%M:%S'),pais=pais,estado=est,ciudad=ciu,
        rango_edad=ed,genero=random.choices(gens,[.3,.4,.05,.25])[0],experiencia_vr=ex,nombre_error=err,
        latencia=round(lat,1),tiempo_respuesta=round(resp,1),paquetes_perdidos=paq,controles='{"A":1,"LT":0.4}')
rows=[fila(i) for i in range(900)]
bad=[]
for k in range(40):
    r=fila(k); t=k%8
    if t==0: r['latencia']=None
    elif t==1: r['latencia']=-5
    elif t==2: r['device']=''
    elif t==3: r['fecha_evento']='2031-01-01 10:00:00'
    elif t==4: r['nombre_error']='error_inventado'
    elif t==5: r['controles']='{no es json'
    elif t==6: r['genero']='x'
    elif t==7: r['latencia']=9999
    bad.append(r)
allr=rows+bad; random.shuffle(allr)
db=sqlite3.connect('t.db'); db.executescript(open('esquema_streaming_sqlite.sql',encoding='utf-8').read())
cols=list(rows[0]); db.executemany(f"INSERT INTO stg_telemetria ({','.join(cols)}) VALUES ({','.join('?'*len(cols))})",[[r[c] for c in cols] for r in allr])
db.executescript(open('etl_sqlite.sql',encoding='utf-8').read()); db.commit()
q=lambda s:db.execute(s).fetchall()
print('cargados',q("select count(*) from datos_telemetria"),'estado',q("select estado_carga,count(*) from stg_telemetria group by 1"))
print('rechazos',q("select motivo_rechazo,count(*) from stg_telemetria where estado_carga='rechazado' group by 1"))
print('dim',q("select count(*) from dim_usuario"),q("select count(*) from dim_tiempo"),q("select count(*) from dim_ubicacion"))
# JSON para la página
db.row_factory=sqlite3.Row
data=[dict(r) for r in db.execute("select estado,ciudad,anio,mes,dia,hora,rango_edad,genero,experiencia_vr,categoria_error,nombre_error,latencia,tiempo_respuesta,paquetes_perdidos,rango_latencia from v_cubo_calidad")]
import csv
cols_csv=list(rows[0])
with open('telemetria_simulada.csv','w',newline='',encoding='utf-8-sig') as f:
    w=csv.writer(f); w.writerow(cols_csv)
    for r in allr: w.writerow(['' if r[c] is None else r[c] for c in cols_csv])
json.dump(data,open('cubo.json','w'),ensure_ascii=False,separators=(',',':'))
print(len(data),len(json.dumps(data)))
