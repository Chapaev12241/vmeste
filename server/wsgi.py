"""WSGI entry point for hosts such as PythonAnywhere. Uses the same tested API."""
import os
from http import HTTPStatus
from pathlib import Path
import server

server.DB = os.environ.get('DATABASE_PATH', str(Path.home() / 'ryadom-data' / 'ryadom.sqlite'))
Path(server.DB).parent.mkdir(parents=True, exist_ok=True)
server.initialize()

class Request:
    handle_api = server.Handler.handle_api
    def __init__(self, environ):
        self.path = environ.get('PATH_INFO', '/')
        self.command = environ.get('REQUEST_METHOD', 'GET')
        self.headers = {'Authorization': environ.get('HTTP_AUTHORIZATION', ''), 'Content-Length': environ.get('CONTENT_LENGTH') or '0'}
        self.rfile = environ['wsgi.input']
        self.client_address = (environ.get('REMOTE_ADDR', ''), 0)
        self.result = None
    def reply(self, code, obj):
        import json
        body = json.dumps(obj).encode('utf-8')
        self.result = (f'{code} {HTTPStatus(code).phrase}', [('Content-Type', 'application/json'), ('Content-Length', str(len(body))), ('Cache-Control', 'no-store')], [body])

def application(environ, start_response):
    request = Request(environ)
    request.handle_api()
    status, headers, body = request.result
    start_response(status, headers)
    return body
