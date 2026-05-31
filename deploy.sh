#!/bin/bash
# Usage: ./deploy.sh
# Drop new photos into assets/Photos/Touring_images/ or Club_images/, then run this.
# First run will download existing R2 photos to generate thumbnails — subsequent runs are fast.

set -e

R2_PUBLIC="https://pub-ae8df0260aa04fb1a08eafd3a8e08737.r2.dev"
R2_BUCKET="johnstone-cycling"
RCLONE="./rclone"

echo ""
echo "══════════════════════════════════════════"
echo "  Johnstone Cycling — Deploy"
echo "══════════════════════════════════════════"
echo ""

# ── GPX ──────────────────────────────────────────────────────────

echo "Step 1/7: Scanning GPX files..."
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

echo "Step 2/7: Processing GPX data..."
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

echo "Step 3/7: Simplifying geometry..."
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

# ── Photos ───────────────────────────────────────────────────────

echo "Step 4/7: Converting new HEIC/JPG photos to WebP..."
python3 -c "
import os, pillow_heif
from PIL import Image
pillow_heif.register_heif_opener()

MAX_PX = 2000

def resize_to_web(img):
    w, h = img.size
    if max(w, h) <= MAX_PX: return img
    scale = MAX_PX / max(w, h)
    return img.resize((round(w*scale), round(h*scale)), Image.LANCZOS)

converted = 0
for base in ['assets/Photos/Touring_images', 'assets/Photos/Club_images']:
    if not os.path.exists(base): continue
    for fname in os.listdir(base):
        fpath = os.path.join(base, fname)
        webp_path = fpath.rsplit('.', 1)[0] + '.webp'
        if fname.lower().endswith('.heic'):
            if os.path.exists(webp_path): continue
            try:
                img = resize_to_web(Image.open(fpath).convert('RGB'))
                img.save(webp_path, 'WEBP', quality=82)
                converted += 1
                print(f'  Converted: {fname}')
            except Exception as e: print(f'  Failed: {fname}: {e}')
        elif fname.lower().endswith(('.jpg', '.jpeg')):
            try:
                img = resize_to_web(Image.open(fpath).convert('RGB'))
                img.save(webp_path, 'WEBP', quality=82)
                os.remove(fpath)
                converted += 1
                print(f'  Converted: {fname}')
            except Exception as e: print(f'  Failed: {fname}: {e}')
print(f'  {converted} photos converted.')
"

echo "Step 5/7: Generating thumbnails..."
python3 << 'PYEOF'
import os, subprocess
from PIL import Image
import pillow_heif
pillow_heif.register_heif_opener()

THUMB_SIZE = 150
QUALITY = 72

