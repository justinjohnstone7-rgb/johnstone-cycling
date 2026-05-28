#!/bin/bash
echo "Step 1: Scanning GPX files..."
python3 -c "
import os, json
base = 'assets/Experienced'
data = {}
for country in sorted(os.listdir(base)):
    country_path = os.path.join(base, country)
    if os.path.isdir(country_path):
        gpx_files = sorted([f'{base}/{country}/{f}' for f in os.listdir(country_path) if f.endswith('.gpx')])
        if gpx_files:
            data[country] = gpx_files
with open('tours.json', 'w') as f:
    json.dump(data, f, indent=2)
print('  Found:', {k: len(v) for k, v in data.items()})
"

echo "Step 2: Processing GPX data..."
python3 -c "
import os, json, xml.etree.ElementTree as ET, math

def parse_gpx(filepath):
    try:
        tree = ET.parse(filepath)
        root = tree.getroot()
        ns = {'gpx': 'http://www.topografix.com/GPX/1/1'}
        coords, elevations, date_str = [], [], None
        for trkpt in root.findall('.//gpx:trkpt', ns):
            lat = float(trkpt.get('lat'))
            lon = float(trkpt.get('lon'))
            ele = trkpt.find('gpx:ele', ns)
            time = trkpt.find('gpx:time', ns)
            elev = float(ele.text) if ele is not None else None
            coords.append([lon, lat, elev])
            if elev is not None: elevations.append(elev)
            if date_str is None and time is not None: date_str = time.text
        distance_km = 0
        for i in range(1, len(coords)):
            lon1, lat1 = coords[i-1][0], coords[i-1][1]
            lon2, lat2 = coords[i][0], coords[i][1]
            R = 6371
            dlat = math.radians(lat2-lat1); dlon = math.radians(lon2-lon1)
            a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(dlon/2)**2
            distance_km += R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        elevation_gain = sum(max(0, elevations[i]-elevations[i-1]) for i in range(1, len(elevations)))
        return coords, round(distance_km, 1), round(elevation_gain), date_str
    except Exception as e:
        print(f'  Error: {filepath}: {e}')
        return [], 0, 0, None

def friendly_name(f): return os.path.basename(f).replace('.gpx','').replace('_',' ')

with open('tours.json') as f: tours = json.load(f)
features = []
for country, files in tours.items():
    for filepath in files:
        coords, distance_km, elevation_gain, date_str = parse_gpx(filepath)
        if coords:
            features.append({'type':'Feature','properties':{'country':country,'file':filepath,'name':friendly_name(filepath),'distance_km':distance_km,'elevation_gain':elevation_gain,'date':date_str},'geometry':{'type':'LineString','coordinates':coords}})
with open('routes.geojson', 'w') as f: json.dump({'type':'FeatureCollection','features':features}, f)
print(f'  {len(features)} routes processed.')
"

echo "Step 3: Simplifying geometry..."
python3 -c "
import json, math
def simplify(coords, tolerance=0.0001):
    if len(coords) <= 2: return coords
    def dist(p, a, b):
        if a == b: return math.hypot(p[0]-a[0], p[1]-a[1])
        dx, dy = b[0]-a[0], b[1]-a[1]
        t = max(0, min(1, ((p[0]-a[0])*dx+(p[1]-a[1])*dy)/(dx*dx+dy*dy)))
        return math.hypot(p[0]-(a[0]+t*dx), p[1]-(a[1]+t*dy))
    def rdp(pts, tol):
        if len(pts) <= 2: return pts
        dmax, idx = 0, 0
        for i in range(1, len(pts)-1):
            d = dist(pts[i], pts[0], pts[-1])
            if d > dmax: dmax, idx = d, i
        if dmax >= tol: return rdp(pts[:idx+1], tol)[:-1] + rdp(pts[idx:], tol)
        return [pts[0], pts[-1]]
    return rdp(coords, tolerance)
with open('routes.geojson') as f: data = json.load(f)
orig, simp = 0, 0
for feature in data['features']:
    coords = feature['geometry']['coordinates']
    orig += len(coords)
    s = simplify(coords)
    feature['geometry']['coordinates'] = s
    simp += len(s)
