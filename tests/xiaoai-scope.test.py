"""
[INPUT]: 冻结家庭/OH2的授权策略与虚拟身份；不连接真实设备。
[OUTPUT]: 验证家庭、账号、设备替换及未知动作在网络前被拒绝；冻结范围与扫码暂存的连接状态须经过真实固定家庭接口。
[POS]: 音箱权限回归；独立于业务回复测试，覆盖默认拒绝边界。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import copy
import hashlib
from pathlib import Path
import sys
import unittest
from unittest.mock import patch, AsyncMock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/xiaoai'))
import scope
import speaker

class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.lock = dict(version=1, account=hashlib.sha256(b'123').hexdigest(),
                         homeID='one', deviceID='speaker-one', miotDID='111', hardware='OH2')
        self.config = dict(self.lock)
        self.home = dict(homeID='one', account=self.lock['account'])
    def test_identity(self):
        scope.validate(self.lock, self.config, self.home, {'userId':'123'})
        for key in scope.IDENTITY:
            with self.subTest(key=key), self.assertRaises(PermissionError):
                scope.validate(self.lock, {**self.config,key:'other'}, self.home, {'userId':'123'})
        for home, auth in [({**self.home,'homeID':'other'}, {'userId':'123'}),
                            (self.home, {'userId':'456'})]:
            with self.assertRaises(PermissionError):
                scope.validate(self.lock,self.config,home,auth)
    def test_actions(self):
        good = dict(params=dict(did='111',siid=5,aiid=3,**{'in':['hello']}))
        scope.guard_miot(self.lock, '/miotspec/action', good)
        for key,value in [('did','other'),('siid',True),('aiid',1),('in',['a','b'])]:
            bad=copy.deepcopy(good);bad['params'][key]=value
            with self.assertRaises(PermissionError):
                scope.guard_miot(self.lock,'/miotspec/action',bad)
    def test_properties(self):
        good=dict(params=[dict(did='111',siid=5,piid=3,value=True)])
        scope.guard_miot(self.lock,'/miotspec/prop/set',good)
        for key,value in [('did','other'),('piid',2),('value',1),('value',False)]:
            bad=copy.deepcopy(good);bad['params'][0][key]=value
            with self.assertRaises(PermissionError):
                scope.guard_miot(self.lock,'/miotspec/prop/set',bad)
    def test_mina(self):
        good=dict(deviceId='speaker-one',path='mediaplayer',method='player_play_music')
        scope.guard_mina(self.lock,'/remote/ubus',good)
        for uri,data in [('/admin/v2/device_list',{}),('/remote/ubus',{**good,'deviceId':'other'}),
                         ('/remote/ubus',{**good,'method':'other'})]:
            with self.assertRaises(PermissionError):scope.guard_mina(self.lock,uri,data)
    def test_membership(self):
        row=dict(did='111',home_id='one',model='xiaomi.wifispeaker.oh2')
        scope.member_rows(self.lock,[row])
        for rows in [[],[row,row],[{**row,'home_id':'other'}],[{**row,'model':'other'}]]:
            with self.assertRaises(PermissionError):scope.member_rows(self.lock,rows)
    def test_membership_uses_only_fixed_home_without_login_preflight(self):
        from types import SimpleNamespace
        calls = []
        class FakeAPI:
            def __init__(self, path):
                self.session = SimpleNamespace(request=lambda *a, **kw: None)
                self.auth_data = {'userId':'123'}
            def _request(self, uri, data, refresh_token=True):
                if refresh_token:
                    raise AssertionError("Unexpected account preflight/login")
                calls.append((uri,data))
                return [dict(did='111',home_id='one',model='xiaomi.wifispeaker.oh2')]
            def get_devices_list(self, home_id):
                self._get_home_owner(home_id)
                return self._request('/home/home_device_list', {'home_id':home_id})
        with patch.dict(sys.modules, {'mijiaAPI':SimpleNamespace(mijiaAPI=FakeAPI)}), patch.object(scope,'local',return_value=self.lock), patch.object(scope,'private_json',return_value={'userId':'123'}):
            scope.check_member()
        self.assertEqual(calls,[('/home/home_device_list',{'home_id':'one'})])

    def test_transport_denies_before_network(self):
        import asyncio
        transport = speaker.MiIOService(object())
        with patch.object(scope,'local',return_value=self.lock), patch.object(scope,'verify_member',new_callable=AsyncMock) as verify:
            with self.assertRaises(PermissionError):
                asyncio.run(transport.miio_request('/miotspec/action', {'params':{'did':'other'}}))
            verify.assert_not_awaited()

class FrozenBridgeTests(unittest.TestCase):
    def test_direct_helper_rejects_cross_home_before_sdk(self):
        import importlib.util, tempfile, json, os, stat
        spec=importlib.util.spec_from_file_location('locked_mijia',Path(__file__).resolve().parents[1]/'scripts/mijia-bridge.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            auth=Path(tmp)/'auth.json'; auth.write_text(json.dumps({'userId':'123'}))
            lock=Path(tmp)/'scope-lock.json'
            lock.write_text(json.dumps(dict(version=1,homeID='one',homeName='Test',account=hashlib.sha256(b'123').hexdigest())))
            lock.chmod(0o600);os.chflags(lock,stat.UF_IMMUTABLE)
            try:
                for request in [dict(operation='list_devices',home_id='other'),
                                dict(operation='prepare',request=dict(operation='set_property',device='x',property='2.1',value=True,home_id='other'))]:
                    with patch.object(module,'load_sdk') as sdk:
                        result=module.envelope(request,auth)
                        self.assertFalse(result['ok']);self.assertEqual(result['error']['kind'],'scope');sdk.assert_not_called()
                request=dict(operation='list_devices')
                module.frozen_home(request,auth);self.assertEqual(request['home_id'],'one')
                from types import SimpleNamespace
                class FixedHomeAPI:
                    auth_data = {'userId':'123'}
                    def __init__(self, expired):
                        self.expired, self.calls = expired, []
                    def get_homes_list(self):
                        raise AssertionError('Account-wide home discovery forbidden')
                    def get_devices_list(self, home_id):
                        self.calls.append(home_id)
                        if self.expired:
                            raise module.BridgeError('auth','Credential expired')
                        return []
                for expired in [False,True]:
                    api = FixedHomeAPI(expired)
                    result = module.envelope({'operation':'status'},auth,sdk=SimpleNamespace(),api=api)
                    self.assertEqual(api.calls,['one'])
                    self.assertEqual(result['ok'],not expired)
                    if expired:self.assertEqual(result['error']['kind'],'auth')
                    else:self.assertTrue(result['data']['authenticated'])
                staging=Path(tmp)/'login-12345678-1234-1234-1234-123456789abc'
                staging.mkdir();staged_auth=staging/'auth.json';staged_auth.write_text(auth.read_text())
                api=FixedHomeAPI(False)
                result=module.envelope({'operation':'status'},staged_auth,sdk=SimpleNamespace(),api=api)
                self.assertTrue(result['ok']);self.assertEqual(api.calls,['one'])
                with self.assertRaises(module.BridgeError):
                    module.frozen_home({'operation':'list_devices','home_id':'other'},staged_auth)
                auth.write_text(json.dumps({'userId':'456'}))
                with self.assertRaises(module.BridgeError):module.frozen_home(request,auth)
            finally:os.chflags(lock,0)

if __name__=='__main__':unittest.main()
