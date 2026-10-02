"""Codex Runway MCP Apps adapter. The native process is the sole state writer.
No credentials, native preferences, Analytics archives or forecasts are read here.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

ROOT = Path(__file__).resolve().parent
URI = 'ui://codex-runway/hub-v1.html'
SOCKET = Path.home() / 'Library/Application Support/Codex Runway/Bridge/hub-v1.sock'
MAX_REPLY = 4_194_304
ACTIONS = ['refresh', 'refreshSaved', 'refreshProfile', 'refreshAnalytics', 'add', 'save', 'switch', 'forget', 'recover', 'reloadLogins', 'cancel', 'openNative', 'enable', 'move', 'display', 'chooseBackupFolder', 'backupEnabled', 'backupRetention', 'backupNow']
READ_SCHEMA = {'type': 'object', 'properties': {'section': {'enum': ['overview', 'settings', 'history', 'analytics']}, 'accountID': {'type': 'string', 'maxLength': 36}, 'days': {'enum': [7, 30, 365]}}, 'additionalProperties': False}
COMMAND_SCHEMA = {'type': 'object', 'properties': {
    'requestID': {'type': 'string', 'format': 'uuid'}, 'action': {'enum': ACTIONS},
    'accountID': {'type': 'string', 'maxLength': 36}, 'loginID': {'type': 'string', 'maxLength': 256},
    'enabled': {'type': 'boolean'}, 'offset': {'enum': [-1, 1]},
    'range': {'enum': ['overview', 'hour', 'sixHours', 'day', 'threeDays', 'week']},
    'mode': {'enum': ['graph', 'table']}, 'percent': {'type': 'boolean'},
    'keepDailyDays': {'type': 'integer', 'minimum': 1, 'maximum': 365}},
    'required': ['requestID', 'action'], 'additionalProperties': False}
TOOLS = [
    {'name': 'open_codex_runway', 'title': 'Codex Runway', 'description': 'Open the local Runway account, capacity, History and Analytics hub.',
     'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
     'annotations': {'readOnlyHint': True, 'openWorldHint': False},
     '_meta': {'ui': {'resourceUri': URI}, 'openai/ui': {'entrypoints': [{'type': 'global'}]},
               'openai/ui.entrypoints': [{'type': 'global'}]}},
    {'name': 'runway_snapshot', 'description': 'Read saved native Runway state. Never triggers upstream refresh.', 'inputSchema': READ_SCHEMA,
     'annotations': {'readOnlyHint': True, 'openWorldHint': False}, '_meta': {'ui': {'visibility': ['app']}}},
    {'name': 'runway_command', 'description': 'An explicit user action delegated to native Runway. Returns an operation receipt; may refresh OpenAI data or restart Codex for a requested switch.',
     'inputSchema': COMMAND_SCHEMA, 'annotations': {'readOnlyHint': False, 'destructiveHint': True, 'openWorldHint': True},
     '_meta': {'ui': {'visibility': ['app']}}},
]


def validate(args, schema):
    if not isinstance(args, dict) or not set(args) <= set(schema['properties']): raise ValueError('Invalid arguments.')
    if any(key not in args for key in schema.get('required', [])): raise ValueError('Missing arguments.')
    for key, value in args.items():
        rule = schema['properties'][key]
        if 'enum' in rule and (type(value) is bool or value not in rule['enum']): raise ValueError('Invalid choice.')
        kind = rule.get('type')
        if kind == 'string' and (not isinstance(value, str) or len(value) > rule.get('maxLength', 256)): raise ValueError('Invalid identifier.')
        if kind == 'boolean' and type(value) is not bool: raise ValueError('Invalid boolean.')
        if kind == 'integer' and (type(value) is not int or not rule['minimum'] <= value <= rule['maximum']): raise ValueError('Invalid number.')
    for key in ['requestID', 'accountID']:
        if key in args:
            try: uuid.UUID(args[key])
            except (ValueError, TypeError, AttributeError): raise ValueError('Invalid identifier.') from None
    # Native decoding revalidates identifiers and current-state eligibility.


def unavailable():
    return {'version': 1, 'available': False, 'message': 'Runway is unavailable. Open the native app, then reload this hub. No upstream request was made.'}


def bridge(request, path=SOCKET):
    wire = json.dumps({'version': 1, **request}, separators=(',', ':')).encode() + b'\n'
    if len(wire) > 16_384: raise ValueError('Request too large.')
    try:
        parent = path.parent.lstat()
        entry = path.lstat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            raise ValueError('Unsafe Runway bridge directory.')
        if not stat.S_ISSOCK(entry.st_mode) or entry.st_uid != os.getuid() or entry.st_mode & 0o077:
            raise ValueError('Unsafe Runway bridge socket.')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(6)
            client.connect(str(path))
            client.sendall(wire)
            chunks = bytearray()
            while len(chunks) <= MAX_REPLY:
                chunk = client.recv(65536)
                if not chunk: raise ValueError('Runway bridge disconnected. Reload to check operation status before retrying.')
                chunks.extend(chunk)
                if b'\n' in chunk:
                    if not chunks.endswith(b'\n') or chunks.count(b'\n') != 1: raise ValueError('Invalid Runway frame.')
                    result = json.loads(chunks[:-1])
                    if result.get('version') != 1: raise ValueError('Unsupported Runway contract.')
                    return result
            raise ValueError('Runway reply too large.')
    except (FileNotFoundError, ConnectionRefusedError): return unavailable()
    except (TimeoutError, OSError): raise ValueError('Runway did not respond. Reload to check operation status before retrying.') from None


def html():
    return (ROOT / 'web/index.html').read_text().replace('/* STYLE */', (ROOT / 'web/style.css').read_text()).replace('/* BUNDLE */', (ROOT / 'web/bundle.js').read_text().replace('</script', '<\\/script'))


def call(name, args):
    if name == 'open_codex_runway':
        validate(args, {'properties': {}})
        return bridge({'kind': 'snapshot', 'section': 'overview'})
    if name == 'runway_snapshot':
        validate(args, READ_SCHEMA)
        return bridge({'kind': 'snapshot', **args})
    if name == 'runway_command':
        validate(args, COMMAND_SCHEMA)
        result = bridge({'kind': 'command', **args})
        if result.get('available') is False and args['action'] == 'openNative':
            # A user explicitly requested opening Runway. No switches or Codex
            # restarts are performed by this adapter, even when unavailable.
            subprocess.run(['/usr/bin/open', '/Applications/Codex Runway.app'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return {'version': 1, 'accepted': True, 'message': 'Opening native Runway. Reload the hub shortly.'}
        if result.get('available') is False: raise ValueError(result['message'])
        return result
    raise ValueError('Unknown tool.')


def rpc(method, params):
    if method == 'initialize': return {'protocolVersion': params.get('protocolVersion', '2024-11-05'), 'capabilities': {'tools': {}, 'resources': {}}, 'serverInfo': {'name': 'codex-runway', 'version': '1.0.0'}}
    if method == 'ping': return {}
    if method == 'tools/list': return {'tools': TOOLS}
    if method == 'resources/list': return {'resources': [{'uri': URI, 'name': 'Codex Runway', 'mimeType': 'text/html;profile=mcp-app'}]}
    if method == 'resources/templates/list': return {'resourceTemplates': []}
    if method == 'prompts/list': return {'prompts': []}
    if method == 'resources/read':
        if params.get('uri') != URI: raise ValueError('Unknown resource.')
        return {'contents': [{'uri': URI, 'mimeType': 'text/html;profile=mcp-app', 'text': html(), '_meta': {'ui': {'prefersBorder': False, 'csp': {'connectDomains': [], 'resourceDomains': []}}}}]}
    if method == 'tools/call':
        try:
            result = call(params.get('name'), params.get('arguments', {}))
            if 'error' in result: raise ValueError(result['error'])
            return {'content': [{'type': 'text', 'text': 'Codex Runway local hub.'}], 'structuredContent': result}
        except Exception as error:
            # Never print native payloads or tracebacks into MCP logs.
            message = str(error) if isinstance(error, ValueError) else 'Runway request failed. Open native Runway for details.'
            return {'isError': True, 'content': [{'type': 'text', 'text': message}]}
    raise ValueError('Unsupported method.')


def stdio():
    for line in sys.stdin:
        try:
            if len(line) > 32768: continue
            request = json.loads(line)
            if 'id' not in request: continue
            try: response = {'jsonrpc': '2.0', 'id': request['id'], 'result': rpc(request['method'], request.get('params', {}))}
            except Exception: response = {'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32602, 'message': 'Invalid Runway MCP request.'}}
            print(json.dumps(response, separators=(',', ':')), flush=True)
        except (ValueError, KeyError, TypeError): continue


class Preview(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, status, value, mime='application/json'):
        data = value.encode() if isinstance(value, str) else json.dumps(value).encode()
        self.send_response(status)
        for key, val in [('Content-Type', mime), ('Content-Length', str(len(data))), ('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff')]: self.send_header(key, val)
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.headers.get('Host') not in [f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}']: return self.reply(403, {'error': 'Invalid host.'})
        url = urlsplit(self.path)
        if url.path == '/': return self.reply(200, html(), 'text/html; charset=utf-8')
        if url.path == '/api/snapshot':
            if self.server.fixture:
                result = json.loads(self.server.fixture.read_text())
                result['preview'] = True
                account_id = parse_qs(url.query).get('accountID', [''])[0]
                if account_id:
                    result['history'] = result.get('fixtureHistoryByAccount', {}).get(account_id, {'available': False})
                    analytics = result.get('analytics', {})
                    analytics = result.get('fixtureAnalyticsByAccount', {}).get(account_id, {'accounts': [], 'sources': []})
                    result['analytics'] = analytics
                    analytics['savedCount'] = len(analytics['accounts']); analytics['accountCount'] = 1
                result.pop('fixtureHistoryByAccount', None)
                result.pop('fixtureAnalyticsByAccount', None)
                return self.reply(200, result)
            args = {k: v[0] for k, v in parse_qs(url.query).items()}
            if 'days' in args: args['days'] = int(args['days'])
            try:
                validate(args, READ_SCHEMA)
                result = bridge({'kind': 'snapshot', **args}); result['preview'] = True
                account_id = parse_qs(url.query).get('accountID', [''])[0]
                if account_id:
                    result['history'] = result.get('fixtureHistoryByAccount', {}).get(account_id, {'available': False})
                    analytics = result.get('analytics', {})
                    analytics = result.get('fixtureAnalyticsByAccount', {}).get(account_id, {'accounts': [], 'sources': []})
                    result['analytics'] = analytics
                    analytics['savedCount'] = len(analytics['accounts']); analytics['accountCount'] = 1
                result.pop('fixtureHistoryByAccount', None)
                result.pop('fixtureAnalyticsByAccount', None)
                return self.reply(200, result)
            except Exception: return self.reply(503, {'error': 'Runway preview read failed.'})
        return self.reply(404, {'error': 'Not found.'})
    def do_POST(self):
        # Preview cannot perform native mutations, including account switching.
        self.reply(403, {'error': 'Native actions are available in the Codex sidebar or native Runway app.'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--http', action='store_true')
    parser.add_argument('--port', type=int, default=43188)
    parser.add_argument('--fixture', type=Path)
    options = parser.parse_args()
    if options.http:
        server = ThreadingHTTPServer(('127.0.0.1', options.port), Preview)
        server.fixture = options.fixture
        print(f'Runway read-only preview: http://127.0.0.1:{server.server_port}', flush=True)
        server.serve_forever()
    else: stdio()
