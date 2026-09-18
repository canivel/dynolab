"""Bounded, data-only controlled studies against explicitly selected local servers.

No shell, imported code, automatic publication, or additional weight allocation.
Protocols are frozen on creation; labels and attempts are append-only records.
"""
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import threading
import time
import urllib.request
import uuid

MAX_BYTES = 4_000_000


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def text(value, name, maximum=16000):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise ValueError(f'{name} must contain 1–{maximum} characters')
    return value


def validate_protocol(raw):
    if not isinstance(raw, dict):
        raise ValueError('Protocol must be an object')
    allowed = {'schema_version', 'title', 'question', 'hypothesis', 'rubric', 'conditions', 'cases', 'seeds', 'max_tokens', 'thinking', 'temperature', 'source', 'parent_hash'}
    if set(raw) - allowed:
        raise ValueError('Unsupported protocol fields: ' + ', '.join(sorted(set(raw) - allowed)))
    p = copy.deepcopy(raw)
    if p.get('schema_version') != 1:
        raise ValueError('schema_version must be 1')
    for key in ('title', 'question', 'hypothesis', 'rubric'):
        text(p.get(key), key)
    conditions = p.get('conditions')
    cases = p.get('cases')
    if not isinstance(conditions, list) or not 2 <= len(conditions) <= 4:
        raise ValueError('Choose 2–4 conditions')
    if not isinstance(cases, list) or not 1 <= len(cases) <= 50:
        raise ValueError('Choose 1–50 cases')
    ids = set()
    for c in conditions:
        if not isinstance(c, dict) or set(c) != {'id', 'instruction'}:
            raise ValueError('Each condition needs id and instruction')
        name = text(c['id'], 'condition id', 64)
        if name in ids:
            raise ValueError('Duplicate condition id')
        ids.add(name)
        if not isinstance(c['instruction'], str) or len(c['instruction']) > 4000:
            raise ValueError('Invalid condition instruction')
    seen, groups = set(), {}
    for c in cases:
        if not isinstance(c, dict) or set(c) != {'id', 'group', 'split', 'prompt'}:
            raise ValueError('Each case needs id, group, split and prompt')
        name = text(c['id'], 'case id', 64)
        group = text(c['group'], 'case group', 64)
        text(c['prompt'], 'case prompt')
        if name in seen or c['split'] not in ('development', 'test'):
            raise ValueError('Duplicate case or invalid split')
        if group in groups and groups[group] != c['split']:
            raise ValueError('A case group cannot cross development/test partitions')
        seen.add(name); groups[group] = c['split']
    seeds = p.setdefault('seeds', [0])
    if not isinstance(seeds, list) or not 1 <= len(seeds) <= 10 or any(type(s) is not int or not 0 <= s <= 2147483647 for s in seeds) or len(set(seeds)) != len(seeds):
        raise ValueError('Use 1–10 distinct integer seeds')
    budget = p.setdefault('max_tokens', 512)
    if type(budget) is not int or not 16 <= budget <= 8192:
        raise ValueError('max_tokens must be 16–8192')
    p.setdefault('thinking', 'off')
    if p['thinking'] not in ('default', 'on', 'off'):
        raise ValueError('thinking must be default, on or off')
    temperature = p.setdefault('temperature', 0.7)
    if type(temperature) not in (int, float) or not math.isfinite(temperature) or not 0 <= temperature <= 2:
        raise ValueError('temperature must be between 0 and 2')
    count = len(cases) * len(conditions) * len(seeds)
    if count > 200 or count * budget > 200_000:
        raise ValueError('Study exceeds 200 requests or 200000 maximum output tokens')
    for key in ('source', 'parent_hash'):
        if key in p:
            text(p[key], key, 2000)
    return p


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Inference redirects are not allowed')


def complete(port, payload):
    req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/chat/completions',
        data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect).open(req, timeout=180) as response:
        data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError('Inference response exceeds 4 MB')
        return json.loads(data)


