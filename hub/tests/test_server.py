import json
from pathlib import Path
import socket
import stat
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server

class AdapterChecks(unittest.TestCase):
    def test_registration(self):
        tools = server.rpc('tools/list', {})['tools']
        opener = tools[0]
        self.assertEqual(opener['name'], 'open_codex_runway')
        self.assertEqual(opener['_meta']['ui']['resourceUri'], server.URI)
        self.assertEqual(opener['_meta']['openai/ui']['entrypoints'], [{'type': 'global'}])
        self.assertTrue(opener['annotations']['readOnlyHint'])
        for tool in tools[1:]: self.assertEqual(tool['_meta']['ui']['visibility'], ['app'])
        self.assertFalse(tools[2]['annotations']['readOnlyHint'])
        page = server.rpc('resources/read', {'uri': server.URI})['contents'][0]
        self.assertEqual(page['mimeType'], 'text/html;profile=mcp-app')
        self.assertIn('Codex Runway', page['text'])
        self.assertNotIn('/* BUNDLE */', page['text'])
        self.assertNotIn('src="http', page['text'])

    def test_local_metadata(self):
        root = server.ROOT
        manifest = json.loads((root / '.codex-plugin/plugin.json').read_text())
        marketplace = json.loads((root / '.agents/plugins/marketplace.json').read_text())
        self.assertEqual(manifest['name'], marketplace['plugins'][0]['name'])
        config = json.loads((root / '.mcp.json').read_text())['mcpServers']['codex-runway']
        self.assertEqual(Path(config['args'][0]).resolve(), root / 'server.py')

    def test_snapshot_has_no_mutation_or_upstream_side_effect(self):
        with patch.object(server, 'bridge', return_value={'version': 1, 'available': True}) as bridge:
            for name in ['open_codex_runway', 'runway_snapshot']:
                server.call(name, {})
                self.assertEqual(bridge.call_args.args[0]['kind'], 'snapshot')

    def test_validation(self):
        for args in [{'action': 'switch'}, {'requestID': 'id', 'action': 'automaticSwitch'},
                     {'requestID': 'id', 'action': 'switch', 'tokens': 'must-not-pass'},
                     {'requestID': 'id', 'action': 'enable', 'enabled': 1},
                     {'requestID': 'id', 'action': 'display', 'range': 'year'},
                     {'requestID': 'id', 'action': 'move', 'offset': True}]:
            with self.assertRaises(ValueError): server.validate(args, server.COMMAND_SCHEMA)
        with self.assertRaises(ValueError): server.validate({'days': 8}, server.READ_SCHEMA)
        with self.assertRaises(ValueError): server.validate({'accountID': 'x'*200}, server.READ_SCHEMA)

    def test_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            result = server.bridge({'kind': 'snapshot'}, Path(directory) / 'absent.sock')
            self.assertFalse(result['available'])
        with patch.object(server, 'bridge', return_value=server.unavailable()), patch.object(server.subprocess, 'run') as open_app:
            result = server.call('runway_command', {'requestID': '00000000-0000-0000-0000-000000000001', 'action': 'openNative'})
            self.assertTrue(result['accepted'])
            open_app.assert_called_once()
            with self.assertRaises(ValueError): server.call('runway_command', {'requestID': '00000000-0000-0000-0000-000000000001', 'action': 'switch', 'loginID': 'login'})
            self.assertEqual(open_app.call_count, 1)

    def test_private_socket_roundtrip_and_no_auth(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'hub.sock'
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path)); path.chmod(0o600); listener.listen()
                requests = []
                def serve():
                    client, _ = listener.accept()
                    with client:
                        wire = client.recv(16384)
                        requests.append(json.loads(wire))
                        client.sendall(b'{"version":1,"available":true}\n')
                thread = threading.Thread(target=serve); thread.start()
                result = server.bridge({'kind': 'snapshot', 'section': 'analytics'}, path)
                thread.join(timeout=2)
                self.assertTrue(result['available'])
                self.assertEqual(requests, [{'version': 1, 'kind': 'snapshot', 'section': 'analytics'}])
                path.chmod(0o666)
                with self.assertRaisesRegex(ValueError, 'Unsafe'): server.bridge({'kind': 'snapshot'}, path)

    def test_bridge_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            target = path / 'target'; target.mkdir(mode=0o700)
            link = path / 'link'; link.symlink_to(target, target_is_directory=True)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(target / 'hub.sock')); (target / 'hub.sock').chmod(0o600)
                with self.assertRaisesRegex(ValueError, 'Unsafe'): server.bridge({'kind': 'snapshot'}, link / 'hub.sock')

    def test_errors_are_generic_not_payloads(self):
        with patch.object(server, 'call', side_effect=RuntimeError('secret-token')):
            value = server.rpc('tools/call', {'name': 'runway_snapshot'})
            self.assertTrue(value['isError'])
            self.assertNotIn('secret-token', json.dumps(value))

if __name__ == '__main__': unittest.main()
