export function findPostDrainUncertainty(queries,failureName){
  const reason=failureName==='unrelated PID'?'fixture post-drain unreadable PID':'fixture post-drain transport timeout';
  return queries.find(event=>event.snapshot.unknown.some(item=>item.reason===reason));
}
