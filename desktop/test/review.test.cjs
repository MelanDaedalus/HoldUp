const assert = require('node:assert/strict');
const { test } = require('node:test');
const { checkClaim, compareSources, defaultRules } = require('../review.cjs');
const { LocalOllama } = require('../ollama.cjs');

const claim = 'Yellowstone visits rose 44% from 2023 to 2024.';
const quote = 'The 44% increase was measured from 2022.';
const selected = 'from 2023 to 2024';

test('claim check rejects invented quotes and uses the selected rule', async () => {
  const result = await checkClaim({ claim, rules: defaultRules }, async () => ({
    outcome: 'findings',
    findings: [
      { ruleID: 'r1', quote: 'Elsewhere', reason: 'A', verify: 'B' },
      { ruleID: 'r1', quote: selected, reason: 'Check the comparison year.', verify: 'Read the report.' }
    ]
  }));
  assert.equal(result.findings.length, 1);
  assert.equal(result.findings[0].rule, 'Missing baseline');
  assert.equal(result.findings[0].quote, selected);
});

test('source review preserves grounded quotes, attaches failures and leaves incomparable sources unresolved', async () => {
  const sources = [
    { text: quote, url: 'https://example.org/report', title: 'Report' },
    { text: 'Unavailable model result' }
  ];
  const report = await compareSources({ claim, sources }, async ({ excerpt }) => {
    if (excerpt !== quote) throw new Error('Simulated model failure');
    return { findings: [
      { quote, ruleID: 'r4', reason: 'The baseline is 2022.', verify: 'Challenges',
        evidence: { claimQuote: selected, measure: '', group: '', period: '2022', coverage: 'unknown' } },
      { quote: 'Invented', ruleID: 'r4', reason: 'A', verify: 'Supports', evidence: { claimQuote: selected } }
    ] };
  });
  assert.equal(report.sources[0].passages[0].quote, quote);
  assert.equal(report.sources[0].passages.length, 1);
  assert.equal(report.sources[0].url, sources[0].url);
  assert.equal(report.sources[1].status, 'failed');
  assert.equal(report.hasConflict, false);
});

test('cancellation stops source review instead of marking each source as failed', async () => {
  const abort = new AbortController();
  await assert.rejects(compareSources({ claim, sources: [{ text: quote }] }, async () => {
    abort.abort();
    abort.signal.throwIfAborted();
  }, abort.signal), { name: 'AbortError' });
});

test('Ollama cloud guard runs before any model or claim is sent', async () => {
  const requests = [];
  const client = new LocalOllama(async path => {
    requests.push(path);
    return { cloud: { disabled: false } };
  });
  await assert.rejects(client.generate('test:latest', {}, '', {}), /cloud/i);
  assert.deepEqual(requests, ['/api/status']);
});
