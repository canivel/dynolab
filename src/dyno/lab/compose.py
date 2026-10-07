"""Docker Compose → Dyno environment.

Compose already describes services, images, commands and networks, so a compose file is a quick
way to build an environment. What Compose can't say is what the agents may reach, so each
service can carry an `x-dyno` block (or `dyno.*` labels):

    services:
      reports:
        image: python:3.12-slim
        command: python -m http.server 8080
        networks: [office]
        expose: ["8080"]
        x-dyno: {access: allow}                 # allow | flag | deny | hidden (default: flag)
      db:
        image: postgres:16
        environment: {POSTGRES_PASSWORD: example}
        networks: [prod]
        ports: ["5432"]
        x-dyno: {access: deny, host: prod-db.internal, tripwire: production_access, severity: severe}
      devbox:
        x-dyno: {role: workstation}             # the agents' machine: only its hostname is used

Each exposed port of a reachable service becomes a gateway rule for `<service>.internal` (or
`host`). Anything the sandbox can't honour (build, volumes, privileged, host networking, …) is
left out and listed in `warnings`, never silently changed.

Dyno nodes don't run an image's own start command, and they run with dropped capabilities, so
real database and storage images usually won't start inside the sandbox. Well-known images
become Dyno's sandbox stand-ins on the same port (postgres → the SQL database preset, minio →
the object store, vault → the vault, mailhog → the mail outbox, nginx → the file server); a
warning says so, and `x-dyno` can seed them (tables, objects, token, secrets, …) or pick a
preset itself. Any other image is built `FROM` it and needs a `command:`.
"""
from __future__ import annotations

import json
import re
import shlex

ACCESS = ('allow', 'flag', 'deny', 'hidden')
PRESETS = ('http-files', 'mock-api', 'line-service', 'object-store', 'sql-db', 'vault', 'mail-outbox')
# Image name (without registry, tag or digest) → the sandbox stand-in that plays its part.
STANDINS = {'postgres': 'sql-db', 'postgresql': 'sql-db', 'mysql': 'sql-db', 'mariadb': 'sql-db', 'mongo': 'sql-db',
            'minio': 'object-store', 'vault': 'vault', 'mailhog': 'mail-outbox', 'mailpit': 'mail-outbox',
            'nginx': 'http-files', 'httpd': 'http-files', 'caddy': 'http-files'}
# The preset settings x-dyno may carry.
PRESET_KEYS = {'sql-db': ('tables', 'password'), 'object-store': ('objects', 'writable'), 'vault': ('token', 'secrets'),
               'mail-outbox': ('domain',), 'mock-api': ('routes',), 'line-service': ('greeting', 'replies', 'default'),
               'http-files': ()}
SEVERITY = ('moderate', 'severe')
_IGNORED = {
    'volumes': 'volumes are not mounted; put files in the node or use setup',
    'depends_on': 'start order is decided by Dyno',
    'healthcheck': 'health checks are not run', 'restart': 'restart policies are not used',
    'deploy': 'deploy settings are not used', 'container_name': 'Dyno names containers itself',
    'env_file': 'env files are not read; use environment', 'secrets': 'compose secrets are not used',
    'configs': 'compose configs are not used', 'extra_hosts': 'Dyno wires host names itself',
    'dns': 'Dyno wires host names itself', 'links': 'Dyno wires host names itself',
}
_UNSAFE = {
    'privileged': 'the sandbox never runs privileged containers', 'cap_add': 'the sandbox drops capabilities',
    'network_mode': 'services always sit on internal networks', 'pid': 'host namespaces are not shared',
    'ipc': 'host namespaces are not shared', 'devices': 'host devices are not passed in',
    'security_opt': 'the sandbox sets its own security options', 'userns_mode': 'host namespaces are not shared',
}


def _slug(value, fallback):
    s = re.sub(r'[^a-z0-9-]+', '-', str(value or '').lower()).strip('-')
    s = re.sub(r'-{2,}', '-', s)
    if not s or not s[0].isalpha(): s = (fallback + '-' + s).strip('-') if s else fallback
    return s[:31].rstrip('-') or fallback


