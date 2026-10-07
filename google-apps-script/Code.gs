const SHEET_NAME = 'THOVE_NB_KEYS';
const HEADERS = ['id','name','key','note','expiresAt','enabled','createdAt','updatedAt'];
function doPost(e) {
  try {
    const input=JSON.parse(e.postData.contents||'{}'),expected=PropertiesService.getScriptProperties().getProperty('KEY_STORE_SECRET');
    if(!expected||input.secret!==expected)return reply({ok:false,error:'Unauthorized'});
    const lock=LockService.getScriptLock();lock.waitLock(10000);try{return reply(handle(input.action,input.payload||{}));}finally{lock.releaseLock();}
  }catch(err){return reply({ok:false,error:String(err.message||err)});}
}
function handle(action,payload){
  const sheet=getSheet(),rows=readRows(sheet),now=new Date().toISOString();
  if(action==='list')return{ok:true,keys:rows};
  if(action==='create'){validate(payload,true);if(rows.some(x=>x.id===payload.id||x.key===payload.key))throw Error('Duplicate key');const row=[payload.id,payload.name,payload.key,payload.note||'',payload.expiresAt||'',true,now,now];sheet.appendRow(row);return{ok:true,key:objectFrom(row)};}
  const index=rows.findIndex(x=>x.id===payload.id);if(index<0)throw Error('Key not found');
  if(action==='delete'){sheet.deleteRow(index+2);return{ok:true};}
  if(action==='update'){const current=rows[index],merged=Object.assign({},current,payload,{id:current.id,key:current.key,updatedAt:now});validate(merged,false);const row=HEADERS.map(k=>merged[k]);sheet.getRange(index+2,1,1,HEADERS.length).setValues([row]);return{ok:true,key:objectFrom(row)};}
  throw Error('Unknown action');
}
function getSheet(){const book=SpreadsheetApp.getActiveSpreadsheet();let sheet=book.getSheetByName(SHEET_NAME);if(!sheet){sheet=book.insertSheet(SHEET_NAME);sheet.getRange(1,1,1,HEADERS.length).setValues([HEADERS]);sheet.setFrozenRows(1);}return sheet;}
function readRows(sheet){const last=sheet.getLastRow();if(last<2)return[];return sheet.getRange(2,1,last-1,HEADERS.length).getValues().map(objectFrom);}
function objectFrom(row){const value={};HEADERS.forEach((k,i)=>value[k]=row[i]);value.enabled=value.enabled===true||String(value.enabled).toLowerCase()==='true';return value;}
function validate(v,creating){if(!/^[a-f0-9]{16}$/.test(String(v.id)))throw Error('Invalid id');if(!String(v.name||'').trim()||String(v.name).length>80)throw Error('Invalid name');if(String(v.note||'').length>200)throw Error('Invalid note');if(v.expiresAt&&!/^\d{4}-\d{2}-\d{2}$/.test(String(v.expiresAt)))throw Error('Invalid expiry');if(creating&&(!String(v.key).startsWith('NB-')||String(v.key).length<27))throw Error('Invalid key');}
function reply(value){return ContentService.createTextOutput(JSON.stringify(value)).setMimeType(ContentService.MimeType.JSON);}
