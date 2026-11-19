const destination='https://bbkfsgnordtdiblgdzkg.supabase.co/functions/v1/rewarded-generation-ssv';
/** Called only after the provider signature and exact source attempt were
 * checked under the generation lease. Query bytes remain signature-identical. */
export async function forwardTransferredReward(request:Request,row:Record<string,any>,unity:boolean,fetcher:typeof fetch=fetch) {
  if(row.state!=='transferred'||!['pending','earned','spent'].includes(row.transfer_state)||
    !/^[0-9a-f-]{36}$/.test(row.transfer_user_id||'')||!/^[0-9a-f-]{36}$/.test(row.transfer_id||''))throw new Error('reward_transfer_unavailable');
  const query=new URL(request.url).search;if(!query||query.length>16384)throw new Error('reward_transfer_unavailable');
  const response=await fetcher(destination+query,{method:'GET',headers:{Accept:'application/json','X-SpyClash-Reward-Transfer':'1'},redirect:'manual',signal:AbortSignal.timeout(8000)});
  if(!response.ok){await response.body?.cancel();throw new Error('reward_transfer_unavailable');}
  const reader=response.body?.getReader();if(!reader)throw new Error('reward_transfer_unavailable');
  const chunks:Uint8Array[]=[];let size=0;
  try {while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>4096)throw new Error('reward_transfer_unavailable');chunks.push(value);}}
  finally {await reader.cancel().catch(()=>{});}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  const text=new TextDecoder().decode(bytes);
  if(unity&&text==='1')return {success:true};
  if(!unity&&JSON.parse(text)?.received===true)return {success:true};
  throw new Error('reward_transfer_unavailable');
}