def make_thumb(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    img = Image.open(src)
    if img.mode in ('RGBA', 'P'): img = img.convert('RGB')
    w, h = img.size
    m = min(w, h)
    img = img.crop(((w-m)//2, (h-m)//2, (w+m)//2, (h+m)//2))
    img = img.resize((THUMB_SIZE, THUMB_SIZE), Image.LANCZOS)
    img.save(dst, 'WEBP', quality=QUALITY)

generated = 0

for category in ['Touring_images', 'Club_images']:
    local_dir = f'assets/Photos/{category}'
    thumb_dir = f'assets/Photos/thumbs/{category}'

    # Thumb any local photos first (fast path)
    if os.path.exists(local_dir):
        for fname in sorted(os.listdir(local_dir)):
            if not fname.lower().endswith('.webp'): continue
            dst = os.path.join(thumb_dir, fname)
            if os.path.exists(dst): continue
            make_thumb(os.path.join(local_dir, fname), dst)
            generated += 1

    # Find R2 photos that still need thumbs
    try:
        r2_all   = set(subprocess.check_output(['./rclone','lsf',f'r2:johnstone-cycling/{category}'],stderr=subprocess.DEVNULL).decode().split())
        r2_thumbs= set(subprocess.check_output(['./rclone','lsf',f'r2:johnstone-cycling/thumbs/{category}'],stderr=subprocess.DEVNULL).decode().split())
    except Exception as e:
        print(f'  Warning: could not list R2 files ({e}). Skipping R2 thumb check.')
        r2_all, r2_thumbs = set(), set()

    local_thumbs = set(os.listdir(thumb_dir)) if os.path.exists(thumb_dir) else set()
    need = [f for f in r2_all if f.endswith('.webp') and f not in r2_thumbs and f not in local_thumbs]

    if need:
        print(f'  {len(need)} {category} photos on R2 need thumbnails — downloading...')
        tmp = f'/tmp/jc_thumb_{category}'
        os.makedirs(tmp, exist_ok=True)

        # Write filelist and batch-download
        filelist = f'/tmp/jc_need_{category}.txt'
        with open(filelist, 'w') as f: f.write('\n'.join(need))
        subprocess.run(['./rclone','copy',f'r2:johnstone-cycling/{category}/',tmp,
                        '--files-from', filelist,'--transfers','8','--progress'], check=True)

        for fname in need:
            src = os.path.join(tmp, fname)
            if not os.path.exists(src): continue
            make_thumb(src, os.path.join(thumb_dir, fname))
            os.remove(src)
            generated += 1

        # Clean up
        try: os.rmdir(tmp)
        except: pass
        os.remove(filelist)

print(f'  {generated} new thumbnails generated.')
PYEOF

# ── Upload ───────────────────────────────────────────────────────

echo "Step 6/7: Uploading to R2..."
for category in Touring_images Club_images; do
    if [ -d "assets/Photos/$category" ]; then
        echo "  Uploading $category..."
        $RCLONE copy "assets/Photos/$category/" "r2:$R2_BUCKET/$category/" \
            --include "*.webp" --transfers 8 --progress
    fi
done
if [ -d "assets/Photos/thumbs" ]; then
    echo "  Uploading thumbnails..."
    $RCLONE copy assets/Photos/thumbs/ "r2:$R2_BUCKET/thumbs/" --transfers 8 --progress
fi

# ── JSON ─────────────────────────────────────────────────────────

echo "Step 7/7: Updating photo index and deploying..."
python3 << 'PYEOF'
import os, json
from PIL import Image
from PIL.ExifTags import TAGS, GPSTAGS
import pillow_heif
pillow_heif.register_heif_opener()

R2_PUBLIC = 'https://pub-ae8df0260aa04fb1a08eafd3a8e08737.r2.dev'

def get_gps(fpath):
    try:
        img = Image.open(fpath)
        exif = img._getexif()
        if not exif: return None
        gps = {}
        for tag, val in exif.items():
            if TAGS.get(tag) == 'GPSInfo':
                for k, v in val.items(): gps[GPSTAGS.get(k, k)] = v
        if not gps: return None
        def dec(dms, ref):
            d,m,s = dms
            v = float(d)+float(m)/60+float(s)/3600
            return round(-v if ref in ['S','W'] else v, 6)
        return dec(gps['GPSLatitude'],gps['GPSLatitudeRef']), dec(gps['GPSLongitude'],gps['GPSLongitudeRef'])
    except: return None

def update_index(json_file, category):
    # Load existing entries keyed by filename (preserves GPS for R2-only photos)
    existing = {}
    if os.path.exists(json_file):
        for e in json.load(open(json_file)):
            fname = os.path.basename(e['path'])
            e['thumb'] = f'{R2_PUBLIC}/thumbs/{category}/{fname}'
            existing[fname] = e

    # Merge in any new local photos
    local_dir = f'assets/Photos/{category}'
    new_count = 0
    if os.path.exists(local_dir):
        for fname in sorted(os.listdir(local_dir)):
            if not fname.lower().endswith('.webp') or fname in existing: continue
            coords = get_gps(os.path.join(local_dir, fname))
            if coords:
                existing[fname] = {
                    'path':  f'{R2_PUBLIC}/{category}/{fname}',
                    'thumb': f'{R2_PUBLIC}/thumbs/{category}/{fname}',
                    'lat': coords[0], 'lon': coords[1]
                }
                new_count += 1

    with open(json_file, 'w') as f:
        json.dump(list(existing.values()), f)
    status = f'+{new_count} new' if new_count else 'no new photos'
    print(f'  {json_file}: {len(existing)} entries ({status})')

update_index('touring_photos.json', 'Touring_images')
update_index('club_photos.json', 'Club_images')
PYEOF

# Commit and push
git add routes.geojson touring_photos.json club_photos.json
if git diff --cached --quiet; then
    echo "  No data changes to commit."
else
    git commit -m "Update routes and photo index"
fi
git push origin main

echo ""
echo "✓ Done! Site will update in ~1 minute at johnstonecycling.com"
echo ""