class Studies:
    def __init__(self, root, completion=complete):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.active = None
        self.cancel_event = threading.Event()
        self.completion = completion
        for path in self.root.glob('*.json'):
            data = json.loads(path.read_text())
            if data.get('status') in ('running', 'cancelling'):
                data['status'] = 'interrupted'
                for run in data['runs']:
                    if run['status'] == 'running': run['status'] = 'interrupted'
                self._write(data)

    def _path(self, identifier):
        if not isinstance(identifier, str) or not re.fullmatch('[a-f0-9]{32}', identifier):
            raise ValueError('Invalid study ID')
        return self.root / (identifier + '.json')

    def _write(self, data):
        path = self._path(data['id'])
        tmp = path.with_suffix('.tmp')
        tmp.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False, indent=2))
        os.chmod(tmp, 0o600)
        tmp.replace(path)

    def read(self, identifier):
        with self.lock:
            return json.loads(self._path(identifier).read_text())

    def list(self):
        with self.lock:
            values = [json.loads(p.read_text()) for p in self.root.glob('*.json')]
            return [dict(id=s['id'], title=s['protocol']['title'], status=s['status'], created=s['created'], attempts=len(s['runs'])) for s in sorted(values, key=lambda v: v['created'], reverse=True)]

    def create(self, protocol):
        p = validate_protocol(protocol)
        data = dict(id=uuid.uuid4().hex, protocol=p, protocol_hash=digest(p), created=time.time(), status='prepared', runs=[], labels=[])
        with self.lock: self._write(data)
        return data

    def run(self, identifier, port, model):
        if type(port) is not int or not 1024 <= port <= 65535:
            raise ValueError('Select a local inference port between 1024 and 65535')
        text(model, 'model identifier', 2048)
        with self.lock:
            if self.active: raise RuntimeError('A controlled study is already running')
            data = self.read(identifier)
            if data.get('imported'): raise ValueError('Imported evidence is read-only; create a reproduction first')
            target = dict(port=port, model=model)
            if data.get('target') not in (None, target):
                raise ValueError('Cannot change endpoint/model within a study; create a reproduction')
            data['target'] = target
            data['status'] = 'running'
            self.active = identifier; self.cancel_event.clear(); self._write(data)
            threading.Thread(target=self._execute, args=(identifier, target), daemon=True).start()
            return data

    def cancel(self, identifier):
        with self.lock:
            data = self.read(identifier)
            if self.active == identifier:
                self.cancel_event.set(); data['status'] = 'cancelling'; self._write(data)
            return data

    def _execute(self, identifier, target):
        execution_error = None
        try:
            p = self.read(identifier)['protocol']
            work = [(c, condition, seed) for c in p['cases'] for condition in p['conditions'] for seed in p['seeds']]
            random.Random(0).shuffle(work)
            for case, condition, seed in work:
                with self.lock:
                    if self.cancel_event.is_set(): break
                    data = self.read(identifier)
                    key = digest([case['id'], condition['id'], seed])
                    if any(r['key'] == key and r['status'] == 'completed' for r in data['runs']): continue
                    payload = dict(model=target['model'], messages=[{'role': 'user', 'content': case['prompt'] + '\n\n' + condition['instruction']}], max_tokens=p['max_tokens'], temperature=p['temperature'], seed=seed, stream=False)
                    if p['thinking'] != 'default': payload['chat_template_kwargs'] = {'enable_thinking': p['thinking'] == 'on'}
                    run = dict(id=uuid.uuid4().hex, key=key, case=case['id'], group=case['group'], split=case['split'], condition=condition['id'], seed=seed, status='running', request=payload, started=time.time())
                    data['runs'].append(run); self._write(data)
                try:
                    response = self.completion(target['port'], payload)
                    choice = response['choices'][0]
                    message = choice['message']
                    answer = message.get('content') or ''
                    thinking = message.get('reasoning_content') or message.get('reasoning') or ''
                    if not isinstance(answer, str) or not isinstance(thinking, str): raise ValueError('Unsupported response content')
                    finish = choice.get('finish_reason')
                    run.update(response=response, answer=answer, thinking=thinking, finish_reason=finish,
                        status='completed' if answer.strip() and finish == 'stop' else 'incomplete')
                except Exception as error:
                    run.update(status='failed', error=str(error)[:4000])
                with self.lock:
                    if self.cancel_event.is_set(): run['status'] = 'cancelled'
                    run['ended'] = time.time()
                    data = self.read(identifier)
                    data['runs'][-1] = run
                    self._write(data)
        except Exception as error:
            execution_error = str(error)[:4000]
        finally:
            with self.lock:
                try:
                    data = self.read(identifier)
                    data['status'] = 'failed' if execution_error else 'cancelled' if self.cancel_event.is_set() else 'finished'
                    if execution_error: data['error'] = execution_error
                    self._write(data)
                finally:
                    self.active = None

    def label(self, identifier, run_id, value, reviewer, note=''):
        if value not in ('pass', 'fail', 'uncertain'): raise ValueError('Label must be pass, fail or uncertain')
        text(reviewer, 'reviewer', 128)
        if not isinstance(note, str) or len(note) > 4000: raise ValueError('Invalid label note')
        with self.lock:
            data = self.read(identifier)
            if data.get('imported'): raise ValueError('Imported evidence is read-only')
            if not any(r['id'] == run_id and r['status'] == 'completed' for r in data['runs']):
                raise ValueError('Only completed runs can be labeled')
            data['labels'].append(dict(id=uuid.uuid4().hex, run_id=run_id, value=value, reviewer=reviewer, note=note, created=time.time()))
            self._write(data)
            return data

    def prepare_review(self, identifier, reviewer, prior_exposure):
        """Persist one shuffled, resumable queue per reviewer; return only its safe view."""
        reviewer = text(reviewer, 'reviewer', 128).strip()
        if type(prior_exposure) is not bool:
            raise ValueError('Declare prior_exposure as true or false')
        with self.lock:
            data = self.read(identifier)
            if data.get('imported') or data['status'] in ('running', 'cancelling'):
                raise ValueError('Review requires inactive local results')
            sessions = data.setdefault('reviews', [])
            existing = next((s for s in sessions if s['reviewer'] == reviewer), None)
            if existing:
                return self._review_view(data, existing)
            if len(sessions) >= 100: raise ValueError('At most 100 review sessions per study')
            # Match the summary denominator: latest completed attempt per work item.
            runs = list({r['key']: r for r in data['runs'] if r['status'] == 'completed'}.values())
            if not runs: raise ValueError('No completed answers to review')
            random.SystemRandom().shuffle(runs)
            session = dict(id=uuid.uuid4().hex, reviewer=reviewer, prior_exposure=prior_exposure,
                created=time.time(), revealed_at=None, protocol_hash=data['protocol_hash'],
                items=[dict(id=uuid.uuid4().hex, run_id=r['id']) for r in runs])
            sessions.append(session); self._write(data)
            return self._review_view(data, session)

    @staticmethod
    def _find_review(data, review_id):
        session = next((s for s in data.get('reviews', []) if s['id'] == review_id), None)
        if session is None: raise ValueError('Unknown review session')
        return session

    @staticmethod
    def _review_view(data, session):
        cases = {c['id']: c for c in data['protocol']['cases']}
        runs = {r['id']: r for r in data['runs']}
        items = []
        revealed = session['revealed_at'] is not None
        for index, item in enumerate(session['items'], 1):
            run = runs[item['run_id']]
            history = [l for l in data['labels'] if l.get('review_id') == session['id'] and l['run_id'] == run['id']]
            # Explicit allowlist. No raw request, condition instruction, target, seed,
            # run ID, thinking, peer labels or timing is returned before reveal.
            row = dict(id=item['id'], number=index, prompt=cases[run['case']]['prompt'],
                answer=run['answer'], labels=[{k: l[k] for k in ('value', 'note', 'created', 'context_hidden')} for l in history])
            if revealed:
                row['context'] = dict(run_id=run['id'], condition=run['condition'], case=run['case'],
                    seed=run['seed'], split=run['split'], target=data.get('target'))
            items.append(row)
        return dict(id=session['id'], reviewer=session['reviewer'], rubric=data['protocol']['rubric'],
            prior_exposure=session['prior_exposure'], revealed_at=session['revealed_at'], items=items,
            reviewed=sum(bool(i['labels']) for i in items), total=len(items),
            limitation='Context masking is a review aid, not access control. Answer text or the shared prompt may reveal context. Prior exposure is self-reported; local reviewer names are not authenticated.')

    def review(self, identifier, review_id):
        with self.lock:
            data = self.read(identifier)
            return self._review_view(data, self._find_review(data, review_id))

    def review_label(self, identifier, review_id, item_id, value, note=''):
        if value not in ('pass', 'fail', 'uncertain'): raise ValueError('Label must be pass, fail or uncertain')
        if not isinstance(note, str) or len(note) > 4000: raise ValueError('Invalid label note')
        with self.lock:
            data = self.read(identifier)
            session = self._find_review(data, review_id)
            item = next((i for i in session['items'] if i['id'] == item_id), None)
            if item is None: raise ValueError('Unknown review item')
            data['labels'].append(dict(id=uuid.uuid4().hex, run_id=item['run_id'], value=value,
                reviewer=session['reviewer'], note=note, created=time.time(), review_id=review_id,
                protocol_hash=session['protocol_hash'], prior_exposure=session['prior_exposure'],
                context_hidden=session['revealed_at'] is None))
            self._write(data)
            return self._review_view(data, session)

    def reveal_review(self, identifier, review_id):
        with self.lock:
            data = self.read(identifier)
            session = self._find_review(data, review_id)
            if session['revealed_at'] is None:
                session['revealed_at'] = time.time(); self._write(data)
            return self._review_view(data, session)

    def export(self, identifier):
        data = self.read(identifier)
        if data['status'] in ('running', 'cancelling'): raise ValueError('Finish or cancel before exporting')
        return dict(schema='dyno.controlled-study/1', study=data, sha256=digest(data))

    def import_bundle(self, bundle):
        if not isinstance(bundle, dict) or set(bundle) != {'schema', 'study', 'sha256'} or bundle['schema'] != 'dyno.controlled-study/1':
            raise ValueError('Unsupported study bundle')
        if len(json.dumps(bundle)) > MAX_BYTES: raise ValueError('Bundle exceeds 4 MB')
        data = bundle['study']
        if not isinstance(data, dict) or not isinstance(data.get('protocol'), dict):
            raise ValueError('Invalid study evidence')
        if digest(data) != bundle['sha256']: raise ValueError('Bundle hash mismatch')
        p = validate_protocol(data['protocol'])
        if data.get('protocol_hash') != digest(p): raise ValueError('Protocol hash mismatch')
        # Imported output stays opaque evidence. It is never resumed or executed.
        with self.lock:
            imported = self.create(p)
            imported.update(status='imported', imported=True, source_hash=bundle['sha256'], evidence=bundle)
            self._write(imported)
            return imported

    def reproduce(self, identifier):
        original = self.read(identifier)
        p = copy.deepcopy(original['protocol'])
        parent = original['evidence']['study'] if original.get('imported') else original
        p['parent_hash'] = digest(parent)
        child = self.create(p)
        child['parent_evidence'] = copy.deepcopy(parent)
        with self.lock: self._write(child)
        return child

    def reproduction_report(self, identifier):
        child = self.read(identifier)
        parent = child.get('parent_evidence')
        if not parent: raise ValueError('No saved parent evidence; prepare a new reproduction from the source study')
        if digest(parent) != child['protocol'].get('parent_hash'): raise ValueError('Parent evidence hash mismatch')
        def latest(data):
            return {(r['case'], r['condition'], r['seed']): r for r in data['runs'] if r['status'] == 'completed'}
        before, after = latest(parent), latest(child)
        rows = []
        for key in sorted(set(before) | set(after)):
            a, b = before.get(key), after.get(key)
            rows.append(dict(case=key[0], condition=key[1], seed=key[2],
                original_run_id=a['id'] if a else None, reproduction_run_id=b['id'] if b else None,
                original_answer=a.get('answer') if a else None, reproduction_answer=b.get('answer') if b else None,
                status='missing_original' if not a else 'missing_reproduction' if not b else 'exact_answer_match' if a.get('answer') == b.get('answer') else 'answer_changed'))
        target_before, target_after = parent.get('target'), child.get('target')
        changes = []
        for field in sorted(set(parent['protocol']) | set(child['protocol'])):
            if field == 'parent_hash': continue
            if parent['protocol'].get(field) != child['protocol'].get(field): changes.append(field)
        return dict(parent_hash=child['protocol']['parent_hash'], original_target=target_before,
            reproduction_target=target_after, target_identifier_matches=(target_before.get('model') == target_after.get('model') if target_before and target_after else None),
            changed_protocol_fields=changes, rows=rows, exact_matches=sum(r['status']=='exact_answer_match' for r in rows),
            changed_answers=sum(r['status']=='answer_changed' for r in rows), missing=sum(r['status'].startswith('missing') for r in rows),
            compatibility='Model revision, tokenizer/template, quantization and numerical backend compatibility are not automatically verified. Inspect raw requests and endpoint metadata before interpreting differences.',
            criterion='Exact final-answer text is compared. A textual difference does not establish a scientific conflict; an exact match does not verify a general finding. Review both against the saved rubric.')


