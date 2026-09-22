#!/usr/bin/env python3
"""Read-only, dependency-free forecast study. No account identifiers are exported.

Quota folds use only intervals whose endpoint was known at the forecast origin.
Daily profile folds are retrospective: historical fetch/revision vintages are absent.
"""
import argparse, collections, datetime as dt, hashlib, json, math, plistlib, statistics
from pathlib import Path
from zoneinfo import ZoneInfo

UTC = dt.timezone.utc
TZ = ZoneInfo('Europe/Stockholm')
EPOCH = dt.datetime(2001, 1, 1, tzinfo=UTC).timestamp()
HOUR = 3600

def mean(xs):
    return statistics.mean(xs) if xs else 0.0

def quantile(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs)-1, int((len(xs)-1)*q))] if xs else None

def iso(t):
    return dt.datetime.fromtimestamp(t, TZ).isoformat()

def overlap(a,b,c,d):
    return max(0, min(b,d)-max(a,c))

def hour_parts(a,b):
    while a < b:
        end = min(b, (math.floor(a/HOUR)+1)*HOUR)
        yield a,end,dt.datetime.fromtimestamp(a,TZ).hour
        a=end

def metrics(rows):
    if not rows:return {'n':0}
    errors=[p-y for y,p in rows]
    return {'n':len(rows),'mae':mean([abs(e) for e in errors]),
            'rmse':math.sqrt(mean([e*e for e in errors])), 'bias':mean(errors),
            'p90_absolute_error':quantile([abs(e) for e in errors],.9),
            'mean_actual':mean([y for y,p in rows])}

def quota_intervals(accounts):
    valid=[]; audit=[]
    for i,acc in enumerate(accounts):
        weight=4 if '20' in acc['planName'] else 1
        ss=sorted(acc['snapshots'], key=lambda s:s['capturedAt'])
        counts=collections.Counter(); totals=collections.Counter()
        for old,new in zip(ss,ss[1:]):
            a,b=old['capturedAt']+EPOCH,new['capturedAt']+EPOCH
            w=new.get('capacityUnits',weight)
            if b<=a:reason='nonpositive_duration'
            elif old['resetAt']+EPOCH<=b or abs(old['resetAt']-new['resetAt'])>=60:reason='reset_boundary'
            elif old.get('capacityUnits',weight)!=w:reason='plan_change'
            elif new['usedPercent']<old['usedPercent']:reason='decreasing_reading'
            else:reason='usable'
            counts[reason]+=1
            if reason!='usable':continue
            # Match app clamping and missing historical weight fallback.
            amount=(min(100,max(0,new['usedPercent']))-min(100,max(0,old['usedPercent'])))*w/100
            valid.append((a,b,amount,i));totals['observed_units']+=amount
            if b-a>2*HOUR:totals['units_in_gaps_over_2h']+=amount
        prof=acc.get('profile') or {}; days=prof.get('dailyUsageBuckets',[])
        audit.append({'account':i+1,'plan':acc['planName'],'enabled':acc.get('isEnabled',True),
                      'snapshots':len(ss),'first':iso(ss[0]['capturedAt']+EPOCH),'last':iso(ss[-1]['capturedAt']+EPOCH),
                      'intervals':dict(counts),**totals,'profile_days':len(days),
                      'profile_first':min((d['startDate'] for d in days),default=None),
                      'profile_last':max((d['startDate'] for d in days),default=None),
                      'profile_fetched':iso(prof['fetchedAt']+EPOCH) if prof else None})
    return sorted(valid),audit

def covered(a,b,intervals):
    spans=sorted((max(a,s),min(b,e)) for s,e,*_ in intervals if e>a and s<b)
    total=0;end=a
    for s,e in spans:
        total+=max(0,e-max(s,end));end=max(end,e)
    return total/(b-a)

