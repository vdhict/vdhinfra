import math, datetime
LAT, LON = 51.8582341, 4.4838181
def sunpos(dt):  # dt: aware UTC datetime -> (elevation_deg, azimuth_deg)
    jd = dt.timestamp()/86400.0 + 2440587.5
    n = jd - 2451545.0
    L = (280.460 + 0.9856474*n) % 360
    g = math.radians((357.528 + 0.9856003*n) % 360)
    lam = math.radians(L + 1.915*math.sin(g) + 0.020*math.sin(2*g))
    eps = math.radians(23.439 - 0.0000004*n)
    ra = math.atan2(math.cos(eps)*math.sin(lam), math.cos(lam))
    dec = math.asin(math.sin(eps)*math.sin(lam))
    gmst = (18.697374558 + 24.06570982441908*n) % 24
    lst = math.radians((gmst*15 + LON) % 360)
    H = lst - ra
    lat = math.radians(LAT)
    el = math.asin(math.sin(lat)*math.sin(dec) + math.cos(lat)*math.cos(dec)*math.cos(H))
    az = math.atan2(math.sin(H), math.cos(H)*math.sin(lat) - math.tan(dec)*math.cos(lat))
    return math.degrees(el), (math.degrees(az) + 180) % 360
def p(ts, label=''):
    dt = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
    el, az = sunpos(dt)
    loc = dt.astimezone(datetime.timezone(datetime.timedelta(hours=2)))
    print(f"{ts}  local {loc.strftime('%Y-%m-%d %H:%M')}  elev={el:6.2f}  azim={az:6.2f}   {label}")
if __name__=='__main__':
    import sys
    for a in sys.argv[1:]:
        if '=' in a: ts,lab=a.split('=',1)
        else: ts,lab=a,''
        p(ts,lab)
