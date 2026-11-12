/** A clean, current OS observation may clear a transient query failure. */
export function createHostedOwnerCertainty(){
  let latestClean=false,blocked=false;
  return {
    observe(snapshot){
      latestClean=snapshot.complete===true&&Array.isArray(snapshot.unknown)&&snapshot.unknown.length===0;
      return latestClean;
    },
    block(){blocked=true;},
    canComplete({observed,hostPresent,childExited,childSignal,stopping}){
      return latestClean&&!blocked&&observed&&!hostPresent&&childExited&&!childSignal&&!stopping;
    }
  };
}