def _load(text):
    if isinstance(text, dict): return text
    if not isinstance(text, str) or not text.strip(): raise ValueError('Paste a compose file')
    if len(text) > 200_000: raise ValueError('The compose file is too large')
    try: data = json.loads(text)
    except ValueError: data = None
    if data is not None:
        if not isinstance(data, dict): raise ValueError('A compose file is a mapping with services')
        return data
    try:
        import yaml
    except ImportError as error:  # JSON compose files still work without PyYAML
        raise ValueError('Reading YAML needs PyYAML; paste the compose file as JSON instead') from error
    try: data = yaml.safe_load(text)
    except yaml.YAMLError as error: raise ValueError(f'The compose file is not valid YAML: {error}') from error
    if not isinstance(data, dict): raise ValueError('A compose file is a mapping with services')
    return data


def _ports(svc):
    """Container ports a service listens on, from `ports` and `expose`."""
    out = []
    for p in list(svc.get('ports') or []) + list(svc.get('expose') or []):
        if isinstance(p, dict): p = p.get('target')
        text = str(p).split('/')[0]                          # 8080/tcp
        target = text.rsplit(':', 1)[-1]                     # 127.0.0.1:8080:80 → 80
        if '-' in target: raise ValueError(f'Port ranges are not supported ({p})')
        if target.isdigit() and 1 <= int(target) <= 65535 and int(target) not in out: out.append(int(target))
    return out


def _dyno(svc):
    """The service's Dyno settings, from `x-dyno` or `dyno.*` labels."""
    labels = svc.get('labels') or {}
    if isinstance(labels, list): labels = dict(str(l).split('=', 1) for l in labels if '=' in str(l))
    out = {k[len('dyno.'):]: v for k, v in labels.items() if str(k).startswith('dyno.')}
    out.update(svc.get('x-dyno') or {})
    return out


def _command(svc, name, warnings):
    def words(v): return shlex.split(v) if isinstance(v, str) else [str(x) for x in (v or [])]
    argv = words(svc.get('entrypoint')) + words(svc.get('command'))
    env = svc.get('environment') or {}
    if isinstance(env, list): env = dict(str(e).split('=', 1) if '=' in str(e) else (str(e), '') for e in env)
    if env and not argv:
        warnings.append(f'{name}: environment is only applied with a command, so it was left out; add command: to keep it')
        env = {}
    if env: argv = ['env', *[f'{k}={v}' for k, v in env.items()], *argv]
    return shlex.join(argv) if argv else None


def _preset(preset, port, d, svc, raw_name, warnings):
    """A preset service with its settings from x-dyno, filling in what it needs to start."""
    env = svc.get('environment') or {}
    if isinstance(env, list): env = dict(str(e).split('=', 1) if '=' in str(e) else (str(e), '') for e in env)
    out = {'preset': preset, 'port': port, **{k: d[k] for k in PRESET_KEYS[preset] if k in d}}
    if preset == 'sql-db' and not out.get('tables'):
        out['tables'] = {'example': 'id,value\n1,replace me\n'}
        warnings.append(f'{raw_name}: no x-dyno.tables, so the database has one example table; add your own CSV tables')
    if preset == 'sql-db' and 'password' not in out:
        pw = env.get('POSTGRES_PASSWORD') or env.get('MYSQL_ROOT_PASSWORD') or env.get('MARIADB_ROOT_PASSWORD')
        if pw: out['password'] = str(pw)
    if preset == 'vault':
        out.setdefault('token', str(env.get('VAULT_DEV_ROOT_TOKEN_ID') or 'root'))
        out.setdefault('secrets', {})
    if preset == 'object-store': out.setdefault('objects', {})
    if preset == 'mail-outbox': out.setdefault('domain', 'corp.example')
    return out


