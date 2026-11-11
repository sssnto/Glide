// Exercise the actual embedded recovery script without a browser or credentials.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const elements = new Map();
function element(name) {
    if (!elements.has(name)) elements.set(name, { value: '', disabled: false, textContent: '',
        listeners: {}, addEventListener(type, fn) { this.listeners[type] = fn; } });
    return elements.get(name);
}
const page = { querySelector: element, addEventListener() {} };
const id = '11111111-2222-4333-8444-555555555555';
const calls = [];
let confirmation = false;
let status = { jobId: id, state: 'needs_verification', originalExists: false, originalRestored: false, canRecoverMissing: true };
const context = { document: { querySelector: () => page }, window: { confirm: () => confirmation },
    Dashboard: {}, ApiClient: { getUrl: x => x, ajax: async request => {
        calls.push(request);
        if (request.url === 'GlideToolkit/Recovery/Jobs') return [{ jobId: id, state: 'needs_verification' }];
        if (request.type === 'POST') return { ...status, state: 'failed', originalRestored: true, canRecoverMissing: false };
        return status;
    } } };
const file = path.join(__dirname, '../Server/Jellyfin.Plugin.GlideToolkit/Configuration/configPage.html');
const script = fs.readFileSync(file, 'utf8').split('<script>')[1].split('</script>')[0];
vm.runInNewContext(script, context);
const click = async name => { await element(name).listeners.click(); await new Promise(resolve => setImmediate(resolve)); };
(async () => {
    assert.equal(calls.length, 0, 'opening recovery page does not write or read automatically');
    await click('#GlideRecoveryList');
    assert.equal(element('#GlideRecoveryId').value, id);
    await click('#GlideRecoveryInspect');
    assert.equal(element('#GlideRecoveryRestore').disabled, false);
    await click('#GlideRecoveryRestore');
    assert.equal(calls.filter(c => c.type === 'POST').length, 0, 'cancelled confirmation never submits restore');
    confirmation = true;
    await click('#GlideRecoveryRestore');
    let posts = calls.filter(c => c.type === 'POST');
    assert.equal(posts.length, 1);
    assert.equal(posts[0].url, 'GlideToolkit/Jobs/' + id + '/RecoverMissing');
    assert.deepEqual(JSON.parse(posts[0].data), { confirmed: true });
    assert.equal(element('#GlideRecoveryRestore').disabled, true, 'successful repair cannot be submitted again');
    status = { ...status, originalExists: true, originalRestored: true, canRecoverMissing: false };
    await click('#GlideRecoveryInspect');
    assert.equal(element('#GlideRecoveryRestore').disabled, false, 'manual NAS repair can be reconciled');
    assert.equal(element('#GlideRecoveryRestore').textContent, '确认原片已恢复');
    element('#GlideRecoveryId').listeners.input();
    assert.equal(element('#GlideRecoveryRestore').disabled, true, 'changing the job invalidates prior verification');
    console.log('Passed recovery page confirmation, id-only submission, manual repair and stale selection checks');
})().catch(error => { console.error(error); process.exitCode = 1; });
