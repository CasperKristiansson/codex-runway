#!/usr/bin/env python3
"""Score immutable app forecasts against subsequently observed quota intervals.

Read-only; no account names/IDs are printed. Targets remain partial-observation
proxies. A missing record/account/interval is not interpreted as zero usage.
"""
import argparse
import collections
import json
import plistlib
from pathlib import Path
from analyze import EPOCH, HOUR, covered, metrics, overlap, quota_intervals


def score(records, accounts, as_of):
    by_id = {a['id']: a for a in accounts}
    rows = collections.defaultdict(list)
    skipped = collections.Counter()
    for record in sorted(records, key=lambda r: r['origin']):
        if record['schemaVersion'] != 1:
            skipped['unsupported_schema'] += 1
            continue
        origin = record['origin'] + EPOCH
        if origin > as_of:
            skipped['future_origin'] += 1
            continue
        states = record['accounts']
        if any(s['id'] not in by_id for s in states):
            skipped['account_no_longer_available'] += 1
            continue
        scoped = []
        for state in states:
            # Frozen starting reading supplies the left boundary even if current
            # retention no longer contains it. Snapshot IDs prevent duplicates.
            snapshots = {s['id']: s for s in by_id[state['id']]['snapshots']}
            snapshots[state['snapshot']['id']] = state['snapshot']
            scoped.append({'planName': 'Pro 20×' if state['capacityUnits'] == 4 else 'Pro 5×',
                           'snapshots': sorted((s for s in snapshots.values() if s['capturedAt']+EPOCH <= as_of),
                                               key=lambda s:s['capturedAt'])})
        intervals, _ = quota_intervals(scoped)
        reliable = [x for x in intervals if x[1]-x[0] <= 2*HOUR]
        for candidate in record['candidates']:
            for prediction in candidate['predictions']:
                h = prediction['horizonHours']
                end = origin + h*HOUR
                if end > as_of:
                    skipped['pending_candidate_targets'] += 1
                    continue
                if covered(origin, end, reliable) < .8:
                    skipped['insufficient_observation_candidate_targets'] += 1
                    continue
                actual = sum(v*overlap(s,e,origin,end)/(e-s) for s,e,v,i in reliable)
                rows[(candidate['model'], h)].append((origin,actual,prediction['units']))
    scores = {}
    for (model,h), values in sorted(rows.items()):
        independent=[]; last=None
        for origin,actual,predicted in values:
            if last is None or origin-last >= h*HOUR:
                independent.append((actual,predicted));last=origin
        scores[f'{model}/{h}h'] = {
            'all_origins': metrics([(a,p) for _,a,p in values]),
            'disjoint_targets': metrics(independent)}
    return {'scores_units': scores, 'skipped':dict(skipped),
            'limitations': 'Observed consumption only; >=80% union coverage is not complete account coverage. Reset gaps and unmet demand are unmeasured. This does not score exhaustion-warning accuracy.'}


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--directory',type=Path,default=Path.home()/'Library/Application Support/Codex Runway/Forecasts')
    p.add_argument('--preferences',type=Path,default=Path.home()/'Library/Preferences/com.casperkristiansson.codex-runway.plist')
    args=p.parse_args()
    records=[json.loads(path.read_text()) for path in sorted(args.directory.glob('forecast-*.json'))]
    accounts=json.loads(plistlib.loads(args.preferences.read_bytes())['codex-runway.accounts.v1'])
    as_of=max((s['capturedAt']+EPOCH for a in accounts for s in a['snapshots']),default=0)
    print(json.dumps(score(records,accounts,as_of),indent=2))

if __name__=='__main__':main()