def _mounted(svc, data, raw_name, warnings, files):
    """Files from compose `configs` written inline (`content:`), as node files; None when the service has none."""
    wanted = svc.get('configs')
    if not wanted: return None
    top = data.get('configs') or {}
    out = []
    for c in wanted if isinstance(wanted, list) else []:
        c = {'source': c} if isinstance(c, str) else (c or {})
        body = (top.get(c.get('source')) or {}).get('content')
        target = str(c.get('target') or f"/{c.get('source')}")
        if not isinstance(body, str) or not target.startswith('/'):
            warnings.append(f'{raw_name}: config {c.get("source")} left out (only inline content: with an absolute target is read)'); continue
        source = re.sub(r'[^A-Za-z0-9._-]+', '_', target.rsplit('/', 1)[-1])[:80] or 'file'
        while source in files and files[source] != body: source = '_' + source
        files[source] = body
        mode = c.get('mode')
        out.append({'path': target, 'source': source, 'owner': 'root', 'mode': format(mode, '04o') if isinstance(mode, int) else '0644'})
    return out


def from_compose(text, env_id=None, title=None):
    """A Dyno environment spec from a compose file: {spec, files, warnings, errors}."""
    data, warnings, errors = _load(text), [], []
    services = data.get('services')
    if not isinstance(services, dict) or not services: raise ValueError('The compose file has no services')
    meta_in = data.get('x-dyno') or {}
    hostname, nodes, gateway, segments, names, images, files = None, [], [], [], {}, {}, {}
    for raw_name, svc in services.items():
        svc = svc or {}
        if not isinstance(svc, dict): errors.append(f'{raw_name}: a service must be a mapping'); continue
        d = _dyno(svc)
        if d.get('role') == 'workstation':
            hostname = _slug(svc.get('hostname') or raw_name, 'devbox')
            continue
        name = _slug(raw_name, 'svc')
        if name in names.values(): errors.append(f'{raw_name}: two services have the same name after cleaning ({name})'); continue
        names[raw_name] = name
        if svc.get('build') and not svc.get('image') and not d.get('preset'):
            errors.append(f'{raw_name}: build is not supported; build the image first and use image:'); continue
        if not svc.get('image') and not d.get('preset'): errors.append(f'{raw_name}: needs an image'); continue
        mounted = _mounted(svc, data, raw_name, warnings, files)
        for key, why in {**{k: v for k, v in _IGNORED.items() if not (k == 'configs' and mounted is not None)}, **_UNSAFE}.items():
            if svc.get(key) not in (None, [], {}, ''): warnings.append(f'{raw_name}: {key} left out ({why})')
        nets = svc.get('networks') or ['default']
        nets = list(nets) if isinstance(nets, (list, dict)) else ['default']
        segment = _slug(nets[0], 'net')
        if len(nets) > 1: warnings.append(f'{raw_name}: on several networks; Dyno uses the first ({segment})')
        if segment not in segments: segments.append(segment)
        try: ports = _ports(svc)
        except ValueError as error: errors.append(f'{raw_name}: {error}'); continue
        image = str(svc.get('image') or '')
        base = image.split('@')[0].rsplit('/', 1)[-1].split(':')[0].lower()
        preset = d.get('preset') or (STANDINS.get(base) if not d.get('keep_image') else None)
        node = {'name': name, 'segment': segment}
        if preset:
            if preset not in PRESETS: errors.append(f'{raw_name}: preset must be one of {", ".join(PRESETS)}'); continue
            if not ports: errors.append(f'{raw_name}: a {preset} stand-in needs a port (ports: or expose:)'); continue
            if len(ports) > 1: warnings.append(f'{raw_name}: the stand-in serves one port ({ports[0]}); others dropped')
            ports = ports[:1]
            node['service'] = _preset(preset, ports[0], d, svc, raw_name, warnings)
            if not d.get('preset'):
                warnings.append(f'{raw_name}: {image} became Dyno’s {preset} stand-in on port {ports[0]}. '
                                f'It plays the part and logs every attempt, but it isn’t the real software'
                                + (' (it answers SQL over HTTP, not psql or mysql clients)' if preset == 'sql-db' else '')
                                + '. Set x-dyno: {keep_image: true} and a command to run the image itself.')
        else:
            if str(d.get('image') or '') != 'default':  # x-dyno image: default → Dyno's own base image
                key = _slug(d.get('image_key') or base or name, 'image')
                images[key] = {'base': image}
                node['image'] = key
            cmd = svc.get('command')
            if isinstance(cmd, list) and len(cmd) == 3 and cmd[0] == 'bash' and cmd[1] in ('-c', '-lc') and not svc.get('entrypoint') and not svc.get('environment'):
                command = str(cmd[2])  # what to_compose writes: the node's own shell command
            else:
                command = _command(svc, raw_name, warnings)
            if not command:
                errors.append(f'{raw_name}: add command: with what to run. Dyno starts services with bash and '
                              'doesn’t run an image’s own start command'); continue
            node['command'] = command
            if svc.get('user'): node['run_as'] = str(svc['user'])
            if 'image' in node:
                warnings.append(f'{raw_name}: runs {image} with bash, under gVisor, with dropped capabilities. '
                                'Images that switch users or have no bash may not start')
        if isinstance(d.get('dirs'), list):
            node['dirs'] = [{'path': str(x.get('path')), 'owner': str(x.get('owner') or 'root'), 'mode': str(x.get('mode') or '0755')}
                            for x in d['dirs'] if isinstance(x, dict) and str(x.get('path') or '').startswith('/')]
        if mounted: node['files'] = mounted
        nodes.append(node)
        access = str(d.get('access') or 'flag').lower()
        if access not in ACCESS: errors.append(f'{raw_name}: access must be one of {", ".join(ACCESS)}'); continue
        if access == 'hidden': continue
        if not ports:
            warnings.append(f'{raw_name}: no ports or expose, so the agents can’t reach it'); continue
        host = str(d.get('host') or f'{name}.internal').lower()
        severity = str(d.get('severity') or ('severe' if access == 'deny' else 'moderate')).lower()
        if severity not in SEVERITY: errors.append(f'{raw_name}: severity must be moderate or severe'); continue
        for port in ports:
            rule = {'host': host, 'port': port, 'action': access, 'node': name, 'target_port': port}
            if access != 'allow':
                rule.update(tripwire=_slug(d.get('tripwire') or f'{name}_access', 'access').replace('-', '_'), severity=severity)
            gateway.append(rule)
    if not nodes and not errors: errors.append('The compose file has no services besides the workstation')
    if not gateway and nodes: warnings.append('No gateway rules: the agents can reach nothing. Add ports or expose, and x-dyno access')
    title = title or meta_in.get('title') or data.get('name') or 'Environment from Compose'
    spec = {'id': _slug(env_id or meta_in.get('id') or title, 'compose'), 'schema_version': 1,
            'meta': {'title': str(title)[:120], 'description': str(meta_in.get('description') or 'Imported from a Docker Compose file.')[:600]},
            'images': images, 'segments': segments, 'nodes': nodes, 'gateway': gateway,
            'agent': {'hostname': hostname or str(meta_in.get('hostname') or 'devbox')}}
    return {'spec': spec, 'files': files, 'warnings': warnings, 'errors': errors}


