/** Signed aliases come only from the immutable user's archive snapshots. A
 * stable foreign owner always wins over email equality, including old rows. */
export async function deleteHistoricalOwnedContent(store:any,userID:string,ownerField:string,emailField:string,aliases:string[]) {
  if(!userID || !['player_user_id','owner_user_id'].includes(ownerField) || !['player_email','owner_email'].includes(emailField))throw new Error('Invalid content erasure scope');
  for(let pass=0;pass<8;pass++) {
    const selected=new Map<string,any>();
    for(const query of [{[ownerField]:userID},...[...new Set(aliases)].map(alias=>({[emailField]:alias}))]) {
      for(let skip=0;;skip+=100) {
        const rows=await store.filter(query,'created_date',100,skip);
        if(!Array.isArray(rows))throw new Error('Content ownership unavailable');
        for(const row of rows)if(row.id && (!row[ownerField] || row[ownerField]===userID))selected.set(row.id,row);
        if(rows.length<100)break;
      }
    }
    if(!selected.size)return;
    for(const row of selected.values())await store.delete(row.id);
  }
  throw new Error('Account content continued changing');
}

/** A participant's immutable ID outranks its contact field. Email-only legacy
 * references are considered only when no foreign participant binds that alias. */
export function historicalRoomSubject(room:Record<string,any>,userID:string,aliases:string[]) {
  const people=[...(Array.isArray(room.players)?room.players:[]),...(Array.isArray(room.spectators)?room.spectators:[])].filter(v=>v&&typeof v==='object');
  const ids=(Array.isArray(room.participant_user_ids)?room.participant_user_ids:[]);
  const ownedByID=ids.includes(userID)||room.host_user_id===userID||people.some(p=>p.user_id===userID);
  const foreignAliases=new Set(people.filter(p=>p.user_id&&p.user_id!==userID).map(p=>String(p.email||'').trim().toLowerCase()));
  if(room.host_user_id&&room.host_user_id!==userID)foreignAliases.add(String(room.host_email||'').trim().toLowerCase());
  return {ownedByID,aliases:[...new Set(aliases)].filter(alias=>!foreignAliases.has(alias))};
}