def quota_predict(train, origin, horizon, model):
    start=max(min(s for s,e,v,i in train),origin-30*24*HOUR)
    total=sum(v*overlap(s,e,start,origin)/(e-s) for s,e,v,i in train)
    baseline=total/((origin-start)/HOUR)
    if model=='app_30d':return baseline*horizon
    if model in ('recent_24h','recent_72h'):
        hours=24 if model=='recent_24h' else 72
        start=max(start,origin-hours*HOUR)
        r=sum(v*overlap(s,e,start,origin)/(e-s) for s,e,v,i in train)/((origin-start)/HOUR)
        return r*horizon
    # Shape estimated from short intervals only; exposure uses UNION across
    # accounts, preventing account switching from multiplying elapsed time.
    short=[x for x in train if x[1]-x[0]<=2*HOUR]
    amounts=[0.0]*24;exposure=[0.0]*24
    for s,e,v,i in short:
        for a,b,h in hour_parts(s,e):amounts[h]+=v*(b-a)/(e-s)
    spans=sorted((s,e) for s,e,v,i in short);merged=[]
    for s,e in spans:
        if merged and s<=merged[-1][1]:merged[-1][1]=max(merged[-1][1],e)
        else:merged.append([s,e])
    for s,e in merged:
        for a,b,h in hour_parts(s,e):exposure[h]+=(b-a)/HOUR
    # Four observed hours of pooled-rate shrinkage per clock hour.
    pooled=sum(amounts)/max(sum(exposure),1e-9)
    rates=[(v+4*pooled)/(t+4) for v,t in zip(amounts,exposure)]
    norm=mean(rates)
    shape=[r/norm if norm else 1 for r in rates]
    if model=='circadian_recent':
        recent=quota_predict(train,origin,24,'recent_72h')/24
        baseline=.5*baseline+.5*recent
    prediction=sum(baseline*shape[h]*(b-a)/HOUR for a,b,h in hour_parts(origin,origin+horizon*HOUR))
    if model=='circadian_burst':
        # Blend a decaying six-hour pace adjustment into the circadian curve.
        expected=sum(baseline*shape[h]*(b-a)/HOUR for a,b,h in hour_parts(origin-6*HOUR,origin))
        observed=sum(v*overlap(s,e,origin-6*HOUR,origin)/(e-s) for s,e,v,i in train)
        ratio=max(.5,min(2,(observed+.15)/(expected+.15)))
        prediction=sum(baseline*shape[h]*(1+(ratio-1)*math.exp(-(a-origin)/HOUR/6))*(b-a)/HOUR for a,b,h in hour_parts(origin,origin+horizon*HOUR))
    return prediction

QUOTA_MODELS=['app_30d','recent_24h','recent_72h','circadian','circadian_recent','circadian_burst']

