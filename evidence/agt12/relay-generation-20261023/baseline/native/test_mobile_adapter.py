import copy
import json
import threading
import unittest
from follower import Follower
from mobile_adapter import Adapter, version

class Stub:
    def __init__(self):
        self.request={'id': 7, 'method':'item/tool/requestUserInput', 'params': {'threadId':'t', 'turnId':'turn', 'questions':[]}}
        self.owner='owner'; self.calls=[]; self.fail=False
    def follow(self, thread, host_id):
        self.calls.append(('follow', thread, host_id))
        return {'valid':True,'threadId':thread,'hostId':host_id,'ownerClientId':self.owner,'requests': [] if self.request is None else [copy.deepcopy(self.request)]}
    def respond(self,*args,**kw):
        self.calls.append(('respond',args,kw))
        if self.fail: raise TimeoutError()
        return {'result':{}}
    def native_observation(self,*args,**kw):
        return getattr(self, 'native', {})

class Tests(unittest.TestCase):
    def setUp(self):
        self.stub=Stub(); self.a=Adapter(self.stub,['t'])
        self.row=self.a.handle('list',{})['data'][0]
        self.body={k:self.row[k] for k in ('receipt_id','request_id','request_version')}
        self.body['response']={'id':7,'result':{'answers':{}}}
    def call(self,operation,body=None):
        return self.a.line({'id':'outer','operation':operation,'body':self.body if body is None else body})
    def test_raw_envelope_and_fresh(self):
        out=self.call('read'); self.assertEqual(out['id'],'outer')
        self.assertEqual(json.loads(out['payload_json'])['request_id'],7)
        self.assertEqual(len(self.stub.calls),2)
    def test_owner_typed_id_version_and_generation(self):
        self.assertIn('error',self.call('read',{**self.body,'request_id':'7'}))
        self.stub.owner='different'; self.assertIn('error',self.call('respond'))
        self.stub.owner='owner'; self.stub.request['params']['command']='changed'
        self.assertEqual(self.call('read')['error']['code'],'NATIVE_REQUEST_CHANGED')
        other=Adapter(self.stub,['t']); self.assertIn('error',other.line({'operation':'read','body':self.body}))
        self.assertFalse(any(x[0]=='respond' for x in self.stub.calls))
    def test_disappearance_is_not_resolution(self):
        self.stub.request=None
        result=self.call('read'); self.assertEqual(result['error']['code'],'NATIVE_REQUEST_NOT_PENDING')
        self.assertNotIn('native_resolution',json.dumps(result))
    def test_response_raw_and_duplicate_fenced(self):
        result=json.loads(self.call('respond')['payload_json'])
        self.assertTrue(result['response_submitted']); self.assertNotIn('native_resolution',result)
        self.assertEqual(self.stub.calls[-1][1][2],{'answers':{}})
        self.assertEqual(self.stub.calls[-1][2]['expected_request'],self.stub.request)
        self.assertIn('error',self.call('respond'))
    def test_unknown_never_retries(self):
        self.stub.fail=True
        self.assertEqual(self.call('respond')['error']['code'],'NATIVE_RESPONSE_OUTCOME_UNKNOWN')
        self.call('respond'); self.assertEqual(sum(x[0]=='respond' for x in self.stub.calls),1)
    def test_error_and_unavailable_option_rejected(self):
        for response in ({'id':7,'error':{'code':-1}}, {'id':'7','result':{'answers':{}}}):
            self.assertIn('error',self.call('respond',{**self.body,'response':response}))
        self.assertFalse(any(x[0]=='respond' for x in self.stub.calls))
    def test_non_user_input_not_writable(self):
        self.stub.request['method']='item/commandExecution/requestApproval'
        self.assertFalse(self.a.handle('list',{})['data'][0]['response_available'])

    def test_large_id_not_writable(self):
        self.stub.request['id']=2**53+1
        row=self.a.handle('list',{})['data'][0]
        self.assertFalse(row['response_available'])
    def test_follower_checks_full_version_under_lock(self):
        f=Follower.__new__(Follower); f.lock=threading.RLock(); f.closed=False; f.attempted=set()
        f.views={('local','t'):{'valid':True,'ownerClientId':'owner','state':{'requests':[self.stub.request]}}}
        f.rpc=lambda *a,**kw: self.fail('must not send')
        stale=copy.deepcopy(self.stub.request); stale['params']['extra']=True
        with self.assertRaisesRegex(ValueError,'request-version-changed'):
            f.respond('t',7,{'answers':{}},'owner',expected_request=stale)
        self.assertEqual(f.attempted,set())

if __name__=='__main__': unittest.main()
