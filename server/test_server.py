import unittest, tempfile, threading, json, urllib.request, urllib.error
import server
class PairTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(); server.DB=cls.tmp.name+'/db'; server.initialize()
        cls.http=server.ThreadingHTTPServer(('127.0.0.1',0),server.Handler)
        threading.Thread(target=cls.http.serve_forever,daemon=True).start()
        cls.url='http://127.0.0.1:'+str(cls.http.server_port)
    @classmethod
    def tearDownClass(cls): cls.http.shutdown(); cls.http.server_close(); cls.tmp.cleanup()
    def call(self,path,token=None,body=None):
        req=urllib.request.Request(self.url+path,data=json.dumps(body).encode() if body is not None else None,headers={'Authorization':'Bearer '+(token or ''),'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req) as r: return r.status,json.load(r)
        except urllib.error.HTTPError as e: return e.code,json.load(e)
    def test_pair_lifecycle(self):
        a=self.call('/register',body={})[1]['token']; b=self.call('/register',body={})[1]['token']; c=self.call('/register',body={})[1]['token']
        self.assertEqual(self.call('/state')[0],401)
        code=self.call('/invite',a,{})[1]['code']
        self.assertEqual(self.call('/join',b,{'code':code})[0],200)
        self.assertEqual(self.call('/join',c,{'code':code})[0],400)
        self.assertEqual(self.call('/location',a,{'latitude':51,'longitude':142,'accuracy':90})[0],200)
        self.assertEqual(self.call('/state',b)[1]['partner']['location']['latitude'],51)
        self.assertIsNone(self.call('/state',c)[1]['partner'])
        self.assertEqual(self.call('/location',a,{'latitude':999,'longitude':142,'accuracy':90})[0],400)
        self.call('/pause',a,{})
        self.assertIsNone(self.call('/state',b)[1]['partner']['location'])
        self.call('/unpair',a,{})
        self.assertIsNone(self.call('/state',b)[1]['partner'])
        self.call('/delete',a,{})
        self.assertEqual(self.call('/state',a)[0],401)
if __name__=='__main__': unittest.main()
