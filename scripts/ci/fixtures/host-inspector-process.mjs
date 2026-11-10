import {spawn} from 'node:child_process';
const server=String.raw`
const readline=require('node:readline'),generation=process.argv[1],gated=process.argv[2]==='gate';
let snapshot={complete:true,processes:[],unknown:[]};
const emit=x=>process.stdout.write(JSON.stringify(x)+'\n');
const ready=()=>emit({protocol:1,type:'ready',generation});
process.on('message',m=>{if(m.ready)ready();if(m.snapshot)snapshot=m.snapshot;if(m.close)process.exit(0);});
readline.createInterface({input:process.stdin}).on('line',line=>{const r=JSON.parse(line);process.send({request:r});emit({protocol:1,type:'result',generation,requestId:r.requestId,snapshot});});
process.send({boot:true});if(!gated)ready();
`;
export function externalInspectorFixture(t,{gated=false}={}){
  let child,resolveBoot,resolveExit;const requests=[];
  const boot=new Promise(resolve=>resolveBoot=resolve),exited=new Promise(resolve=>resolveExit=resolve);
  const externalSpawn=(_command,args,options)=>{
    child=spawn(process.execPath,['-e',server,args.at(-1),gated?'gate':'ready'],{...options,stdio:['pipe','pipe','pipe','ipc']});
    child.on('message',m=>{if(m.boot)resolveBoot();if(m.request)requests.push(m.request);});child.once('close',resolveExit);return child;
  };
  t.after(async()=>{if(child){child.kill('SIGKILL');await exited;}});
  return {spawn:externalSpawn,boot,exited,requests,get child(){return child;},send:m=>child.send(m)};
}
