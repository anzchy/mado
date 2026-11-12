// Test-only proof: distinguish deliberate host-targeted transport failures
// from transient unrelated candidates in a completed OS enumeration.
import assert from 'node:assert/strict';

export function countControlledFailures(queryFailures, hostPid) {
  assert.ok(Array.isArray(queryFailures));
  let controlled=0;
  for(const record of queryFailures){
    assert.ok(Array.isArray(record.unknown));
    if(record.transport?.errorCode==='ETIMEDOUT'){
      assert.equal(record.transport.stage,'process');
      assert.deepEqual(record.unknown.map(item=>item.pid),[hostPid],
        'each injected timeout must target the owned host');
      controlled++;
    }else{
      assert.equal(record.transport?.stage,'complete',
        'only complete OS snapshots may add unrelated uncertainty');
      assert.ok(record.unknown.length>0);
      assert.ok(record.unknown.every(item=>item.pid!==hostPid),
        'a non-injected uncertainty must not name the owned host');
    }
  }
  return controlled;
}
