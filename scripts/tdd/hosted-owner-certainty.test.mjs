import test from 'node:test';
import assert from 'node:assert/strict';
import {createHostedOwnerCertainty} from './hosted-owner-certainty.mjs';

const drained={observed:true,hostPresent:false,childExited:true,childSignal:null,stopping:false};
const clean={complete:true,unknown:[]};

test('a later complete clean observation clears transient uncertainty before cleanup',()=>{
  const certainty=createHostedOwnerCertainty();
  certainty.observe({complete:true,unknown:[{pid:999999,reason:'unreadable'}]});
  assert.equal(certainty.canComplete(drained),false);
  certainty.observe(clean);
  assert.equal(certainty.canComplete(drained),true);
});

test('last unknown or failed transport observation refuses cleanup, even after a clean observation',()=>{
  for(const last of [{complete:true,unknown:[{pid:41,reason:'host identity unavailable'}]},
    {complete:false,unknown:[]}, {complete:false,unknown:[{reason:'transport failed'}]}]){
    const certainty=createHostedOwnerCertainty();
    certainty.observe(clean);
    certainty.observe(last);
    assert.equal(certainty.canComplete(drained),false,JSON.stringify(last));
  }
});

test('missing registration, a live host, and incomplete child exit refuse cleanup',()=>{
  const certainty=createHostedOwnerCertainty();
  certainty.observe(clean);
  for(const state of [{...drained,observed:false},{...drained,hostPresent:true},
    {...drained,childExited:false},{...drained,childSignal:'SIGTERM'},
    {...drained,stopping:true}])assert.equal(certainty.canComplete(state),false,JSON.stringify(state));
});

test('a failed registration or changed identity stays blocking after later clean observations',()=>{
  const certainty=createHostedOwnerCertainty();
  certainty.observe(clean);
  certainty.block();
  certainty.observe({complete:true,unknown:[{pid:41,reason:'unreadable'}]});
  certainty.observe(clean);
  assert.equal(certainty.canComplete(drained),false);
});
