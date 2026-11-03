import importlib.util
import json
import tempfile
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sbx', ROOT / 'sbx.py')
sbx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sbx)

try:
    import yaml
except ImportError:
    yaml = None


class GeneratedProfilesTest(unittest.TestCase):
    def setUp(self):
        self.dev = {
            'uuid': str(uuid.uuid4()),
            'hy2_password': 'hy2-test-secret-0123456789'
        }
        self.cfg = {
            'server': {
                'address': '203.0.113.10',
                'domain': 'node.example.com',
                'reality_sni': 'www.microsoft.com',
                'reality_private_key': 'private-key-placeholder',
                'reality_public_key': 'public-key-placeholder',
                'reality_short_id': '0123456789abcdef',
                'vless_port': 443,
                'hy2_port': 443,
                'hy2_enabled': True,
                'certificate_path': '/etc/letsencrypt/live/node.example.com/fullchain.pem',
                'private_key_path': '/etc/letsencrypt/live/node.example.com/privkey.pem'
            },
            'devices': {'windows-pc': self.dev}
        }

    def test_server_config_has_tcp_and_udp_inbounds(self):
        cfg = sbx.make_config(self.cfg)
        self.assertEqual([x['type'] for x in cfg['inbounds']], ['vless', 'hysteria2'])
        self.assertEqual(cfg['inbounds'][0]['users'][0]['uuid'], self.dev['uuid'])
        self.assertEqual(cfg['inbounds'][1]['users'][0]['password'], self.dev['hy2_password'])
        self.assertEqual(cfg['inbounds'][0]['listen_port'], cfg['inbounds'][1]['listen_port'])

    def test_sing_box_client_profile_contains_no_server_private_key(self):
        profile = sbx.make_singbox_profile(self.cfg, self.dev, 'windows-pc')
        encoded = json.dumps(profile)
        self.assertIn('VLESS-REALITY', encoded)
        self.assertIn('Hysteria2', encoded)
        self.assertNotIn('reality_private_key', encoded)
        self.assertNotIn('private_key', encoded)
        self.assertEqual(profile['inbounds'][0]['type'], 'tun')

    def test_mihomo_yaml_parses_and_has_two_proxies(self):
        if yaml is None:
            self.skipTest('PyYAML is optional; install it to run YAML validation')
        doc = yaml.safe_load(sbx.make_clash_yaml(self.cfg, self.dev, 'windows-pc'))
        self.assertEqual(len(doc['proxies']), 2)
        self.assertEqual(doc['proxies'][0]['type'], 'vless')
        self.assertEqual(doc['proxies'][1]['type'], 'hysteria2')
        self.assertFalse(doc['proxies'][1]['skip-cert-verify'])


    def test_export_bundle_contains_client_files_and_is_private(self):
        with tempfile.TemporaryDirectory() as td:
            old = sbx.EXPORT_DIR
            try:
                sbx.EXPORT_DIR = Path(td)
                path = sbx.export_device(self.cfg, 'windows-pc')
                bundle = path / 'windows-pc.zip'
                self.assertTrue(bundle.exists())
                self.assertEqual(bundle.stat().st_mode & 0o777, 0o600)
                import zipfile
                with zipfile.ZipFile(bundle) as zf:
                    names = set(zf.namelist())
                self.assertIn('nodes.txt', names)
                self.assertIn('mihomo.yaml', names)
                self.assertIn('sing-box.json', names)
            finally:
                sbx.EXPORT_DIR = old

    def test_vless_and_hysteria_uris_have_device_label(self):
        vless = sbx.create_vless_uri(self.cfg, self.dev, 'windows-pc')
        hy2 = sbx.create_hy2_uri(self.cfg, self.dev, 'windows-pc')
        self.assertTrue(vless.startswith('vless://'))
        self.assertIn('flow=xtls-rprx-vision', vless)
        self.assertIn('pbk=public-key-placeholder', vless)
        self.assertTrue(hy2.startswith('hysteria2://'))
        self.assertIn('sni=node.example.com', hy2)
        self.assertIn('203.0.113.10:443', hy2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
