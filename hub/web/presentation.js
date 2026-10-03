export const known = value => typeof value === 'number' && Number.isFinite(value);
export const number = (value, decimals=0) => known(value) ? value.toLocaleString(undefined,{maximumFractionDigits:decimals}) : '—';
const countFormats=Object.fromEntries(['long','short'].map(display=>[display,new Intl.NumberFormat('en',{notation:'compact',compactDisplay:display,maximumFractionDigits:1})]));
// Words make hover counts easy to read; short labels keep chart axes compact.
export const count = (value, display='long') => !known(value)?'—':Math.abs(value)>=1000?countFormats[display].format(value):number(value,display==='short'?1:0);
export const stamp = value => known(value) ? new Date(value*1000).toLocaleString(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}) : 'Unknown';
export const scale = (value, percent) => known(value) ? value*(percent?25:1) : null;
// Give a visible reset priority over denser readings within 12 screen pixels.
// The pixel-to-time scale comes from the actual responsive plot, not its range.
export function chartHoverIndex(times, resetDates, time, secondsPerPixel, snapPixels=12) {
 if(!times.length||!known(time))return -1;
 const resets=new Set(resetDates);let nearest=0,reset=-1;
 times.forEach((t,i)=>{
  if(Math.abs(t-time)<Math.abs(times[nearest]-time))nearest=i;
  if(resets.has(t)&&(reset<0||Math.abs(t-time)<Math.abs(times[reset]-time)))reset=i;
 });
 return reset>=0&&known(secondsPerPixel)&&secondsPerPixel>0&&Math.abs(times[reset]-time)<=secondsPerPixel*snapPixels?reset:nearest;
}
export const detailText = detail => [detail.heading,...detail.rows.map(r=>`${r.label}: ${r.value}`),detail.caption].filter(Boolean).join(' · ');
export function activityDetails(day, values, type) {
 const suffix=type==='usage'?'%':type==='messages'?' messages':' calls',entries=Object.entries(values);
 const total=entries.every(([,v])=>known(v))?entries.reduce((s,[,v])=>s+v,0):null;
 const format=v=>known(v)?`${type==='usage'?number(v,2):count(v)}${suffix}`:'—';
 return {heading:day,rows:entries.map(([label,value])=>({label,value:format(value)})),caption:`Daily total: ${format(total)}${type==='usage'&&known(total)?' of limit':''}`};
}
export function operationNotice(data, now=Date.now()/1000) {
 if(data?.status?.recoveryPending)return {source:'recovery',message:'A switch needs recovery. Open native Runway or use Recover Switch in Settings.'};
 const running=(data?.operations||[]).filter(o=>o.state==='running').at(-1);
 if(running)return {source:'operation',message:running.message+(data.status?.loginBusy&&data.status.loginMessage?` ${data.status.loginMessage}`:'')};
 const last=data?.operations?.at(-1);
 if(last&&['failed','interrupted'].includes(last.state)&&now-(last.finishedAt||last.startedAt)<90)return {source:'operation',message:last.message};
 return null;
}
export function health(data, received, now, failed=false) {
 if(!data?.available)return {text:'Runway unavailable',stale:true};
 if(failed||now-received>20000)return {text:'Connection stale · last saved view retained',stale:true};
 return {text:data.preview?'Read-only browser preview':'Connected to native Runway',stale:false};
}
const labels={task:'Tasks',tasks:'Tasks',user:'Tasks',memory_consolidation:'Memory updates',memory_update:'Memory updates',guardian_review:'Auto review',auto_review:'Auto review',commit_message:'Commit messages',subagent:'Subagents',thread_description:'Task descriptions',automation:'Automations',code_review:'Code review',desktop_app:'Desktop app',work_desktop:'Work desktop',vscode:'VS Code',cli:'CLI',web:'Web'};
export const label = value => labels[value]||String(value).replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase());
// Presentation aggregation only. Allowance forecasting and reset assumptions
// arrive calculated by Swift; no forecast model or persistence exists here.
export function series(accounts, type, group, days, now=Date.now()) {
 const since=new Date(now-(days-1)*86400000).toISOString().slice(0,10);
 const totalCapacity=accounts.reduce((sum,a)=>sum+(a.capacityUnits??1),0);
 const buckets=new Map();
 for(const a of accounts)for(const row of a[type]||[]) {
  if(row.date<since)continue;
  const values=type==='usage'?row[group]:type==='messages'?row[group]:row.items;
  const weight=type==='usage'&&accounts.length>1?(a.capacityUnits??1)/Math.max(totalCapacity,1):1;
  if(!buckets.has(row.date))buckets.set(row.date,new Map());
  const bucket=buckets.get(row.date);
  for(const item of values||[])if(known(item.value)) {
   const name=['features','surfaces'].includes(group)?label(item.name):item.name;
   bucket.set(name,(bucket.get(name)||0)+item.value*weight);
  }
  if(type==='messages'&&known(row.total)) {
   const remainder=Math.max(0,row.total-(values||[]).reduce((s,v)=>s+(known(v.value)?v.value:0),0));
   if(remainder>0)bucket.set('Other',(bucket.get('Other')||0)+remainder);
  }
 }
 const totals=new Map();for(const b of buckets.values())for(const [n,v] of b)totals.set(n,(totals.get(n)||0)+v);
 const selected=[...totals].filter(([n,v])=>n!=='Other'&&v>0).sort((a,b)=>b[1]-a[1]).slice(0,5).map(([n])=>n);
 const rest=[...totals].filter(([n])=>!selected.includes(n)).reduce((s,[,v])=>s+v,0);
 const names=rest>0?[...selected,'Other']:selected;
 const rows=[...buckets].sort((a,b)=>a[0].localeCompare(b[0])).map(([day,b])=>({day,values:Object.fromEntries(names.map(n=>[n,n==='Other'?[...b].filter(([k])=>!selected.includes(k)).reduce((s,[,v])=>s+v,0):b.get(n)??0]))}));
 return {names,rows,total:[...totals.values()].reduce((s,v)=>s+v,0),totals:Object.fromEntries(totals)};
}
export function heatmap(days,mode,now=Date.now()) {
 const today=new Date(now);today.setUTCHours(0,0,0,0);
 const first=new Date(today.getTime()-364*86400000);first.setUTCDate(first.getUTCDate()-first.getUTCDay());
 const values=new Map(days.map(d=>[d.date,d.tokens]));const weeks=[];let cumulative=0;
 for(let t=first.getTime();t<=today.getTime();t+=7*86400000) {
  const week=Array.from({length:7},(_,i)=>{const date=new Date(t+i*86400000).toISOString().slice(0,10);return {date,value:values.get(date)??0,future:t+i*86400000>today.getTime()};});
  const total=week.reduce((s,d)=>s+d.value,0);cumulative+=total;
  weeks.push(week.map(d=>({...d,value:mode==='Daily'?d.value:mode==='Weekly'?total:cumulative,week:week[0].date})));
 }
 const maximum=Math.max(1,...weeks.flat().map(d=>d.value));
 // Match native ProfileHeatmap: daily intensity has four levels; weekly
 // and cumulative totals are seven-cell bars filled from the bottom.
 return weeks.map(week=>week.map((d,row)=>({...d,
  level:mode==='Daily'?(d.value===0?0:Math.max(1,Math.ceil(d.value/maximum*4))):(d.value>0&&row>=7-Math.ceil(d.value/maximum*7)?4:0),
  hidden:mode==='Daily'&&d.future
 })));
}
export function chartBounds(values, fullScale=null) {
 const valid=values.filter(known);
 if(!valid.length)return [0,1];
 if(known(fullScale))return [0,Math.max(fullScale,...valid,1)];
 const min=Math.min(...valid),max=Math.max(...valid),padding=Math.max((max-min)*.12,.05);
 return [Math.max(0,min-padding),max+padding];
}
