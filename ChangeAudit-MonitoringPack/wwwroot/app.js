'use strict';
const $ = id => document.getElementById(id);
const demo = new URLSearchParams(location.search).get('demo') === '1';
const state = { data: null, events: [], failed: false };
const names = { Matched:'Matches master', Different:'Different SQL', NotFound:'Not found', Unknown:'Unknown', NotAssessed:'Not assessed', NeedsReview:'Needs review', Linked:'Linked — verify approval', EvidenceLinked:'Evidence linked', Approved:'Legacy approval — verify', NotFoundInScope:'No RAB matched', ApprovalAfterChange:'Late approval', LoggedAfterChange:'Logged late', OutsideWindow:'Outside window', NotApproved:'Not approved', Covered:'Legacy assessment — verify', RepositoryException:'Repository gap', RabException:'RAB exception', BothExceptions:'Both exceptions', Pending:'Pending' };
const good = new Set(['Matched']);
const bad = new Set(['Different','NotFound','NotFoundInScope','ApprovalAfterChange','LoggedAfterChange','OutsideWindow','NotApproved','RepositoryException','RabException','BothExceptions']);
function node(tag, text, cls) { const e=document.createElement(tag); if(text!==undefined)e.textContent=String(text); if(cls)e.className=cls; return e; }
function badge(status){return node('span',names[status]||status,'badge '+(good.has(status)?'good':bad.has(status)?'bad':'warn'));}
function daySast(date=new Date()){return new Date(date.getTime()+7200000).toISOString().slice(0,10);}
function timeSast(value){return new Intl.DateTimeFormat('en-GB',{timeZone:'Africa/Johannesburg',hour:'2-digit',minute:'2-digit',second:'2-digit'}).format(new Date(value));}
function safeLink(url,label){try{const u=new URL(url);if(u.protocol==='https:'&&['dev.azure.com','betsoftware.atlassian.net'].includes(u.hostname)){const a=node('a',label);a.href=u.href;a.target='_blank';a.rel='noopener noreferrer';return a;}}catch{}return node('span',label);}
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
  $('notice').textContent=notices.join(' ')||'Current collection · Master and RAB evidence assessed independently · External sources are read-only';
  $('notice').className='notice '+(stale||state.failed?'error':notices.length?'warn':'');
  for(const [id,key,label]of [['health-sql','Source','SQL'],['health-repo','Repository','Master'],['health-jira','Jira','Jira'],['health-policy','ApprovalPolicy','Approvers']]){const h=health[key]||{};$(id).textContent=label+' · '+(h.Status==='ManualReview'?'DBA review':(h.Status||'unknown'));$(id).className=h.Status==='OK'?'ok':'bad';$(id).title=h.Reason||'';}
  const events=state.events;
  $('count-all').textContent=events.length;
  $('count-covered').textContent=events.filter(e=>e.overallStatus==='EvidenceLinked').length;
  $('count-repo').textContent=events.filter(e=>['Different','NotFound'].includes(e.repositoryStatus)).length;
  $('count-rab').textContent=events.filter(e=>bad.has(e.rabStatus)).length;
  $('count-review').textContent=events.filter(e=>['NeedsReview','Pending'].includes(e.overallStatus)).length;
  const selected=$('database').value;$('database').replaceChildren(node('option','All databases'));$('database').firstChild.value='';
  for(const db of [...new Set(events.map(e=>e.DatabaseName))].sort()){const option=node('option',db);option.value=db;$('database').append(option);} $('database').value=selected;
  const query=$('search').value.toLowerCase(),db=$('database').value,status=$('status').value;
  const rows=events.filter(e=>(!db||e.DatabaseName===db)&&(!status||e.overallStatus===status)&&JSON.stringify([e.DatabaseName,e.SchemaName,e.ObjectName,e.LoginName,e.evidence?.Rab?.Candidates?.map(c=>c.Key)]).toLowerCase().includes(query));
  $('events').replaceChildren();
  for(const event of rows){const tr=node('tr');tr.append(node('td',timeSast(event.eventAtUtc)));const object=node('td');object.append(node('span',event.DatabaseName,'db'),node('span',(event.SchemaName?event.SchemaName+'.':'')+event.ObjectName,'object'));tr.append(object,node('td',event.EventType,'event-type'),node('td',event.LoginName));const approvers=[...new Set((event.evidence?.Rab?.Candidates||[]).flatMap(c=>(c.Approval?.Approvers||[]).map(p=>p.Name)))];tr.append(node('td',approvers.join(', ')||'Not recorded'));for(const s of [event.repositoryStatus,event.rabStatus,event.overallStatus]){const td=node('td');td.append(badge(s));tr.append(td);}const td=node('td'),button=node('button','Evidence →');button.type='button';button.addEventListener('click',()=>openDetail(event));td.append(button);tr.append(td);$('events').append(tr);}
  $('rows').textContent=rows.length+' of '+events.length+' changes';$('empty').hidden=rows.length>0;
}
function openDetail(event){
  $('detail-title').textContent=event.DatabaseName+' / '+(event.SchemaName||'')+'.'+event.ObjectName;
  $('detail-meta').textContent=event.ServerName+' · Log ID '+event.LogId+' · '+event.EventType+' · '+timeSast(event.eventAtUtc)+' SAST · '+event.LoginName;
  $('detail-verdicts').replaceChildren(badge(event.repositoryStatus),badge(event.rabStatus));
  const repo=event.evidence?.Repository||{},rab=event.evidence?.Rab||{};
  $('repo-evidence').replaceChildren(node('p',repo.Reason||'Not assessed'));
  for(const match of repo.Matches||[]){const p=node('p',match.Method+' · ');const url='https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_git/SSDT_SA?path='+encodeURIComponent(match.Path)+'&version=GC'+encodeURIComponent(match.Commit);p.append(safeLink(url,match.Path+' @ '+match.Commit.slice(0,12)));$('repo-evidence').append(p);}
  $('rab-evidence').replaceChildren(node('p',rab.Reason||'Not assessed'));
  for(const candidate of rab.Candidates||[]){const block=node('div',undefined,'evidence-block');block.append(safeLink(candidate.Url,candidate.Key),node('p',(names[candidate.Status]||candidate.Status)+' · '+candidate.Reason));if(candidate.PrId)block.append(safeLink('https://dev.azure.com/BETSoftwareO365/SyX%20SSDT/_git/SSDT_SA/pullrequest/'+encodeURIComponent(candidate.PrId),'PR '+candidate.PrId));const approval=candidate.Approval||{};block.append(node('p','Recorded approver(s): '+((approval.Approvers||[]).map(p=>p.Name).join(', ')||'Not recorded')));block.append(node('p','DBA verifies approval validity and timing.'));for(const comment of approval.Comments||[]){const entry=node('div',undefined,'evidence-block');entry.append(node('p',comment.Author+' · created '+comment.Created+' · updated '+comment.Updated),node('p',comment.Text));block.append(entry);}if(!approval.CommentsComplete)block.append(node('p','Comments are unavailable or incomplete. Open the Jira release to verify.'));$('rab-evidence').append(block);}
  $('sql').textContent=event.sqlCommand||'';$('detail').showModal();
}
async function refresh(){
  $('refresh').disabled=true;
  try{const response=await fetch(demo?'data/demo.json':'data/change-audit.json',{cache:'no-store'});if(!response.ok)throw new Error('HTTP '+response.status);const data=await response.json();if(data.schemaVersion!==1||!Array.isArray(data.events))throw new Error('Invalid snapshot');state.data=data;state.failed=false;if(demo){const now=new Date();data.generatedAtUtc=now.toISOString();data.displayDate=daySast(now);data.events.forEach((e,i)=>e.eventAtUtc=new Date(now.getTime()-(i+1)*600000).toISOString());}render();}
  catch{state.failed=true;if(state.data)render();else{$('notice').textContent='Monitoring data unavailable. Configure the collector and JSON export. No production results have been loaded.';$('notice').className='notice error';$('empty').hidden=false;$('empty').textContent='Waiting for the first successful collection.';}}
  finally{$('refresh').disabled=false;}
}
for(const id of ['search','database','status'])$(id).addEventListener('input',render);
$('refresh').addEventListener('click',refresh);$('close').addEventListener('click',()=>$('detail').close());
refresh();setInterval(refresh,60000);