with open('routes.geojson', 'w') as f: json.dump(data, f)
print(f'  {orig:,} → {simp:,} points ({round((1-simp/orig)*100)}% reduction)')
"

echo "Step 4a: Converting HEIC/JPG photos to WebP and resizing..."
python3 -c "
import os
import pillow_heif
from PIL import Image

pillow_heif.register_heif_opener()

MAX_PX = 2000

def resize_to_web(img):
    w, h = img.size
    if max(w, h) <= MAX_PX:
        return img
    if w >= h:
        return img.resize((MAX_PX, round(h * MAX_PX / w)), Image.LANCZOS)
    else:
        return img.resize((round(w * MAX_PX / h), MAX_PX), Image.LANCZOS)

bases = ['assets/Photos/Touring_images', 'assets/Photos/Club_images']
converted = 0
for base in bases:
    if not os.path.exists(base): continue
    for fname in os.listdir(base):
        fpath = os.path.join(base, fname)
        webp_path = fpath.rsplit('.', 1)[0] + '.webp'
        if fname.lower().endswith('.heic'):
            if os.path.exists(webp_path): continue
            try:
                img = Image.open(fpath)
                if img.mode in ('RGBA', 'P'): img = img.convert('RGB')
                img = resize_to_web(img)
                img.save(webp_path, 'WEBP', quality=82)
                converted += 1
                print(f'  Converted: {fname}')
            except Exception as e:
                print(f'  Failed: {fname}: {e}')
        elif fname.lower().endswith(('.jpg', '.jpeg')):
            try:
                img = Image.open(fpath)
                if img.mode in ('RGBA', 'P'): img = img.convert('RGB')
                img = resize_to_web(img)
                img.save(webp_path, 'WEBP', quality=82)
                os.remove(fpath)
                converted += 1
                print(f'  Converted: {fname}')
            except Exception as e:
                print(f'  Failed: {fname}: {e}')
print(f'  {converted} photos converted to WebP.')
"

echo "Step 4b: Extracting photo GPS data..."
python3 -c "
import os, json
import pillow_heif
from PIL import Image
from PIL.ExifTags import TAGS, GPSTAGS

pillow_heif.register_heif_opener()

def get_heic_gps(filepath):
    try:
        heif = pillow_heif.open_heif(filepath)
        exif_bytes = heif.info.get('exif')
        if not exif_bytes: return None
        if exif_bytes[:6] == b'Exif\x00\x00': exif_bytes = exif_bytes[6:]
        import piexif
        exif_dict = piexif.load(exif_bytes)
        gps = exif_dict.get('GPS', {})
        if not gps: return None
        def to_decimal(dms, ref):
            d = dms[0][0]/dms[0][1]; m = dms[1][0]/dms[1][1]; s = dms[2][0]/dms[2][1]
            decimal = d + m/60 + s/3600
            if ref in [b'S', b'W']: decimal = -decimal
            return round(decimal, 6)
        return [to_decimal(gps[piexif.GPSIFD.GPSLatitude], gps[piexif.GPSIFD.GPSLatitudeRef]),
                to_decimal(gps[piexif.GPSIFD.GPSLongitude], gps[piexif.GPSIFD.GPSLongitudeRef])]
    except: return None

def get_jpg_gps(filepath):
    try:
        img = Image.open(filepath)
        exif_data = img._getexif()
        if not exif_data: return None
        gps_info = {}
        for tag, value in exif_data.items():
            if TAGS.get(tag) == 'GPSInfo':
                for k, v in value.items(): gps_info[GPSTAGS.get(k, k)] = v
        if not gps_info: return None
        def to_decimal(dms, ref):
            d, m, s = dms
            decimal = float(d) + float(m)/60 + float(s)/3600
            if ref in ['S', 'W']: decimal = -decimal
            return round(decimal, 6)
        return [to_decimal(gps_info['GPSLatitude'], gps_info['GPSLatitudeRef']),
                to_decimal(gps_info['GPSLongitude'], gps_info['GPSLongitudeRef'])]
    except: return None