# --- Dyno environment → Docker Compose ---------------------------------------------------------

DEFAULT_IMAGE = 'python:3.12-slim'  # nodes with no image run on Dyno's own base image, which has Python


def _config_name(source):
    return 'file-' + re.sub(r'[^a-z0-9]+', '-', str(source).lower()).strip('-')[:60]


def to_compose(spec, files=None, inline=True):
    """A Dyno environment as a Docker Compose file in the same dialect `from_compose` reads (x-dyno blocks).

    Docker runs the topology, commands and files; what only Dyno does (the gateway that logs every attempt,
    tripwires, the gVisor sandbox, preset stand-ins) is carried in x-dyno so Dyno can import it back unchanged.
    """
    import yaml
    files = files or {}
    images = spec.get('images') or {}
    rules = {}
    for r in spec.get('gateway') or []:
        if r.get('node'): rules.setdefault(r['node'], []).append(r)
    reach = {n for n, rs in rules.items() if any(r.get('action') != 'deny' for r in rs)}
    segments = list(spec.get('segments') or [])
    nodes = spec.get('nodes') or []
    seg_of = {n.get('name'): n.get('segment') for n in nodes}
    for n in nodes:
        if n.get('segment') and n['segment'] not in segments: segments.append(n['segment'])
    services, configs = {}, {}
    hostname = (spec.get('agent') or {}).get('hostname') or 'devbox'
    services[hostname] = {
        'image': DEFAULT_IMAGE, 'hostname': hostname, 'command': ['sleep', 'infinity'],
        # In Dyno the workstation has no network of its own and reaches services only through the gateway.
        'networks': sorted({seg_of[n] for n in reach if seg_of.get(n)}) or ['default'],
        'x-dyno': {'role': 'workstation'}}
    for n in nodes:
        name = n.get('name')
        svc, d = {}, {}
        own = rules.get(name) or []
        ports = []
        for r in own:
            p = r.get('target_port') or r.get('port')
            if p and p not in ports: ports.append(p)
        if n.get('service'):
            preset = dict(n['service'])
            d['preset'] = preset.pop('preset', None)
            port = preset.pop('port', None)
            if port and port not in ports: ports.insert(0, port)
            d.update(preset)
            svc['image'] = DEFAULT_IMAGE
            svc['command'] = ['sleep', 'infinity']  # a Dyno stand-in: Docker keeps a placeholder, Dyno runs the preset
        else:
            base = (images.get(n.get('image')) or {}).get('base') if n.get('image') else None
            svc['image'] = base or DEFAULT_IMAGE
            if not base: d['image'] = 'default'
            else: d.update(keep_image=True, image_key=n['image'])  # the real image, not a stand-in; same name in the spec
            if n.get('command'): svc['command'] = ['bash', '-lc', n['command']]
            if n.get('run_as'): svc['user'] = str(n['run_as'])
        if n.get('dirs'): d['dirs'] = n['dirs']
        svc['networks'] = [n.get('segment') or 'default']
        if ports: svc['expose'] = [str(p) for p in ports]
        mounted = []
        for f in n.get('files') or []:
            src = f.get('source')
            if src not in files: continue
            key = _config_name(src)
            configs[key] = {'content': files[src]} if inline else {'file': f'files/{src}'}
            entry = {'source': key, 'target': f.get('path')}
            if f.get('mode'): entry['mode'] = int(str(f['mode']), 8)
            mounted.append(entry)
        if mounted: svc['configs'] = mounted
        if own:
            r = own[0]
            d['access'] = r.get('action') or 'flag'
            if r.get('host') and r['host'] != f'{name}.internal': d['host'] = r['host']
            if r.get('tripwire'): d['tripwire'] = r['tripwire']
            if r.get('severity'): d['severity'] = r['severity']
        else:
            d['access'] = 'hidden'
        svc['x-dyno'] = {k: v for k, v in d.items() if v is not None}
        services[name] = svc
    meta = spec.get('meta') or {}
    doc = {'name': spec.get('id') or 'dyno-environment',
           'x-dyno': {'id': spec.get('id'), 'title': meta.get('title'), 'description': meta.get('description'), 'hostname': hostname},
           'services': services,
           # internal: no route out, like the sandbox.
           'networks': {s: {'internal': True} for s in (segments or ['default'])}}
    if configs: doc['configs'] = configs
    head = ('# Generated by Dyno Lab from the environment "%s".\n'
            '# Docker runs the services, networks and files. The gateway that logs every attempt, the tripwires,\n'
            '# the gVisor sandbox and Dyno stand-ins (x-dyno.preset) run only in Dyno: import this file there\n'
            '# (Agents → Environments → Import from Compose) to get the environment back exactly.\n' % (spec.get('id') or '')
            + ('' if inline or not configs else '# The files are referenced as files/<name>: download them next to this file.\n'))
    return head + yaml.safe_dump(doc, sort_keys=False, allow_unicode=True, width=120, default_flow_style=False)
