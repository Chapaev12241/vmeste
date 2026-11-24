import os, sqlite3, secrets, hashlib, json, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
DB = os.getenv('DATABASE_PATH', 'ryadom.sqlite')
LOCK = threading.Lock()
def connect():
    db = sqlite3.connect(DB)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA foreign_keys=ON')
    return db
def initialize():
    with connect() as db:
        db.executescript('''CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, token TEXT UNIQUE, name TEXT, avatar TEXT, partner TEXT, location TEXT, updated REAL, paused INTEGER DEFAULT 1);
        CREATE TABLE IF NOT EXISTS invites(code TEXT PRIMARY KEY, owner TEXT UNIQUE, expires REAL);
        CREATE TABLE IF NOT EXISTS limits(key TEXT PRIMARY KEY, count INTEGER, reset REAL);''')
def digest(value): return hashlib.sha256(value.encode()).hexdigest()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, code, obj):
        body = json.dumps(obj).encode(); self.send_response(code)
        self.send_header('Content-Type','application/json'); self.send_header('Cache-Control','no-store'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self): self.handle_api()
    def do_POST(self): self.handle_api()
    def handle_api(self):
        try:
            with LOCK, connect() as db:
                now = time.time()
                key = self.client_address[0]
                rate = db.execute('SELECT * FROM limits WHERE key=?',(key,)).fetchone()
                if rate and rate['reset'] > now and rate['count'] >= 180:
                    return self.reply(429, {'error':'Слишком много запросов. Подождите минуту.'})
                db.execute('INSERT INTO limits VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET count=?,reset=?',(key,1,now+60,(rate['count']+1 if rate and rate['reset']>now else 1),(rate['reset'] if rate and rate['reset']>now else now+60)))
                db.commit()
                if self.path == '/health': return self.reply(200, {'ok':True})
                size = int(self.headers.get('Content-Length','0'))
                if size > 200000 or size < 0: return self.reply(413, {'error':'Слишком большой запрос'})
                data = json.loads(self.rfile.read(size)) if size else {}
                if self.path == '/register' and self.command == 'POST':
                    token = secrets.token_urlsafe(32); uid = secrets.token_hex(16)
                    db.execute('INSERT INTO users(id,token,name) VALUES(?,?,?)',(uid,digest(token),'Я'))
                    self.reply(201, {'token':token}); return
                token = self.headers.get('Authorization','').removeprefix('Bearer ')
                me = db.execute('SELECT * FROM users WHERE token=?',(digest(token),)).fetchone()
                if not me: return self.reply(401, {'error':'Нужна авторизация'})
                uid = me['id']
                if self.path == '/state' and self.command == 'GET':
                    partner = db.execute('SELECT * FROM users WHERE id=? AND partner=?',(me['partner'],uid)).fetchone()
                    def profile(row):
                        if not row: return None
                        return dict(name=row['name'],avatar=row['avatar'],paused=bool(row['paused']),location=json.loads(row['location']) if row['location'] and not row['paused'] else None,updated=row['updated'])
                    return self.reply(200, {'me':profile(me),'partner':profile(partner)})
                if self.command != 'POST': return self.reply(404, {'error':'Не найдено'})
                if self.path == '/invite':
                    if me['partner']: return self.reply(409, {'error':'Сначала отключите текущую пару'})
                    code = secrets.token_hex(5).upper()
                    db.execute('DELETE FROM invites WHERE owner=? OR expires<?',(uid,now))
                    db.execute('INSERT INTO invites VALUES(?,?,?)',(digest(code),uid,now+600))
                    self.reply(200, {'code':code,'expires':now+600}); return
                if self.path == '/join':
                    code = str(data.get('code','')).strip().upper()
                    invite = db.execute('SELECT * FROM invites WHERE code=? AND expires>?',(digest(code),now)).fetchone()
                    if not invite or invite['owner']==uid: return self.reply(400, {'error':'Код недействителен или истёк'})
                    owner = db.execute('SELECT * FROM users WHERE id=?',(invite['owner'],)).fetchone()
                    if me['partner'] or owner['partner']: return self.reply(409, {'error':'Один из участников уже в паре'})
                    db.execute('UPDATE users SET partner=? WHERE id=?',(owner['id'],uid)); db.execute('UPDATE users SET partner=? WHERE id=?',(uid,owner['id']))
                    db.execute('DELETE FROM invites WHERE owner IN (?,?)',(uid,owner['id']))
                elif self.path == '/unpair':
                    db.execute('UPDATE users SET partner=NULL,location=NULL,paused=1 WHERE id=? OR (id=? AND partner=?)',(uid,me['partner'],uid))
                    db.execute('DELETE FROM invites WHERE owner=?',(uid,))
                elif self.path == '/profile':
                    name = str(data.get('name','Я')).strip()[:40] or 'Я'
                    avatar = data.get('avatar')
                    if avatar is not None:
                        import base64
                        raw = base64.b64decode(avatar,validate=True)
                        if len(raw)>100000: return self.reply(400, {'error':'Аватарка слишком большая'})
                    db.execute('UPDATE users SET name=?,avatar=? WHERE id=?',(name,avatar,uid))
                elif self.path == '/location':
                    lat, lon, accuracy = float(data['latitude']),float(data['longitude']),float(data['accuracy'])
                    if not (-90<=lat<=90 and -180<=lon<=180 and 0<=accuracy<=100000): raise ValueError()
                    db.execute('UPDATE users SET location=?,updated=?,paused=0 WHERE id=?',(json.dumps(dict(latitude=lat,longitude=lon,accuracy=accuracy)),now,uid))
                elif self.path == '/pause': db.execute('UPDATE users SET paused=1,location=NULL WHERE id=?',(uid,))
                elif self.path == '/delete':
                    db.execute('UPDATE users SET partner=NULL WHERE partner=?',(uid,)); db.execute('DELETE FROM invites WHERE owner=?',(uid,)); db.execute('DELETE FROM users WHERE id=?',(uid,))
                else: return self.reply(404, {'error':'Не найдено'})
                self.reply(200, {'ok':True})
        except (ValueError, KeyError, TypeError): self.reply(400, {'error':'Некорректный запрос'})
        except Exception: self.reply(500, {'error':'Ошибка сервера'})
if __name__ == '__main__':
    initialize(); ThreadingHTTPServer(('0.0.0.0',int(os.getenv('PORT','8080'))),Handler).serve_forever()
