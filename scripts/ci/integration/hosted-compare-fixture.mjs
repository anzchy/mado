import {writeFileSync} from 'node:fs';
import path from 'node:path';

const shellQuote=value=>"'"+value.replaceAll("'","'\"'\"'")+"'";

export function writeHostedCompareXcodebuild(dir,hostPids,hostMilliseconds=2000){
  const driver=path.join(dir,'xcodebuild-driver.cjs');
  writeFileSync(path.join(dir,'xcodebuild'),`#!/bin/sh\n`+
    `exec /usr/bin/env -u MADO_TEST_RUN_TOKEN ${shellQuote(process.execPath)} ${shellQuote(driver)} "$MADO_TEST_RUN_TOKEN"\n`,{mode:0o755});
  writeFileSync(driver,
    `const {spawn}=require('node:child_process');const fs=require('node:fs');`+
    `const h=spawn(process.execPath,['-e','setTimeout(()=>{},${hostMilliseconds})'],`+
    `{detached:true,env:{...process.env,MADO_TEST_RUN_TOKEN:process.argv[2]},stdio:'ignore'});`+
    `fs.appendFileSync(${JSON.stringify(hostPids)},h.pid+'\\n');`+
    `h.unref();setTimeout(()=>console.log('** TEST EXECUTE SUCCEEDED **'),150);\n`);
}