def summarize(study):
    """Descriptive rates only. No independent-sample CI over repeated prompts."""
    latest = {}
    for label in study['labels']:
        latest[(label['run_id'], label['reviewer'])] = label['value']
    results = []
    for split in ('development', 'test'):
        for condition in study['protocol']['conditions']:
            runs = [r for r in study['runs'] if r['split'] == split and r['condition'] == condition['id']]
            # One most recent completed attempt per case/seed; failed attempts remain counted separately.
            completed = {r['key']: r for r in runs if r['status'] == 'completed'}
            passed = failed = ungraded = disagreement = 0
            for run in completed.values():
                labels = {v for (rid, _), v in latest.items() if rid == run['id']}
                if labels == {'pass'}: passed += 1
                elif labels == {'fail'}: failed += 1
                elif len(labels) > 1: disagreement += 1
                else: ungraded += 1
            results.append(dict(split=split, condition=condition['id'], completed=len(completed), invalid_attempts=sum(r['status'] != 'completed' for r in runs), passed=passed, failed=failed, ungraded=ungraded, disagreement=disagreement, pass_rate=passed/(passed+failed) if passed+failed else None))
    return dict(rows=results, interpretation='Descriptive, reference-labeled results. Reviewer identities and independence are not verified. Not a safety score. Repeated samples do not establish cross-task generalization.')


def monitor_metrics(rows, threshold):
    """Evaluate frozen binary predictions against explicit reference labels."""
    if type(threshold) not in (int, float) or not 0 <= threshold <= 1: raise ValueError('Invalid threshold')
    if not isinstance(rows, list) or len(rows) > 10000: raise ValueError('Invalid monitor records')
    counts = dict(tp=0, fp=0, tn=0, fn=0, excluded=0)
    for row in rows:
        if not isinstance(row, dict):
            counts['excluded'] += 1; continue
        truth, score = row.get('reference'), row.get('score')
        if type(truth) is not bool or type(score) not in (int, float) or not math.isfinite(score) or not 0 <= score <= 1:
            counts['excluded'] += 1; continue
        counts['tp' if truth and score >= threshold else 'fn' if truth else 'fp' if score >= threshold else 'tn'] += 1
    def rate(a, b): return a/b if b else None
    return dict(counts, threshold=threshold, precision=rate(counts['tp'], counts['tp']+counts['fp']), recall=rate(counts['tp'], counts['tp']+counts['fn']), false_positive_rate=rate(counts['fp'], counts['fp']+counts['tn']))