def quota_study(intervals):
    first=min(x[0] for x in intervals);last=max(x[1] for x in intervals)
    # Fixed chronological development/holdout boundary, no random shuffling.
    split=first+.7*(last-first)
    out={};details=[]
    for max_gap in (2,6):
        reliable=[x for x in intervals if x[1]-x[0]<=max_gap*HOUR]
        for horizon in (3,6,12,24,48):
            rows=collections.defaultdict(list); eligible=collections.Counter()
            for origin in range(math.ceil((first+48*HOUR)/(3*HOUR))*3*HOUR,int(last-horizon*HOUR)+1,3*HOUR):
                train=[x for x in intervals if x[1]<=origin]
                if not train:continue
                # Current app requires two hours of usable history per discovered account.
                ids={x[3] for x in intervals if x[0]<=origin}
                if any(sum(e-s for s,e,v,i in train if i==idx)<2*HOUR for idx in ids):continue
                endpoint=origin+horizon*HOUR
                if origin<split<endpoint:continue
                phase='holdout' if origin>=split else 'development'
                eligible[phase+'_possible']+=1
                cov=covered(origin,endpoint,reliable)
                # Score the full-horizon observed proxy only when short-interval
                # union coverage is high; this still cannot certify inactive accounts.
                if cov<.8:continue
                actual=sum(v*overlap(s,e,origin,endpoint)/(e-s) for s,e,v,i in reliable)
                for model in QUOTA_MODELS:
                    pred=quota_predict(train,origin,horizon,model)
                    rows[(phase,model)].append((actual,pred))
                    details.append({'origin':iso(origin),'horizon_h':horizon,'max_gap_h':max_gap,
                                    'phase':phase,'model':model,'actual':actual,'prediction':pred,'coverage':cov})
            out[f'gap{max_gap}_horizon{horizon}']={'eligible':dict(eligible),**{phase:{m:metrics(rows[(phase,m)]) for m in QUOTA_MODELS} for phase in ('development','holdout')}}
    # Local time activity audit, short gaps only, union exposure.
    short=[x for x in intervals if x[1]-x[0]<=2*HOUR]
    bins=[]
    for lo,hi in ((0,6),(6,12),(12,18),(18,24)):
        amount=0;exposure=0
        for s,e,v,i in short:
            for a,b,h in hour_parts(s,e):
                if lo<=h<hi:amount+=v*(b-a)/(e-s)
        for a,b,h in hour_parts(first,last):
            if lo<=h<hi:exposure+=(b-a)/HOUR*covered(a,b,short)
        bins.append({'local_hours':f'{lo:02d}–{hi:02d}','observed_units':amount,'union_observed_hours':exposure,'units_per_observed_hour':amount/exposure if exposure else None})
    return {'split':iso(split),'scores':out,'local_activity':bins},details

DAILY_MODELS=['mean_all','mean_7','mean_28','mean_90','ewma_7','ewma_28','weekday_56','weekday_recent','median_28']

def daily_predict(train,date,model):
    if model=='mean_all':return mean([v for d,v in train])
    if model.startswith('mean_') or model.startswith('median_'):
        window=int(model.split('_')[1]);vals=[v for d,v in train if (date-d).days<=window]
        # Future horizon uses the frozen training cutoff; do not age values out.
        return statistics.median(vals) if vals and model.startswith('median') else mean(vals)
    if model.startswith('ewma_'):
        half=int(model.split('_')[1]);ws=[(v,2**(-(date-d).days/half)) for d,v in train]
        return sum(v*w for v,w in ws)/sum(w for v,w in ws)
    vals=[(d,v) for d,v in train if (date-d).days<=56]
    base=mean([v for d,v in vals]);same=[v for d,v in vals if d.weekday()==date.weekday()]
    weekday=(sum(same)+4*base)/(len(same)+4)
    if model=='weekday_recent':
        recent=mean([v for d,v in train if (date-d).days<=14])
        return weekday*(.5+.5*recent/base) if base else 0
    return weekday

