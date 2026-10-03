import { showInspector, hideInspector } from './inspector.js';
import { createDropdown, closeDropdown, dropdownIsOpen } from './dropdown.js';
import { App } from '@modelcontextprotocol/ext-apps';
import { known, number, count, stamp, scale, health, series, heatmap, chartBounds, label, activityDetails, detailText, operationNotice, chartHoverIndex } from './presentation.js';
const uuid=()=>{if(crypto.randomUUID)return crypto.randomUUID();const b=crypto.getRandomValues(new Uint8Array(16));b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;const h=[...b].map(v=>v.toString(16).padStart(2,'0')).join('');return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;};
const $=id=>document.getElementById(id);
const el=(tag,cls,text)=>{const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node;};
const colors=['#625bca','#e89642','#46a18c','#bb70a9','#739dd1','#a3a5b8'];
const button=(text,fn,disabled=false,cls='')=>{const b=el('button',cls,text);b.type='button';b.disabled=disabled;b.onclick=()=>Promise.resolve(fn()).catch(fail);return b;};
const note=(text,cls='subtle')=>el('p',cls,text);
const select=(name,options,value,fn,key)=>createDropdown(name,options,value,v=>Promise.resolve().then(()=>fn(v)).catch(fail),key);
let native,data,tab='overview',accountID=null,received=0,failed=false,loading=false,pending=false,generation=0,mode='Daily';
let previewPreferences={};const chartObservers=new Set();
let usageDays=30,toolDays=7,messageDays=7,usageGroup='features',messageGroup='models',planWindow=10080,planDimension='thread_source',allChats=false,allPeriods=false;
const datasets=new Map(),chartPositions=new Map();let uncertain=null,noticeSource=null,noticeAt=0;
function fail(error){$('error').textContent=error.message||String(error);$('error').hidden=false;}
function notify(message,source='action'){noticeSource=source;noticeAt=Date.now();$('notice').textContent=message;$('notice').hidden=false;}
function clearNotice(){noticeSource=null;$('notice').textContent='';$('notice').hidden=true;}
function busy(){return pending||data?.bridgeBusy||data?.status?.busy;}
function mutationsDisabled(){return !native||!data?.available||busy();}
function segmented(name,options,value,fn,disabled=false){
 const group=el('div','segmented');group.setAttribute('role','group');group.setAttribute('aria-label',name);
 for(const [key,text] of options){const b=button(text,()=>fn(key),disabled);b.setAttribute('aria-pressed',String(key===value));group.append(b);}return group;
}
function displayPreference(values){
 if(native)return command('display',values);
 previewPreferences={...previewPreferences,...values};data.preferences={...data.preferences,...values};render();
}
function unit(value){return `${number(scale(value,data?.preferences?.percent),1)}${data?.preferences?.percent?'%':' units'}`;}
async function api(name,args={}) {
 if(native){const r=await native.callServerTool({name,arguments:args});if(r.isError)throw new Error(r.content?.[0]?.text||'Runway request failed.');return r.structuredContent;}
 if(name!=='runway_snapshot')throw new Error('Use the Codex sidebar or native Runway app for account actions.');
 const r=await fetch(`/api/snapshot?${new URLSearchParams(args)}`,{signal:AbortSignal.timeout(10000)});const value=await r.json();if(!r.ok)throw new Error(value.error||'Preview request failed.');return value;
}
function query(){return {section:tab,...(accountID?{accountID}:{}),days:365};}
function healthUI(){const h=health(data,received,Date.now(),failed);$('connection').textContent=h.text;$('connection').classList.toggle('stale',h.stale);}
function accept(value,scope){
 if(value?.version!==1)throw new Error('Unsupported Runway contract.');
 if(!value.available){failed=true;healthUI();notify(value.message||'Runway unavailable. Open the native app, then reload.','connection');if(!data)$('view').replaceChildren(note('Runway is unavailable. Open native Runway to display saved data.','empty'));return;}
 data=value;received=Date.now();failed=false;
 if(data.preview)data.preferences={...data.preferences,...previewPreferences};
 if(noticeSource==='connection')clearNotice();
 if(value.history)datasets.set(`history:${scope?.accountID||''}`,value.history);
 if(value.analytics)datasets.set(`analytics:${scope?.accountID||''}`,value.analytics);
 if(accountID&&!value.accounts.some(a=>a.id===accountID)){accountID=null;generation++;notify('That account is no longer available. Showing all active accounts.');}
 $('error').hidden=true;healthUI();
 // Leave a dialog, select menu or retention input intact while polling.
 if(!$('confirm').open&&!dropdownIsOpen()&&!document.activeElement?.matches('input,.chart svg,.heatmap-cell')&&!document.querySelector('.chart svg:hover,.heatmap:hover'))render();
 renderOperations();
}
async function refresh(force=false){
 if(loading)return;loading=true;$('reload').disabled=true;const scope=query(),epoch=generation;
 try{const value=await api('runway_snapshot',scope);if(epoch===generation)accept(value,scope);}
 catch(e){failed=true;healthUI();fail(e);}finally{loading=false;$('reload').disabled=false;}
 if(force&&!dropdownIsOpen())render();
}
async function command(action,args={},requestID=uuid()) {
 if(pending)throw new Error('Wait for the current request.');pending=true;
 const request={action,requestID,...args};uncertain=request;
 try{const result=await api('runway_command',request);if(result.error)throw new Error(result.error);uncertain=null;if(result.state==='running')notify(result.message,'operation');else if(['failed','interrupted'].includes(result.state))fail(new Error(result.message));}
 catch(e){fail(new Error(`${e.message} Reload to check native operation status before retrying.`));}
 finally{pending=false;await refresh(true);}
}
function renderOperations(){
 const status=operationNotice(data);
 if(status)notify(status.message,status.source);
 else if(['operation','recovery'].includes(noticeSource)||(noticeSource==='action'&&Date.now()-noticeAt>90000))clearNotice();
}
async function confirm(title,message,yes='Continue'){
 $('confirm-title').textContent=title;$('confirm-message').textContent=message;$('confirm-yes').textContent=yes;$('confirm').showModal();
 return new Promise(resolve=>$('confirm').addEventListener('close',()=>resolve($('confirm').returnValue==='yes'),{once:true}));
}
function tabs(){
 if($('tabs').children.length){for(const b of $('tabs').children){const selected=b.id===`tab-${tab}`;b.setAttribute('aria-selected',String(selected));b.tabIndex=selected?0:-1;}return;}
 $('tabs').replaceChildren(...['overview','settings','history','analytics'].map((name,i)=>{
  const b=button(name[0].toUpperCase()+name.slice(1),()=>enter(name));b.id=`tab-${name}`;b.role='tab';b.setAttribute('aria-controls','content');b.setAttribute('aria-selected',String(tab===name));b.tabIndex=tab===name?0:-1;
  b.onkeydown=e=>{if(['ArrowRight','ArrowLeft','Home','End'].includes(e.key)){e.preventDefault();const index=e.key==='Home'?0:e.key==='End'?3:(i+(e.key==='ArrowRight'?1:3))%4;enter(['overview','settings','history','analytics'][index]);$('tabs').children[index].focus();}};return b;
 }));
}
function enter(name){if(tab===name)return;closeDropdown();tab=name;accountID=null;generation++;$('content').scrollTop=0;tabs();render();refresh(true);}
function heading(title,subtitle,controls=[]){const h=el('div','section-head'),text=el('div');text.append(el('h2','',title),note(subtitle));const actions=el('div','actions');actions.append(...controls);h.append(text,actions);return h;}
function metrics(values){const grid=el('div','metrics');for(const [title,value,description] of values){const item=el('div','metric');item.append(el('strong','',value),el('span','',title));if(description)item.append(el('small','',description));grid.append(item);}return grid;}
function panel(title){const p=el('section','panel');if(title)p.append(el('h3','',title));return p;}
function accountFilter(){return select('Account',[['','All active accounts'],...data.accounts.map(a=>[a.id,`${a.name}${a.enabled?'':' · Inactive'}`])],accountID||'',value=>{accountID=value&&data.accounts.some(a=>a.id===value)?value:null;if(value&&!accountID)notify('That account is no longer available. Showing all active accounts.');generation++;render();refresh(true);});}
function activeName(){return accountID?data.accounts.find(a=>a.id===accountID)?.name||'Account':'All active accounts';}
function table(headers,rows){const wrap=el('div','table-wrap'),t=el('table'),head=el('thead'),tr=el('tr');headers.forEach((h,i)=>tr.append(el('th',i?'number':'',h)));head.append(tr);const body=el('tbody');for(const values of rows){const row=el('tr');values.forEach((v,i)=>{const td=el('td',i?'number':'');if(v instanceof Node)td.append(v);else td.textContent=v;row.append(td);});body.append(row);}t.append(head,body);wrap.append(t);return wrap;}
// A responsive SVG with a single keyboard focus target. Arrow/Home/End keys
// inspect points; hover and keyboard use the same detail string.
function chart({lines,start,end,bounds,details,events=[],title,stacked=false,compactCounts=false}) {
 const wrap=el('div','chart'),svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('preserveAspectRatio','none');svg.tabIndex=0;svg.setAttribute('role','group');svg.setAttribute('aria-label',`${title}. Use left and right arrow keys to inspect saved values.`);
 const detail=el('output','chart-details','Hover the graph or focus it and use arrow keys for details.');
 const points=lines.flatMap(l=>l.points).filter(p=>known(p.x)&&known(p.y));const times=[...new Set([...points.map(p=>p.x),...events.map(e=>e.date)].filter(t=>t>=start&&t<=end))].sort((a,b)=>a-b);const resetDates=events.filter(e=>known(e.date)&&e.date>=start&&e.date<=end).map(e=>e.date),resetTimes=new Set(resetDates);let hovering=false,pointerY=null;
 function draw(width){
 svg.replaceChildren();svg.setAttribute('viewBox',`0 0 ${width} 240`);const plotWidth=width-63;
 const [low,high]=bounds||chartBounds(points.map(p=>p.y));const x=t=>48+(t-start)/Math.max(1,end-start)*plotWidth,y=v=>210-(v-low)/Math.max(.01,high-low)*190;
 function shape(tag,attrs,text,parent=svg){const node=document.createElementNS(svg.namespaceURI,tag);Object.entries(attrs).forEach(([k,v])=>node.setAttribute(k,v));if(text!==undefined)node.textContent=text;parent.append(node);return node;}
 for(let i=0;i<4;i++){const v=low+(high-low)*i/3;shape('line',{x1:48,y1:y(v),x2:width-15,y2:y(v),stroke:'#eeeef5'});shape('text',{x:40,y:y(v)+3,'text-anchor':'end'},compactCounts?count(v,'short'):number(v,1));}
 for(let i=0;i<4;i++){const t=start+(end-start)*i/3;shape('text',{x:x(t),y:234,'text-anchor':i===0?'start':i===3?'end':'middle'},stamp(t).split(',').slice(0,1).join(','));}
 const clipID=`clip-${uuid()}`;const defs=document.createElementNS(svg.namespaceURI,'defs'),clip=document.createElementNS(svg.namespaceURI,'clipPath'),rect=document.createElementNS(svg.namespaceURI,'rect');clip.id=clipID;Object.entries({x:48,y:10,width:plotWidth,height:200}).forEach(([k,v])=>rect.setAttribute(k,v));clip.append(rect);defs.append(clip);svg.append(defs);
 const bottoms=new Map();
 for(const [index,line] of lines.entries()){
  if(stacked){
   for(const p of line.points.filter(p=>known(p.y))){const bottom=bottoms.get(p.x)||0,top=bottom+p.y;bottoms.set(p.x,top);const barWidth=Math.max(3,Math.min(20,plotWidth/Math.max(1,(end-start)/86400)*.65));shape('rect',{x:x(p.x)-barWidth/2,y:y(top),width:barWidth,height:Math.max(0,y(bottom)-y(top)),fill:line.color||colors[index%colors.length],'clip-path':`url(#${clipID})`});}
   continue;
  }
  let last;const path=line.points.filter(p=>known(p.y)).map(p=>{const disconnected=last&&(p.segment!==last.segment||p.x-last.x>1.5*86400)&&line.gaps;const part=`${!last||disconnected?'M':'L'}${x(p.x)},${y(p.y)}`;last=p;return part;}).join(' ');
  shape('path',{d:path,fill:'none',stroke:line.color||colors[index%colors.length],'stroke-width':1.9,'stroke-dasharray':line.dashed?'5 4':'','clip-path':`url(#${clipID})`,'vector-effect':'non-scaling-stroke'});
  if(!line.dashed&&line.points.length<=90)for(const p of line.points.filter(p=>known(p.y)))shape('circle',{cx:x(p.x),cy:y(p.y),r:2.5,fill:line.color||colors[index%colors.length],'clip-path':`url(#${clipID})`});
 }
 for(const event of events.filter(e=>e.date>=start&&e.date<=end))shape('line',{x1:x(event.date),x2:x(event.date),y1:10,y2:210,stroke:'#65a597','data-reset-date':event.date,'stroke-dasharray':event.kind==='observed'?'':'3 4','stroke-width':1});
 const cursor=shape('line',{x1:48,x2:48,y1:10,y2:210,stroke:'#aaa7c9','stroke-dasharray':'3 3',visibility:'hidden'}),markers=shape('g',{'clip-path':`url(#${clipID})`,'data-chart-selection':''});let index=chartPositions.has(title)?Math.max(0,times.findIndex(t=>t>=chartPositions.get(title))):0;
 function inspect(i,show=true){
  if(!times.length)return;index=Math.max(0,Math.min(times.length-1,i));const t=times[index],content=details(t);chartPositions.set(title,t);detail.textContent=detailText(content);markers.replaceChildren();
  cursor.setAttribute('stroke',resetTimes.has(t)?'#408e7c':'#aaa7c9');cursor.setAttribute('stroke-width',resetTimes.has(t)?1.8:1);cursor.setAttribute('x1',x(t));cursor.setAttribute('x2',x(t));cursor.setAttribute('visibility',show?'visible':'hidden');
  if(!show)return;
  if(stacked){const bw=Math.max(5,Math.min(24,plotWidth/Math.max(1,(end-start)/86400)*.65+4));shape('rect',{x:x(t)-bw/2,y:10,width:bw,height:200,fill:'#5752cb','fill-opacity':'.09'},undefined,markers);}
  let total=0;for(const [i,line] of lines.entries())for(const p of line.points.filter(p=>p.x===t&&known(p.y))){total+=p.y;shape('circle',{cx:x(t),cy:y(stacked?total:p.y),r:4,fill:'white',stroke:line.color||colors[i%colors.length],'stroke-width':2},undefined,markers);}
  const rect=svg.getBoundingClientRect();showInspector(wrap,content,{x:rect.left+x(t)/width*rect.width,y:pointerY??rect.top+rect.height/2});
 }
 function dismiss(){cursor.setAttribute('visibility','hidden');markers.replaceChildren();hideInspector(wrap);}
 svg.onpointermove=e=>{hovering=true;pointerY=e.clientY;const r=svg.getBoundingClientRect(),t=start+(((e.clientX-r.left)/r.width*width-48)/plotWidth)*(end-start);const nearest=chartHoverIndex(times,resetDates,t,(end-start)/plotWidth*width/r.width);if(nearest>=0)inspect(nearest);};
 svg.onpointerleave=()=>{hovering=false;pointerY=null;if(document.activeElement!==svg)dismiss();};
 svg.onfocus=()=>{pointerY=null;requestAnimationFrame(()=>{if(document.activeElement===svg)inspect(index);});};svg.onblur=()=>{if(!hovering)dismiss();};
 svg.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();dismiss();}else if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();inspect(e.key==='Home'?0:e.key==='End'?times.length-1:index+(e.key==='ArrowRight'?1:-1));}};
 if(chartPositions.has(title))inspect(index,hovering||document.activeElement===svg);
 }
 draw(640);const observer=new ResizeObserver(entries=>{const width=entries[0].contentRect.width;if(width>0)draw(Math.max(220,width));});observer.observe(svg);chartObservers.add(observer);
 wrap.append(svg,detail);return wrap;
}
function overview(){
 const root=el('div','overview-page');root.append(heading('Overview','Capacity and usage across your enabled accounts',[
  button(data.status.refreshing?'Refreshing…':'Refresh usage',()=>command('refresh'),mutationsDisabled()||data.status.recoveryPending,'primary')]));
 const report=data.overview,p=data.preferences,summary=panel();summary.classList.add('summary-panel');
 summary.append(metrics([
  ['Combined capacity',unit(report.remaining),`of ${unit(report.total)} · Pro 20× = 100%`],
  ['Daily pace',known(report.ratePerDay)?`${unit(report.ratePerDay)} / day`:'—',known(report.averageHistoryHours)?`Based on ${number(report.averageHistoryHours/24,1)} days of observations`:'Not enough observed history'],
  ['Forecast',report.issue?'Unavailable':report.exhaustedAt?'Projected shortfall':report.prediction.length?'Projected runway':'Learning',report.exhaustedAt?`Exhaustion ${stamp(report.exhaustedAt)}`:report.usesTimeOfDay?'Follows observed time-of-day usage':'Steady pace while learning']
 ]));root.append(summary);
 const capacity=panel(),head=el('div','panel-head');head.append(el('h3','','Capacity over time'),segmented('Capacity view',[['graph','Graph'],['table','Table']],p.mode,v=>displayPreference({mode:v}),native&&mutationsDisabled()));capacity.append(head);
 const controls=el('div','toolbar chart-toolbar');controls.append(select('Time range',[['overview','Forecast'],['hour','Past hour'],['sixHours','Past 6 hours'],['day','Past day'],['threeDays','Past 3 days'],['week','Past week']],p.range,v=>displayPreference({range:v})));
 controls.append(segmented('Capacity scale',[['percent','%'],['units','Units']],p.percent?'percent':'units',v=>displayPreference({percent:v==='percent'}),native&&mutationsDisabled()));for(const c of controls.querySelectorAll('.dropdown-trigger')){c.disabled=mutationsDisabled();if(!native)c.title='Choose a time range in the Codex sidebar or native Runway.';}capacity.append(controls);
 if(report.historyTruncated)capacity.append(note('Showing the latest 2,500 readings. Table totals use the complete saved history.'));
 if(report.issue)capacity.append(note(report.issue,'warn'));
 if(known(report.shortfallUnits))capacity.append(note(`Projected deficit ${unit(report.shortfallUnits)} at ${stamp(report.shortfallAt)}.`,'warn'));
 if(report.stale||report.assumedResets)capacity.append(note(`${report.stale?'Some account readings are stale. ':''}${report.assumedResets?'Passed resets are assumed refills; their next reset is unknown.':''}`,'warn'));
 if(p.mode==='graph'){
  if(report.history.length||report.prediction.length){
   const all=[...report.history,...report.prediction];capacity.append(chart({title:'Combined allowance',start:report.start,end:report.end,bounds:chartBounds(all.filter(v=>v.date>=report.start).map(v=>scale(v.units,p.percent)),p.range==='overview'?scale(report.total,p.percent):null),events:report.resets,
    lines:[{points:report.history.map(v=>({x:v.date,y:scale(v.units,p.percent),segment:v.segment})),gaps:false},{points:report.prediction.map(v=>({x:v.date,y:scale(v.units,p.percent)})),dashed:true,color:colors[0]}],
    details:t=>({heading:stamp(t),rows:[...all.filter(v=>v.date===t).map(v=>({label:report.prediction.includes(v)?'Predicted':'Saved / interpolated',value:unit(v.units),color:colors[0]})),...report.resets.filter(r=>r.date===t).map(r=>({label:r.account,value:`${r.kind} reset${known(r.after)?` → ${unit(r.after)}`:''}`,color:'#65a597'}))]})}));
   const legend=el('div','legend');['Saved / interpolated','Predicted · dashed','Resets'].forEach((text,i)=>{const n=el('span','',text);n.style.setProperty('--color',i===2?'#65a597':colors[0]);legend.append(n);});capacity.append(legend);
  }else capacity.append(note('No saved capacity readings for this range.','empty'));
 }else capacity.append(table(['Interval','Used','Balance'],report.intervals.map(r=>{const name=el('div','',`${stamp(r.start)} – ${stamp(r.end)}`);if(r.resets.length)name.append(el('small','',r.resets.map(v=>`${v.account}: ${v.kind} reset`).join(' · ')));return [name,unit(r.used),unit(r.balance)];})));
 if(report.notes?.length){const assumptions=el('details','data-notes');assumptions.append(el('summary','','Forecast details'),...report.notes.map(n=>note(n)));capacity.append(assumptions);}root.append(capacity);
 const accountsHead=el('div','panel-head accounts-heading');accountsHead.append(el('h3','','Enabled accounts'),button('Manage accounts',()=>enter('settings'),false,'text-button'));root.append(accountsHead);
 if(!data.currentAccountID)root.append(note('Current sign-in is unknown until Runway refreshes or verifies it.'));
 const cards=el('div','accounts');for(const a of data.accounts.filter(a=>a.enabled)){
  const card=panel();card.classList.add('account');if(a.current)card.classList.add('current');
  const head=el('div','account-head'),identity=el('div');identity.append(el('h3','',a.name),note(a.email));head.append(identity,el('strong','',known(a.remainingPercent)?`${number(a.remainingPercent)}% left`:'—'));card.append(head);
  const tags=el('div','account-tags');tags.append(el('span','plan-badge',a.plan));if(a.current)tags.append(el('span','badge','Signed in'));if(a.stale)tags.append(el('span','badge stale-badge','Stale'));if(a.assumedReset)tags.append(el('span','badge stale-badge','Reset assumed'));card.append(tags);
  if(known(a.remainingPercent)){const meter=el('div','meter'),fill=el('span');fill.style.width=`${Math.max(0,Math.min(100,a.remainingPercent))}%`;meter.append(fill);card.append(meter);head.querySelector('strong').title='Remaining allowance';}
  const dates=el('dl','account-dates');for(const [name,value] of [['Updated',stamp(a.fetchedAt)],['Next reset',`${stamp(a.resetAt)}${known(a.bankedResets)&&a.bankedResets>0?` · ${a.bankedResets} banked`:''}`]]){dates.append(el('dt','',name),el('dd','',value));}dates.querySelector('dt').title='Last successful refresh';card.append(dates);
  if(known(a.secondaryUsedPercent))card.append(note(`Secondary: ${number(a.secondaryUsedPercent)}% used · reset ${stamp(a.secondaryResetAt)}`));
  const actions=el('div','actions account-actions'),refreshButton=button(a.refreshing?'Refreshing…':'Refresh usage',()=>command(a.current?'refresh':'refreshSaved',a.current?{}:{accountID:a.id}),mutationsDisabled()||!a.canRefresh);refreshButton.title=a.refreshReason;actions.append(refreshButton,button('History',()=>{enter('history');accountID=a.id;generation++;render();refresh(true);},false,'text-button'));card.append(actions);
  if(!a.canRefresh&&!a.current)card.append(note(a.refreshReason,'eligibility'));if(a.refreshError)card.append(note(a.refreshError,'error'));cards.append(card);
 }
 if(!cards.children.length)root.append(note(data.accounts.length?'All accounts are inactive. Enable accounts in Settings.':'Refresh to discover your signed-in account.','empty'));else root.append(cards);
 const upcoming=report.resets.filter(r=>r.kind==='scheduled'&&r.date>data.generatedAt);if(upcoming.length){const section=el('details','panel reset-list');section.append(el('summary','',`Upcoming resets · ${upcoming.length}`),table(['Account','Known reset time'],upcoming.map(r=>[r.account,stamp(r.date)])));root.append(section);}
 const layout=el('div','overview-body'),primary=el('div','overview-primary'),accountSection=el('section','overview-account-section');primary.append(capacity,...root.querySelectorAll('.reset-list'));accountSection.append(accountsHead);const identityNote=accountsHead.nextElementSibling;if(identityNote?.classList.contains('subtle'))accountSection.append(identityNote);if(cards.children.length)accountSection.append(cards);layout.classList.toggle('many-accounts',cards.children.length>4);layout.append(primary,accountSection);root.append(layout,note('Accounts that aren’t signed in show saved usage. Reset assumptions and predictions are estimates.','data-caption'));return root;
}
function settings(){
 const root=el('div','settings-page');root.append(heading('Settings','Manage dashboard accounts, saved logins, and backups'));
 const logins=panel('Saved logins'),controls=el('div','toolbar');controls.append(button('Add Account…',()=>command('add'),mutationsDisabled()||data.status.recoveryPending),button('Save current login',()=>command('save'),mutationsDisabled()||data.status.recoveryPending),button('Reload',()=>command('reloadLogins'),mutationsDisabled()));if(data.status.canCancel)controls.append(button('Cancel',()=>command('cancel'),pending));if(data.status.recoveryPending)controls.append(button('Recover Switch',async()=>{if(await confirm('Recover interrupted switch','Native Runway may close and reopen Codex while resolving the saved transaction.','Recover'))await command('recover');},mutationsDisabled()));logins.append(note('Saved sessions stay in device-local Keychain. Switching closes and reopens Codex.'),controls);
 for(const login of data.savedLogins){const row=el('div','row'),identity=el('div','identity');identity.append(el('strong','',login.email),note(`Saved ${stamp(login.savedAt)} · device-local Keychain`));const actions=el('div','actions');actions.append(button('Switch',async()=>{if(await confirm(`Switch to ${login.email}?`,'Codex will close and reopen. Runway continues the transaction independently, verifies the selected identity, and preserves rollback/recovery. Close CLI clients first. Reopen this hub for completion status.','Switch and restart Codex'))await command('switch',{loginID:login.id});},mutationsDisabled()||data.status.recoveryPending),button('Forget',async()=>{if(await confirm('Forget saved login?',`Remove ${login.email} from device-local Keychain. Your current login and account history remain available.`,'Forget'))await command('forget',{loginID:login.id});},mutationsDisabled()||data.status.recoveryPending,'danger'));row.append(identity,actions);logins.append(row);}
 if(!data.savedLogins.length)logins.append(note('No saved logins. Save the currently signed-in account, or Add Account to sign in through the native flow.','empty'));if(data.status.loginMessage)logins.append(note(data.status.loginMessage,data.status.loginError?'error':'subtle'));
 const accounts=panel('Dashboard accounts');accounts.append(note('Active accounts contribute to capacity. Changing this does not switch your Codex login.'));data.accounts.forEach((a,i)=>{const row=el('div','row account-setting'),identity=el('div','identity');row.append(el('span','order-index',String(i+1)));identity.append(el('strong','',a.name),note(`${a.email} · ${a.plan}`));if(a.current)identity.append(el('span','badge','Signed in'));const actions=el('div','actions');for(const [offset,text] of [[-1,'↑'],[1,'↓']]){const move=button(text,()=>command('move',{accountID:a.id,offset}),mutationsDisabled()||(offset<0?i===0:i===data.accounts.length-1),'icon-button');move.title=move.ariaLabel=`Move ${a.name} ${offset<0?'up':'down'}`;actions.append(move);}const enabled=button(a.enabled?'Active':'Inactive',()=>command('enable',{accountID:a.id,enabled:!a.enabled}),mutationsDisabled());enabled.classList.add('account-toggle');enabled.setAttribute('aria-pressed',a.enabled);enabled.setAttribute('aria-label',`${a.name}: ${a.enabled?'Active':'Inactive'} in dashboard`);enabled.title='Enable or exclude from the dashboard; does not switch the signed-in account.';actions.append(enabled);row.append(identity,actions);accounts.append(row);});root.append(accounts,logins);
 const backup=panel('Backups'),b=data.backup;backup.append(note(b.destination||'Choose a native folder to start backups.'));const actions=el('div','toolbar');actions.append(button('Choose Folder…',()=>command('chooseBackupFolder'),mutationsDisabled()),button(b.working?'Backing up…':'Back Up Now',()=>command('backupNow'),mutationsDisabled()||!b.destination||b.working));backup.append(actions);
 const enabled=el('label','', 'Back up automatically'),check=el('input');check.type='checkbox';check.checked=b.enabled;check.disabled=mutationsDisabled()||!b.destination;check.onchange=()=>command('backupEnabled',{enabled:check.checked});enabled.prepend(check);const retention=el('label','', 'Keep daily backups (days)'),days=el('input');days.type='number';days.min=1;days.max=365;days.value=b.keepDailyDays;days.disabled=mutationsDisabled()||!b.destination;days.onchange=()=>{if(days.checkValidity())command('backupRetention',{keepDailyDays:Number(days.value)});};retention.append(days);const fields=el('div','toolbar');fields.append(enabled,retention);backup.append(fields,note(`Last backup: ${stamp(b.lastCompletedAt)}`),note('One automatic ZIP per local day; first monthly copy kept permanently. ZIPs are unencrypted and exclude credentials.'));if(b.error)backup.append(note(b.error,'error'));root.append(backup);
 const receipts=el('details','panel operation-history');receipts.append(el('summary','','Recent native operations'));if(data.operations.length)receipts.append(table(['Action','State','Finished'],[...data.operations].reverse().slice(0,8).map(o=>[`${o.action} · ${o.id.slice(0,8)}`,o.state,stamp(o.finishedAt)])));else receipts.append(note('No hub operations yet.'));
 if(uncertain)receipts.append(button('Retry last request with same ID',()=>command(uncertain.action,Object.fromEntries(Object.entries(uncertain).filter(([k])=>!['action','requestID'].includes(k))),uncertain.requestID),mutationsDisabled()));root.append(receipts);return root;
}
function history(){
 const root=el('div','history-page');root.append(heading('History','Profile totals and token activity',[accountFilter(),button(data.status.profileRefreshing?'Refreshing…':'Refresh profile',()=>command('refreshProfile'),mutationsDisabled()||data.status.recoveryPending)]));
 const h=datasets.get(`history:${accountID||''}`);if(!h){root.append(note('Loading saved profile…','empty'));return root;}
 if(!h.available){root.append(note('No saved profile yet. Refresh profile fetches the currently signed-in account.','empty'));return root;}
 const profile=el('section','history-profile'),identity=el('div','profile-identity'),avatar=el('div','profile-avatar');
 if(accountID)avatar.textContent=activeName().slice(0,2).toUpperCase();else {
  const icon=document.createElementNS('http://www.w3.org/2000/svg','svg');icon.setAttribute('viewBox','0 0 24 24');icon.setAttribute('aria-hidden','true');
  icon.innerHTML='<circle cx="9" cy="8" r="3"/><path d="M3 20v-3a6 6 0 0 1 12 0v3zM16 5a3 3 0 0 1 0 6v-6zM17 13a5 5 0 0 1 4 5v2h-4z"/>';avatar.append(icon);
 }
 identity.append(avatar,el('h3','',activeName()));const account=data.accounts.find(a=>a.id===accountID);identity.append(note(account?`${account.email} · ${account.plan}`:`${h.savedCount} of ${h.accountCount} profiles saved`));profile.append(identity);
 const totals=metrics(['Lifetime tokens','Peak tokens','Longest chat','Current streak','Longest streak'].map(name=>[name,h.stats[name]]));totals.classList.add('profile-totals');profile.append(totals);
 const activity=panel();activity.classList.add('activity-calendar');const activityHead=el('div','panel-head');activityHead.append(el('h3','','Token activity'),segmented('Activity display',[['Daily','Daily'],['Weekly','Weekly'],['Cumulative','Cumulative']],mode,v=>{mode=v;render();}));activity.append(activityHead);
 if(!h.hasDailyData)activity.append(note('Daily coverage is incomplete. This view includes only saved profiles.','warn'));
 const weeks=heatmap(h.days,mode,data.generatedAt*1000),calendar=el('div','calendar'),grid=el('div','heatmap'),months=el('div','heatmap-months');
 for(const n of [grid,months])n.style.setProperty('--weeks',weeks.length);grid.role='group';grid.setAttribute('aria-label',`${mode} token activity. Arrow keys navigate; Home and End select the first and last cells.`);
 const details=el('output','heatmap-detail',mode==='Daily'?'Each cell is one day. Hover or use arrow keys to inspect activity.':mode==='Weekly'?'Each column is one week. Bar height shows its total tokens.':'Each column shows the running token total, filled from the bottom.');
 const cells=[],days=weeks.flat(),entry=days.findLastIndex(d=>!d.hidden&&d.value>0);
 days.forEach((d,index)=>{
  const b=button('',()=>{},false);b.tabIndex=index===Math.max(0,entry)?0:-1;b.className=`heatmap-cell level-${d.level}`;if(d.hidden){b.style.visibility='hidden';b.setAttribute('aria-hidden','true');}
  const dateLabel=mode==='Daily'?d.date:`Week of ${d.week}`,text=`${dateLabel} · ${count(d.value)} tokens${mode==='Cumulative'?' · Cumulative total':''}`;b.setAttribute('aria-label',`${dateLabel} · ${number(d.value)} tokens${mode==='Cumulative'?' · Cumulative total':''}`);
  function inspect(){
   details.textContent=text;cells.forEach((c,i)=>c.classList.toggle('is-inspected',mode==='Daily'?i===index:Math.floor(i/7)===Math.floor(index/7)));const rect=b.getBoundingClientRect();
   showInspector(grid,{heading:dateLabel,rows:[{label:mode==='Daily'?'Tokens':mode==='Weekly'?'Weekly tokens':'Cumulative tokens',value:count(d.value),color:'#2e66c9'}]},{x:rect.left+rect.width/2,y:rect.top+rect.height/2},'heatmap');
  }
  b.onpointerenter=inspect;b.onfocus=()=>requestAnimationFrame(()=>{if(document.activeElement===b)inspect();});b.onblur=()=>{if(!grid.matches(':hover')){hideInspector(grid);cells.forEach(c=>c.classList.remove('is-inspected'));}};b.onkeydown=e=>{if(e.key==='Escape'){e.preventDefault();hideInspector(grid);cells.forEach(c=>c.classList.remove('is-inspected'));return;}const offsets={ArrowLeft:-7,ArrowRight:7,ArrowUp:-1,ArrowDown:1};if(e.key in offsets||['Home','End'].includes(e.key)){e.preventDefault();const next=e.key==='Home'?0:e.key==='End'?days.findLastIndex(c=>!c.hidden):Math.max(0,Math.min(cells.length-1,index+offsets[e.key]));if(!days[next].hidden){cells.forEach(c=>c.tabIndex=-1);cells[next].tabIndex=0;cells[next].focus();}}};cells.push(b);grid.append(b);
 });grid.onpointerleave=()=>{if(!grid.contains(document.activeElement)){hideInspector(grid);cells.forEach(c=>c.classList.remove('is-inspected'));}};
 let prior='';weeks.forEach((week,i)=>{const month=week[0].date.slice(0,7);if(month!==prior&&i>0&&i<weeks.length-2){const m=el('span','',new Date(week[0].date+'T12:00:00Z').toLocaleString(undefined,{month:'short',timeZone:'UTC'}));m.style.gridColumn=String(i+1);m.dataset.month=week[0].date.slice(5,7);months.append(m);}prior=month;});
 calendar.append(grid,months);activity.append(calendar);
 const legend=el('div','heatmap-legend');legend.append(el('span','','Less'));for(let level=0;level<5;level++)legend.append(el('i',`level-${level}`));legend.append(el('span','','More'));
 const calendarFooter=el('div','calendar-footer');calendarFooter.append(details,legend);activity.append(calendarFooter);profile.append(activity,note(`Saved ${stamp(h.fetchedAt)} · Activity can lag by about six hours`,'data-caption'));
 if(h.savedCount<h.accountCount)profile.append(note('Some accounts have no saved profile. Their activity is unavailable.','warn'));root.append(profile);return root;
}
function activityPanel(title,type,group,days,changeDays,changeGroup,showPeriod=true){
 const a=datasets.get(`analytics:${accountID||''}`),p=panel(),controls=el('div','toolbar');if(showPeriod)controls.append(segmented(`${title} period`,[['7','7d'],['30','30d'],['365','1y']],String(days),v=>{changeDays(Number(v));render();}));if(changeGroup)controls.append(select('Group by',type==='usage'?[['features','Feature'],['models','Model'],['surfaces','Surface']]:[['models','Model'],['surfaces','Surface']],group,v=>{changeGroup(v);render();},`${type} grouping`));const head=el('div','panel-head');head.append(el('h3','',title),controls);p.append(head);
 const s=series(a.accounts,type,group,days,data.generatedAt*1000);if(!s.rows.length||!s.names.length){p.append(note('No activity readings saved for this period.','empty'));return p;}
 p.append(note(`${type==='usage'?number(s.total,1):count(s.total)} ${type==='usage'?'% of limit':type==='messages'?'messages':'calls'} across saved readings`,'activity-total'));
 const start=data.generatedAt-(days-1)*86400-43200,end=data.generatedAt+43200;
 p.append(chart({title,start,end,stacked:type==='usage',compactCounts:type!=='usage',bounds:[0,Math.max(1,...s.rows.map(r=>type==='usage'?Object.values(r.values).reduce((s,v)=>s+v,0):Math.max(...Object.values(r.values))))],lines:s.names.map((name,index)=>({color:colors[index],gaps:true,points:s.rows.map(r=>({x:Date.parse(`${r.day}T12:00:00Z`)/1000,y:r.values[name]}))})),details:t=>{const day=new Date(t*1000).toISOString().slice(0,10),row=s.rows.find(r=>r.day===day);if(!row)return {heading:day,rows:[],caption:'No saved reading'};const content=activityDetails(day,row.values,type);content.rows.forEach((r,i)=>r.color=colors[i%colors.length]);return content;}}));
 const legend=el('div','legend');s.names.forEach((name,index)=>{const n=el('span','',name);n.style.setProperty('--color',colors[index]);legend.append(n);});p.append(legend);
 if(type==='usage'){const total=Object.values(s.totals).reduce((s,v)=>s+v,0);p.append(table(['Category','Share of saved usage'],Object.entries(s.totals).sort((a,b)=>b[1]-a[1]).slice(0,6).map(([name,v])=>[name,`${number(v/total*100,1)}%`])));}return p;
}
function analytics(){
 const root=el('div','analytics-page');root.append(heading('Analytics','Usage, chats, and tool activity',[accountFilter(),button(data.status.analyticsRefreshing?'Syncing…':'Sync now',()=>command('refreshAnalytics'),mutationsDisabled()||!data.currentAccountID||data.status.recoveryPending)]));
 const a=datasets.get(`analytics:${accountID||''}`);if(!a){root.append(note('Loading saved Analytics…','empty'));return root;}
 
 if(!a.savedCount){root.append(note('Analytics appears after the signed-in account syncs. Other accounts display their saved archives.','empty'));return root;}
 const coverage=el('details','data-coverage');coverage.append(el('summary','',`Saved data · ${a.savedCount} of ${a.accountCount} accounts`),note('Charts use saved readings. Missing accounts and gaps are unavailable, rather than zero.'));if(!accountID)coverage.append(note('Combined usage is weighted by each saved account’s plan capacity.'));for(const source of a.sources||a.accounts)coverage.append(note(`${source.name} · Saved ${stamp(source.fetchedAt)}${source.freshness?` · ${source.freshness}`:''}`));root.append(coverage);
 root.append(activityPanel('Usage history','usage',usageGroup,usageDays,v=>usageDays=v,v=>usageGroup=v));
 const chats=panel('Top chats'),all=a.accounts.flatMap(v=>v.chats.filter(c=>known(c.weeklyPercent)).map(c=>({...c,account:c.account||v.name}))).sort((a,b)=>b.weeklyPercent-a.weeklyPercent);chats.append(note('Each task’s saved plan and credit usage.'));if(all.length)chats.append(table(['Chat','% weekly limit','Credits used'],all.slice(0,allChats?100:5).map(c=>{const name=el('div','',c.title);name.append(el('small','',`${c.account} · ${c.status}`));if(known(c.fiveHourPercent))name.append(el('small','',`5-hour limit: ${number(c.fiveHourPercent,1)}%`));return [name,`${number(c.weeklyPercent,1)}%`,c.credits==null?'—':/^[+-]?0(?:\.0*)?(?:e[+-]?\d+)?$/i.test(c.credits)?'0':c.credits];})));else chats.append(note('No task-level usage saved yet.','empty'));if(all.length>5)chats.append(button(allChats?'Show less':'Show more',()=>{allChats=!allChats;render();}));
 const plans=panel('Plan-limit periods'),toolbar=el('div','toolbar');toolbar.append(select('Window',[['10080','Weekly'],['300','5 hours']],String(planWindow),v=>{planWindow=Number(v);render();}),select('Group by',[['thread_source','Feature'],['model','Model'],['surface','Surface']],planDimension,v=>{planDimension=v;render();},'plan grouping'));plans.append(toolbar);
 const periods=a.accounts.flatMap(v=>v.periods.filter(p=>p.windowMinutes===planWindow).map(p=>({...p,account:p.account||v.name}))).sort((a,b)=>b.end.localeCompare(a.end));if(!periods.length)plans.append(note('No plan-limit periods saved yet.','empty'));
 for(const period of periods.slice(0,allPeriods?100:5)){const d=el('details'),summary=el('summary','',`${period.start.slice(0,10)} — ${period.end.slice(0,10)} · ${period.account} · ${known(period.usedPercent)?number(period.usedPercent,1)+'%':'Unknown'}${period.complete?'':' · Accounting incomplete'}`);d.append(summary,note(`${stamp(Date.parse(period.start)/1000)} — ${stamp(Date.parse(period.end)/1000)}`));const rows=period.breakdowns.find(b=>b.dimension===planDimension)?.rows||[];if(rows.length)d.append(table(['Category','% limit'],rows.map(v=>[label(v.name),`${number(v.value,1)}%`])));else d.append(note('No breakdown saved for this period.'));plans.append(d);}if(periods.length>5)plans.append(button(allPeriods?'Show less':`Show all ${Math.min(100,periods.length)} periods`,()=>{allPeriods=!allPeriods;render();},false,'text-button'));const detailGrid=el('div','analytics-grid');detailGrid.classList.toggle('expanded-details',allChats||allPeriods);detailGrid.append(chats,plans);root.append(detailGrid);
 const toolHeader=el('div','panel-head');toolHeader.append(el('h3','','Tool activity'),segmented('Tool activity period',[['7','7d'],['30','30d'],['365','1y']],String(toolDays),v=>{toolDays=Number(v);render();}));const tools=el('div','analytics-grid');tools.append(activityPanel('Plugins called','plugins','items',toolDays,v=>toolDays=v,null,false),activityPanel('Skills used','skills','items',toolDays,v=>toolDays=v,null,false));root.append(toolHeader,tools,activityPanel('Messages','messages',messageGroup,messageDays,v=>messageDays=v,v=>messageGroup=v));return root;
}
function render(){
 closeDropdown();hideInspector();
 for(const observer of chartObservers)observer.disconnect();chartObservers.clear();
 tabs();$('content').setAttribute('aria-labelledby',`tab-${tab}`);$('content').setAttribute('aria-label',tab[0].toUpperCase()+tab.slice(1));
 if(!data?.available)return;
 const scrollTop=$('content').scrollTop;
 const focused=document.activeElement;const wasInside=focused?.closest?.('main');const focusText=focused?.textContent;const focusLabel=focused?.getAttribute('aria-label');const focusKey=focused?.dataset?.focusKey;
 $('view').replaceChildren(({overview,settings,history,analytics})[tab]());
 if(focused&&focused!==document.body&&focused.id!=='content'&&wasInside){
  const candidate=[...$('content').querySelectorAll('button,select,input,svg')].find(n=>focusKey?n.dataset.focusKey===focusKey:focusLabel?n.getAttribute('aria-label')===focusLabel:n.textContent===focusText);candidate?.focus({preventScroll:true});
 }
 $('content').scrollTop=scrollTop;
 for(const name of ['usageError','profileError','analyticsError'])if(data.status[name]&&((tab==='overview'&&name==='usageError')||(tab==='history'&&name==='profileError')||(tab==='analytics'&&name==='analyticsError')))$('view').prepend(note(data.status[name],'error'));
 if(data.accountsTruncated)$('view').prepend(note(`Showing the first 128 of ${data.accountCount} accounts. Use native Runway for the complete account list.`, 'warn'));

}
$('reload').onclick=()=>refresh(true);$('open-native').onclick=()=>command('openNative');
async function start(){
 if(window.parent!==window||new URLSearchParams(location.search).get('layout')==='embedded')document.body.classList.add('embedded');
 tabs();
 if(window.parent!==window){native=new App({name:'Codex Runway',version:'1.0.0'},{},{autoResize:true});native.ontoolresult=result=>{if(!data&&result.structuredContent?.available!==undefined)accept(result.structuredContent,{section:'overview'});};try{await native.connect();}catch(e){failed=true;healthUI();fail(e);$('view').replaceChildren(note('The embedded host connection is unavailable. Open native Codex Runway from Applications.', 'empty'));$('open-native').disabled=true;return;}}
 else $('open-native').disabled=true;
 await refresh();setInterval(()=>{if(!document.hidden&&!$('confirm').open)refresh();},5000);setInterval(healthUI,1000);document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
}let resizeTimer;window.addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{if(!$('confirm').open)render();},150);});start();
