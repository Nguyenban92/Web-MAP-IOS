const SHEET_NAME = 'MAGIAO_AOV_KEYS';
const HEADERS = ['id', 'name', 'key', 'note', 'expiresAt', 'enabled', 'createdAt', 'updatedAt'];
const DISPLAY_HEADERS = [
  '🔑 MÃ ID',
  '👤 TÊN NGƯỜI DÙNG',
  '⚡ MÃ KEY TẠO PHÒNG',
  '📝 GHI CHÚ',
  '⏳ HẠN SỬ DỤNG',
  '🟢 TRẠNG THÁI',
  '📅 NGÀY TẠO',
  '🔄 CẬP NHẬT'
];

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('👑 MA GIÁO AOV')
    .addItem('✨ Làm đẹp giao diện (Chuyên nghiệp)', 'formatSheet')
    .addToUi();
}

function doPost(e) {
  try {
    const input = JSON.parse(e.postData.contents || '{}');
    const expected = PropertiesService.getScriptProperties().getProperty('KEY_STORE_SECRET');
    if (!expected || input.secret !== expected) return reply({ ok: false, error: 'Unauthorized' });
    const lock = LockService.getScriptLock();
    lock.waitLock(10000);
    try {
      return reply(handle(input.action, input.payload || {}));
    } finally {
      lock.releaseLock();
    }
  } catch (err) {
    return reply({ ok: false, error: String(err.message || err) });
  }
}

function handle(action, payload) {
  const sheet = getSheet(), rows = readRows(sheet), now = new Date().toISOString();
  if (action === 'list') return { ok: true, keys: rows };
  if (action === 'create') {
    validate(payload, true);
    if (rows.some(x => x.id === payload.id || x.key === payload.key)) throw Error('Duplicate key');
    const row = [payload.id, payload.name, payload.key, payload.note || '', payload.expiresAt || '', true, now, now];
    sheet.appendRow(row);
    styleRow(sheet, sheet.getLastRow());
    return { ok: true, key: objectFrom(row) };
  }
  const index = rows.findIndex(x => x.id === payload.id);
  if (index < 0) throw Error('Key not found');
  if (action === 'delete') {
    sheet.deleteRow(index + 2);
    return { ok: true };
  }
  if (action === 'update') {
    const current = rows[index];
    const merged = Object.assign({}, current, payload, { id: current.id, key: current.key, updatedAt: now });
    validate(merged, false);
    const row = HEADERS.map(k => merged[k]);
    sheet.getRange(index + 2, 1, 1, HEADERS.length).setValues([row]);
    styleRow(sheet, index + 2);
    return { ok: true, key: objectFrom(row) };
  }
  throw Error('Unknown action');
}

function getSheet() {
  const book = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = book.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = book.insertSheet(SHEET_NAME);
    formatSheetHeader(sheet);
  }
  return sheet;
}

function readRows(sheet) {
  const last = sheet.getLastRow();
  if (last < 2) return [];
  return sheet.getRange(2, 1, last - 1, HEADERS.length).getValues().map(objectFrom);
}

function objectFrom(row) {
  const value = {};
  HEADERS.forEach((k, i) => value[k] = row[i]);
  value.enabled = value.enabled === true || String(value.enabled).toLowerCase() === 'true';
  return value;
}

function validate(v, creating) {
  if (!/^[a-f0-9]{16}$/.test(String(v.id))) throw Error('Invalid id');
  if (!String(v.name || '').trim() || String(v.name).length > 80) throw Error('Invalid name');
  if (String(v.note || '').length > 200) throw Error('Invalid note');
  if (v.expiresAt && !/^\d{4}-\d{2}-\d{2}$/.test(String(v.expiresAt))) throw Error('Invalid expiry');
  if (creating && ((!String(v.key).startsWith('MG-') && !String(v.key).startsWith('NB-')) || String(v.key).length < 27)) throw Error('Invalid key');
}

function reply(value) {
  return ContentService.createTextOutput(JSON.stringify(value)).setMimeType(ContentService.MimeType.JSON);
}

function formatSheetHeader(sheet) {
  const header = sheet.getRange(1, 1, 1, DISPLAY_HEADERS.length);
  header.setValues([DISPLAY_HEADERS]);
  header.setBackground('#0F172A'); // Luxury Slate 900
  header.setFontColor('#F8FAFC'); // Crisp white
  header.setFontFamily('Roboto');
  header.setFontSize(11);
  header.setFontWeight('bold');
  header.setHorizontalAlignment('center');
  header.setVerticalAlignment('middle');
  sheet.setRowHeight(1, 45);
  sheet.setFrozenRows(1);

  // Column widths
  sheet.setColumnWidth(1, 150); // ID
  sheet.setColumnWidth(2, 200); // Tên người dùng
  sheet.setColumnWidth(3, 290); // Key tạo phòng
  sheet.setColumnWidth(4, 200); // Ghi chú
  sheet.setColumnWidth(5, 130); // Hạn sử dụng
  sheet.setColumnWidth(6, 130); // Trạng thái
  sheet.setColumnWidth(7, 160); // Ngày tạo
  sheet.setColumnWidth(8, 160); // Cập nhật lần cuối

  applyConditionalFormatting(sheet);
}

function styleRow(sheet, r) {
  sheet.setRowHeight(r, 36);
  const rowRange = sheet.getRange(r, 1, 1, DISPLAY_HEADERS.length);
  rowRange.setFontFamily('Roboto');
  rowRange.setFontSize(10);
  rowRange.setVerticalAlignment('middle');

  sheet.getRange(r, 1).setHorizontalAlignment('center').setFontFamily('Consolas').setFontColor('#64748B');
  sheet.getRange(r, 2).setHorizontalAlignment('left').setFontWeight('bold').setFontColor('#0F172A');
  sheet.getRange(r, 3).setHorizontalAlignment('center').setFontFamily('Consolas').setFontWeight('bold').setFontColor('#0284C7');
  sheet.getRange(r, 4).setHorizontalAlignment('left').setFontStyle('italic').setFontColor('#475569');
  sheet.getRange(r, 5).setHorizontalAlignment('center');
  sheet.getRange(r, 6).setHorizontalAlignment('center');
  sheet.getRange(r, 7, 1, 2).setHorizontalAlignment('center').setFontColor('#64748B').setFontSize(9);
}

function applyConditionalFormatting(sheet) {
  const range = sheet.getRange('F2:F1000');
  const ruleTrue = SpreadsheetApp.newConditionalFormatRule()
    .whenTextEqualTo('TRUE')
    .setBackground('#DCFCE7')
    .setFontColor('#15803D')
    .setBold(true)
    .setRanges([range])
    .build();
  const ruleFalse = SpreadsheetApp.newConditionalFormatRule()
    .whenTextEqualTo('FALSE')
    .setBackground('#FEE2E2')
    .setFontColor('#B91C1C')
    .setBold(true)
    .setRanges([range])
    .build();
  sheet.setConditionalFormatRules([ruleTrue, ruleFalse]);
}

function formatSheet() {
  const sheet = getSheet();
  formatSheetHeader(sheet);
  const last = sheet.getLastRow();
  for (let r = 2; r <= last; r++) {
    styleRow(sheet, r);
  }
}
