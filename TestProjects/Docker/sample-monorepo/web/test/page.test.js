import { test } from 'node:test';
import assert from 'node:assert/strict';
import { page } from '../server.js';

test('notes are listed and escaped', () => {
  const html = page([{ text: 'hello' }, { text: '<script>' }]);
  assert.match(html, /<li>hello<\/li>/);
  assert.match(html, /<li>&lt;script><\/li>/);
});