def daily_study(accounts):
    # Account with longest history: other accounts do not have matching history.
    acc=max(accounts,key=lambda a:len((a.get('profile') or {}).get('dailyUsageBuckets',[])))
    profile=acc['profile'];raw={dt.date.fromisoformat(d['startDate']):d['tokens']/1e9 for d in profile['dailyUsageBuckets']}
    # Drop fetch day and previous UTC day to avoid partially reported current days.
    cutoff=dt.datetime.fromtimestamp(profile['fetchedAt']+EPOCH,UTC).date()-dt.timedelta(days=2)
    raw={d:v for d,v in raw.items() if d<=cutoff}
    first,last=min(raw),max(raw);split=first+dt.timedelta(days=int((last-first).days*.7))
    out={}
    for missing in ('omit','zero_assumption'):
        series={first+dt.timedelta(days=i):raw.get(first+dt.timedelta(days=i),0) for i in range((last-first).days+1)} if missing=='zero_assumption' else raw
        for horizon in (1,7):
            rows=collections.defaultdict(list)
            # Disjoint target windows for each horizon.
            for offset in range(56,(last-first).days-horizon+2,horizon):
                origin=first+dt.timedelta(days=offset)
                targets=[origin+dt.timedelta(days=i) for i in range(horizon)]
                if any(d not in series for d in targets):continue
                if origin<split<=targets[-1]:continue
                train=sorted((d,v) for d,v in series.items() if d<origin)
                phase='holdout' if origin>=split else 'development'
                actual=sum(series[d] for d in targets)
                for model in DAILY_MODELS:
                    # Model history windows anchored to origin, weekday follows
                    # target date. Shift history dates for non-weekday models so
                    # each future day uses exactly the same frozen level.
                    pred=0
                    for d in targets:
                        if model.startswith('weekday'):
                            hist=[(x,v) for x,v in train if (origin-x).days<=56]
                            base=mean([v for x,v in hist]);same=[v for x,v in hist if x.weekday()==d.weekday()]
                            value=(sum(same)+4*base)/(len(same)+4)
                            if model=='weekday_recent' and base:
                                recent=mean([v for x,v in train if (origin-x).days<=14]);value*=.5+.5*recent/base
                            pred+=value
                        else:pred+=daily_predict(train,origin,model)
                    rows[(phase,model)].append((actual,pred))
            out[f'{missing}_horizon{horizon}']={phase:{m:metrics(rows[(phase,m)]) for m in DAILY_MODELS} for phase in ('development','holdout')}
    return {'account':accounts.index(acc)+1,'first':str(first),'last':str(last),'split':str(split),
            'recorded_days':len(raw),'missing_days_inside_span':(last-first).days+1-len(raw),'scores_billions_tokens':out,
            'recent_weekday_means_billions':{str(i):mean([v for d,v in raw.items() if d.weekday()==i and (last-d).days<84]) for i in range(7)}}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--preferences',type=Path,default=Path.home()/'Library/Preferences/com.casperkristiansson.codex-runway.plist');parser.add_argument('--input',type=Path,help='Previously exported anonymized JSON');parser.add_argument('--export-input',type=Path);parser.add_argument('--output',type=Path,default=Path(__file__).parent/'local'/'results.json');args=parser.parse_args()
    if args.input:
        data=args.input.read_bytes();accounts=json.loads(data)
    else:
        prefs=plistlib.loads(args.preferences.read_bytes());raw=json.loads(prefs['codex-runway.accounts.v1'])
        accounts=[]
        for account in raw:
            clean={k:account[k] for k in ('planName','isEnabled') if k in account}
            clean['snapshots']=[{k:v for k,v in s.items() if k!='id'} for s in account['snapshots']]
            if account.get('profile'):clean['profile']=account['profile']
            accounts.append(clean)
        data=(json.dumps(accounts,indent=2)+'\n').encode()
    if args.export_input:args.export_input.write_bytes(data)
    intervals,audit=quota_intervals(accounts);quota,details=quota_study(intervals)
    now=max(x['capturedAt']+EPOCH for a in accounts for x in a['snapshots'])
    latest={m:{str(h):quota_predict(intervals,now,h,m) for h in (6,12,24,48)} for m in QUOTA_MODELS}
    result={'input_sha256':hashlib.sha256(data).hexdigest(),'as_of':iso(now),'accounts':audit,'quota':quota,'daily':daily_study(accounts),'current_observed_demand_scenarios_units':latest,
            'limitations':['Quota targets are observed consumption proxies, not complete demand; only current-account readings refresh.',
            'Short-interval union coverage does not establish complete observation of inactive accounts.',
            'Quota intervals are uniformly apportioned; endpoints after origin are allowed only in evaluation labels, never training.',
            'Reset-crossing consumption and initial readings are excluded, matching app estimator.',
            'Quota folds overlap and are correlated; holdout is only about three days.',
            'Profile daily totals may have been revised; historical fetchedAt vintages unavailable.',
            'Daily token models are evaluated on the longest-history account, not a complete four-account historical portfolio.',
            'Tokens are not quota units. No token-to-quota conversion is validated.',
            'Omitted daily buckets are unknown; zero-filled sensitivity is an assumption.'], 'quota_predictions':details}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n');print(args.output)

if __name__=='__main__':main()