photos_data = []
base = 'assets/Photos/Touring_images'
if os.path.exists(base):
    for fname in sorted(os.listdir(base)):
        fpath = os.path.join(base, fname)
        if not os.path.isfile(fpath): continue
        ext = fname.lower()
        if ext.endswith('.heic'):
            coords = get_heic_gps(fpath)
            webp_path = fpath.rsplit('.', 1)[0] + '.webp'
            display_path = webp_path if os.path.exists(webp_path) else None
        elif ext.endswith('.webp'):
            coords = get_jpg_gps(fpath)
            display_path = fpath
        elif ext.endswith(('.jpg', '.jpeg', '.png')):
            coords = get_jpg_gps(fpath)
            display_path = fpath
        else:
            continue
        if coords and display_path:
            photos_data.append({'path': display_path, 'lat': coords[0], 'lon': coords[1]})

with open('touring_photos.json', 'w') as f: json.dump(photos_data, f)
print(f'  {len(photos_data)} geotagged photos indexed.')
"

echo "Step 4c: Extracting club photo GPS data..."
python3 -c "
import os, json
import pillow_heif
from PIL import Image
from PIL.ExifTags import TAGS, GPSTAGS

pillow_heif.register_heif_opener()

def get_heic_gps(filepath):
    try:
        heif = pillow_heif.open_heif(filepath)
        exif_bytes = heif.info.get('exif')
        if not exif_bytes: return None
        if exif_bytes[:6] == b'Exif\x00\x00': exif_bytes = exif_bytes[6:]
        import piexif
        exif_dict = piexif.load(exif_bytes)
        gps = exif_dict.get('GPS', {})
        if not gps: return None
        def to_decimal(dms, ref):
            d = dms[0][0]/dms[0][1]; m = dms[1][0]/dms[1][1]; s = dms[2][0]/dms[2][1]
            decimal = d + m/60 + s/3600
            if ref in [b'S', b'W']: decimal = -decimal
            return round(decimal, 6)
        return [to_decimal(gps[piexif.GPSIFD.GPSLatitude], gps[piexif.GPSIFD.GPSLatitudeRef]),
                to_decimal(gps[piexif.GPSIFD.GPSLongitude], gps[piexif.GPSIFD.GPSLongitudeRef])]
    except: return None

def get_jpg_gps(filepath):
    try:
        img = Image.open(filepath)
        exif_data = img._getexif()
        if not exif_data: return None
        gps_info = {}
        for tag, value in exif_data.items():
            if TAGS.get(tag) == 'GPSInfo':
                for k, v in value.items(): gps_info[GPSTAGS.get(k, k)] = v
        if not gps_info: return None
        def to_decimal(dms, ref):
            d, m, s = dms
            decimal = float(d) + float(m)/60 + float(s)/3600
            if ref in ['S', 'W']: decimal = -decimal
            return round(decimal, 6)
        return [to_decimal(gps_info['GPSLatitude'], gps_info['GPSLatitudeRef']),
                to_decimal(gps_info['GPSLongitude'], gps_info['GPSLongitudeRef'])]
    except: return None

photos_data = []
base = 'assets/Photos/Club_images'
if os.path.exists(base):
    for fname in sorted(os.listdir(base)):
        fpath = os.path.join(base, fname)
        if not os.path.isfile(fpath): continue
        ext = fname.lower()
        if ext.endswith('.heic'):
            coords = get_heic_gps(fpath)
            webp_path = fpath.rsplit('.', 1)[0] + '.webp'
            display_path = webp_path if os.path.exists(webp_path) else None
        elif ext.endswith('.webp'):
            coords = get_jpg_gps(fpath)
            display_path = fpath
        elif ext.endswith(('.jpg', '.jpeg', '.png')):
            coords = get_jpg_gps(fpath)
            display_path = fpath
        else:
            continue
        if coords and display_path:
            photos_data.append({'path': display_path, 'lat': coords[0], 'lon': coords[1]})

with open('club_photos.json', 'w') as f: json.dump(photos_data, f)
print(f'  {len(photos_data)} geotagged club photos indexed.')
"

echo "✓ Done! Refresh your browser to see the changes."