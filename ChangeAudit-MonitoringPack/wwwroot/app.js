'use strict';
const $ = id => document.getElementById(id);
const demo = new URLSearchParams(location.search).get('demo') === '1';
const state = { data: null, events: [], failed: false };
const names = { Matched:'Matches main', RepositoryMatch:'Matches main', Different:'Different SQL', NotFound:'Not found', Unknown:'Unknown', NotAssessed:'Not assessed', NeedsReview:'Needs review', RepositoryException:'Repository gap', Pending:'Pending' };
const good = new Set(['Matched','RepositoryMatch']);
const bad = new Set(['Different','NotFound','RepositoryException']);
function node(tag, text, cls) { const e=document.createElement(tag); if(text!==undefined)e.textContent=String(text); if(cls)e.className=cls; return e; }
function icon(paths, cls) { const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('width','16');svg.setAttribute('height','16');svg.setAttribute('fill','none');svg.setAttribute('stroke','currentColor');svg.setAttribute('stroke-width','2');svg.setAttribute('stroke-linecap','round');svg.setAttribute('stroke-linejoin','round');svg.setAttribute('aria-hidden','true');if(cls)svg.setAttribute('class',cls);for(const d of paths){const path=document.createElementNS('http://www.w3.org/2000/svg','path');path.setAttribute('d',d);svg.append(path);}return svg;}
function badge(status){return node('span',names[status]||status,'badge '+(good.has(status)?'good':bad.has(status)?'bad':'warn'));}
function daySast(date=new Date()){return new Date(date.getTime()+7200000).toISOString().slice(0,10);}
function timeSast(value){return new Intl.DateTimeFormat('en-GB',{timeZone:'Africa/Johannesburg',hour:'2-digit',minute:'2-digit',second:'2-digit'}).format(new Date(value));}
function safeLink(url,label){try{const u=new URL(url);if(u.protocol==='https:'&&u.hostname==='dev.azure.com'){const a=node('a',label);a.href=u.href;a.target='_blank';a.rel='noopener noreferrer';return a;}}catch{}return node('span',label);}
function render(){
  const data=state.data;if(!data)return;
  const today=daySast();
  state.events=(data.events||[]).filter(e=>Number.isFinite(Date.parse(e.eventAtUtc))&&daySast(new Date(e.eventAtUtc))===today);
  $('date').textContent=today+' · South African time';
  const generated=Date.parse(data.generatedAtUtc), health=data.latestRun?.health||{};
  const stale=!Number.isFinite(generated)||Date.now()-generated>15*60000||generated>Date.now()+60000;
  $('generated').textContent=Number.isFinite(generated)?'Exported '+timeSast(data.generatedAtUtc)+' SAST':'Export time unavailable';
  const notices=[];
  if(demo)notices.push('DEMO — synthetic examples, not production audit results.');
  if(state.failed)notices.push('Refresh failed. Showing the last loaded snapshot.');
  if(stale)notices.push('STALE DATA — collector/export is more than 15 minutes old or its clock is inconsistent.');
  if(data.displayDate!==today)notices.push('This export is from another day. Yesterday’s events are hidden; waiting for today’s export.');
  if(data.latestRun?.Status!=='OK')notices.push('Collector needs attention: '+(data.latestRun?.Status||'no completed run')+'.');
  for(const [key,value]of Object.entries(health)){if(value?.Reason)notices.push(key+': '+value.Reason);}
  if((data.totalToday||0)>(data.events||[]).length)notices.push('Display limit reached: some events are not included in this export.');
  const noticeText=notices.join(' ')||'Current collection · Affiliates SQL changes compared with Azure DevOps main · Sources are read-only';
  $('notice').replaceChildren(node('span',undefined,'notice-indicator'),node('span',noticeText,'notice-copy'));
  $('notice').className='notice '+(stale||state.failed?'error':notices.length?'warn':'');
  for(const [id,key,label]of [['health-sql','Source','SQL'],['health-repo','Repository','Azure DevOps']]){const h=health[key]||{};const branch=(h.Branch||'').replace('refs/heads/','');$(id).textContent=label+' · '+(branch||h.Status||'unknown');$(id).className=h.Status==='OK'?'ok':'bad';$(id).title=[h.Status,h.Commit,h.Reason].filter(Boolean).join(' · ');}
  const events=state.events;
  $('count-all').textContent=events.length;
  $('count-matched').textContent=events.filter(e=>e.overallStatus==='RepositoryMatch').length;
  $('count-repo').textContent=events.filter(e=>['Different','NotFound'].includes(e.repositoryStatus)).length;
  $('count-review').textContent=events.filter(e=>['NeedsReview','Pending'].includes(e.overallStatus)).length;
  const selected=$('database').value;$('database').replaceChildren(node('option','All databases'));$('database').firstChild.value='';
  for(const db of [...new Set(events.map(e=>e.DatabaseName))].sort()){const option=node('option',db);option.value=db;$('database').append(option);} $('database').value=selected;
  const query=$('search').value.toLowerCase(),db=$('database').value,status=$('status').value;
  const rows=events.filter(e=>(!db||e.DatabaseName===db)&&(!status||e.overallStatus===status)&&JSON.stringify([e.DatabaseName,e.SchemaName,e.ObjectName,e.ObjectType,e.EventType,e.LoginName,e.sqlCommand]).toLowerCase().includes(query));
  $('events').replaceChildren();
  for(const event of rows){const tr=node('tr');tr.append(node('td',timeSast(event.eventAtUtc)),node('td',event.LogId));const object=node('td');object.append(node('span',event.DatabaseName,'db'),node('span',(event.SchemaName?event.SchemaName+'.':'')+event.ObjectName,'object'));tr.append(object,node('td',event.ObjectType),node('td',event.EventType,'event-type'),node('td',event.LoginName));for(const s of [event.repositoryStatus,event.overallStatus]){const td=node('td');td.append(badge(s));tr.append(td);}const td=node('td'),button=node('button',undefined,'evidence-button');button.type='button';button.append(node('span','View evidence'),icon(['M5 12h14','m13 6 6 6-6 6']));button.addEventListener('click',()=>openDetail(event));td.append(button);tr.append(td);$('events').append(tr);}
  $('rows').textContent=rows.length+' of '+events.length+' changes';$('empty').hidden=rows.length>0;
}
function openDetail(event){
  $('detail-title').textContent=event.DatabaseName+' / '+(event.SchemaName||'')+'.'+event.ObjectName;
  $('detail-meta').textContent=event.ServerName+' · Log ID '+event.LogId+' · '+event.ObjectType+' · '+event.EventType+' · '+timeSast(event.eventAtUtc)+' SAST · '+event.LoginName;
  $('detail-verdicts').replaceChildren(badge(event.repositoryStatus),badge(event.overallStatus));
  const repo=event.evidence?.Repository||{};
  $('repo-evidence').replaceChildren(node('p',repo.Reason||'Not assessed'));
  for(const match of repo.Matches||[]){const p=node('p',match.Method+' · ');const url='https://dev.azure.com/BETSoftwareO365/Affiliates/_git/Affiliates.Database?path='+encodeURIComponent(match.Path)+'&version=GC'+encodeURIComponent(match.Commit);p.append(safeLink(url,match.Path+' @ '+match.Commit.slice(0,12)));$('repo-evidence').append(p);}
  for(const path of repo.CandidatePaths||[]){const p=node('p','Candidate definition · ');const url='https://dev.azure.com/BETSoftwareO365/Affiliates/_git/Affiliates.Database?path='+encodeURIComponent(path)+'&version=GC'+encodeURIComponent(repo.Commit||'');p.append(safeLink(url,path+(repo.Commit?' @ '+repo.Commit.slice(0,12):'')));$('repo-evidence').append(p);}
  $('sql').textContent=event.sqlCommand||'';$('detail').showModal();
}
async function refresh(){
  $('refresh').disabled=true;
  try{const response=await fetch(demo?'data/demo.json':'data/change-audit.json',{cache:'no-store'});if(!response.ok)throw new Error('HTTP '+response.status);const data=await response.json();if(data.schemaVersion!==1||!Array.isArray(data.events))throw new Error('Invalid snapshot');state.data=data;state.failed=false;if(demo){const now=new Date();data.generatedAtUtc=now.toISOString();data.displayDate=daySast(now);data.events.forEach((e,i)=>e.eventAtUtc=new Date(now.getTime()-(i+1)*600000).toISOString());}render();}
  catch{state.failed=true;if(state.data)render();else{$('notice').replaceChildren(node('span',undefined,'notice-indicator'),node('span','Monitoring data unavailable. Configure the collector and JSON export. No production results have been loaded.','notice-copy'));$('notice').className='notice error';$('empty').hidden=false;$('empty').textContent='Waiting for the first successful collection.';}}
  finally{$('refresh').disabled=false;}
}
for(const id of ['search','database','status'])$(id).addEventListener('input',render);
$('refresh').addEventListener('click',refresh);$('close').addEventListener('click',()=>$('detail').close());
refresh();setInterval(refresh,60000);
