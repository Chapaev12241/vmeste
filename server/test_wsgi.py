import unittest, tempfile, os, io, json, importlib
import server
class WSGITest(unittest.TestCase):
    def test_registration_and_authentication(self):
        original = server.DB
        previous = os.environ.get('DATABASE_PATH')
        try:
            with tempfile.TemporaryDirectory() as folder:
                os.environ['DATABASE_PATH'] = folder + '/test.sqlite'
                import wsgi
                importlib.reload(wsgi)
                def call(path, method='GET', data=None, token=''):
                    raw = json.dumps(data).encode() if data is not None else b''
                    statuses=[]
                    body=wsgi.application({'PATH_INFO':path,'REQUEST_METHOD':method,'CONTENT_LENGTH':str(len(raw)),'HTTP_AUTHORIZATION':'Bearer '+token,'wsgi.input':io.BytesIO(raw),'REMOTE_ADDR':'test'},lambda status,headers:statuses.append(status))
                    return statuses[0],json.loads(b''.join(body))
                status, registration=call('/register','POST',{})
                self.assertEqual(status,'201 Created')
                self.assertEqual(call('/state')[0],'401 Unauthorized')
                status, state=call('/state',token=registration['token'])
                self.assertEqual(status,'200 OK')
                self.assertIsNone(state['partner'])
        finally:
            server.DB=original
            if previous is None: os.environ.pop('DATABASE_PATH',None)
            else: os.environ['DATABASE_PATH']=previous
