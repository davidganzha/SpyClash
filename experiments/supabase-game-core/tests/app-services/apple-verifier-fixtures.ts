import { Buffer } from 'node:buffer';
import jsrsasign from 'npm:jsrsasign@11.1.3';

// Disposable test CA only. Keys are generated in memory, never stored or trusted
// by application configuration. Real ECDSA signatures and DER OCSP responses
// exercise Apple's unmodified verifier, including its delegated signer checks.
const { KJUR, KEYUTIL, X509, pemtohex } = jsrsasign as any;
const time = (milliseconds: number) => new Date(milliseconds).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z').replace('T', '');
const der = (pem: string) => Buffer.from(pemtohex(pem), 'hex');

export type OCSPCase = 'good' | 'revoked' | 'unknown' | 'stale' | 'invalid-time' | 'wrong-signer' | 'tampered' | 'unavailable';

export function createAppleVerifierFixtures(origin: string) {
  const pairs = Array.from({length: 7}, () => KEYUTIL.generateKeypair('EC', 'secp256r1'));
  let serial = 1;
  const now = Date.now();
  function certificate(subject: string, issuer: string, pair: any, issuerPair: any, ext: any[] = [], options: {expired?: boolean} = {}) {
    return KJUR.asn1.x509.X509Util.newCertPEM({
      serial: {int: serial++}, sigalg: 'SHA256withECDSA',
      issuer: {str: issuer}, subject: {str: subject}, sbjpubkey: pair.pubKeyObj,
      notbefore: time(now - 86400_000), notafter: time(options.expired ? now - 3600_000 : now + 86400_000),
      ext, cakey: issuerPair.prvKeyObj,
    });
  }
  const rootName = '/CN=Disposable Apple verifier test root';
  const intermediateName = '/CN=Disposable Apple verifier test intermediate';
  const leafName = '/CN=Disposable Apple verifier test leaf';
  const root = certificate(rootName, rootName, pairs[0], pairs[0], [{extname:'basicConstraints',critical:true,cA:true}]);
  const intermediateExtensions = [
    {extname:'basicConstraints',critical:true,cA:true},
    {extname:'1.2.840.113635.100.6.2.1',extn:'0500'},
    {extname:'authorityInfoAccess',array:[{ocsp:origin+'/intermediate'}]},
  ];
  const intermediate = certificate(intermediateName, rootName, pairs[1], pairs[0], intermediateExtensions);
  const leafExtensions = [
    {extname:'basicConstraints',critical:true,cA:false},
    {extname:'1.2.840.113635.100.6.11.1',extn:'0500'},
    {extname:'authorityInfoAccess',array:[{ocsp:origin+'/leaf'}]},
  ];
  const leaf = certificate(leafName, intermediateName, pairs[2], pairs[1], leafExtensions);
  const expiredLeaf = certificate(leafName, intermediateName, pairs[2], pairs[1], leafExtensions, {expired:true});
  const missingOIDLeaf = certificate(leafName, intermediateName, pairs[2], pairs[1], leafExtensions.filter(ext=>ext.extname!=='1.2.840.113635.100.6.11.1'));
  const wrongCurvePair = KEYUTIL.generateKeypair('EC', 'secp384r1');
  const wrongCurveLeaf = certificate(leafName, intermediateName, wrongCurvePair, pairs[1], leafExtensions);
  const foreignRoot = certificate('/CN=Untrusted root', '/CN=Untrusted root', pairs[6], pairs[6], [{extname:'basicConstraints',critical:true,cA:true}]);
  const rootResponderName = '/CN=Disposable root OCSP responder';
  const leafResponderName = '/CN=Disposable intermediate OCSP responder';
  const responderExtensions = [{extname:'basicConstraints',cA:false},{extname:'extKeyUsage',array:[{name:'ocspSigning'}]}];
  const rootResponder = certificate(rootResponderName, rootName, pairs[3], pairs[0], responderExtensions);
  const leafResponder = certificate(leafResponderName, intermediateName, pairs[4], pairs[1], responderExtensions);
  const wrongResponder = certificate(leafResponderName, '/CN=Untrusted root', pairs[5], pairs[6], responderExtensions);
  let mode: OCSPCase = 'good';
  let calls = 0;
  const responses = new Map<string, Buffer>();
  function ocsp(path: string, requestedCertID:any) {
    const isLeaf = path.endsWith('/leaf');
    const signer = mode === 'wrong-signer' && isLeaf ? wrongResponder : isLeaf ? leafResponder : rootResponder;
    const pair = mode === 'wrong-signer' && isLeaf ? pairs[5] : isLeaf ? pairs[4] : pairs[3];
    const signedAt = mode === 'stale' && isLeaf ? now - 86400_000 : now;
    const certid = requestedCertID;
    const status = mode === 'revoked' && isLeaf ? {status:'revoked',time:time(now-1000),reason:1}
      : {status:mode === 'unknown' && isLeaf ? 'unknown' : 'good'};
    const response = new KJUR.asn1.ocsp.OCSPResponse({
      resstatus:0, restype:'ocspBasic', respid:{name:{str:isLeaf ? leafResponderName : rootResponderName}},
      prodat:time(signedAt), array:[{certid,status,thisupdate:mode==='invalid-time'&&isLeaf?'20261332129999Z':time(signedAt-1000),nextupdate:time(signedAt+3600_000)}],
      sigalg:'SHA256withECDSA', reskey:pair.prvKeyObj, certs:[signer],
    });
    const bytes = Buffer.from(response.getEncodedHex(), 'hex');
    if (mode === 'tampered' && isLeaf) {
      const parsed = new KJUR.asn1.ocsp.OCSPParser().getOCSPResponse(bytes.toString('hex'));
      const signature = Buffer.from(parsed.sighex, 'hex');
      const offset = bytes.indexOf(signature);
      if (offset < 0) throw new Error('OCSP fixture signature not found');
      bytes[offset + signature.length - 1] ^= 1;
    }
    return bytes;
  }
  return {
    rootDER: der(root), foreignRootDER: der(foreignRoot), leafDER: der(leaf), intermediateDER: der(intermediate),
    privateSigningKeyPEM: KEYUTIL.getPEM(pairs[2].prvKeyObj,'PKCS8PRV') as string,
    verifyClientJWT(token: string) { return KJUR.jws.JWS.verify(token,pairs[2].pubKeyObj,['ES256']); },
    get calls() { return calls; },
    setMode(value: OCSPCase) { mode = value; calls = 0; responses.clear(); },
    signed(payload: Record<string, unknown> = {}, options: {expired?:boolean;missingOID?:boolean} = {}) {
      const signingLeaf = options.expired ? expiredLeaf : options.missingOID ? missingOIDLeaf : leaf;
      return KJUR.jws.JWS.sign('ES256', JSON.stringify({alg:'ES256',x5c:[signingLeaf,intermediate,root].map(pem=>der(pem).toString('base64'))}),
        JSON.stringify({bundleId:'com.spyclash.ios',environment:'Sandbox',productId:'com.spyclash.ios.limitless.weekly',
          transactionId:'2000000000000001',originalTransactionId:'2000000000000001',signedDate:now,
          appAccountToken:'11111111-1111-4111-8111-111111111111',...payload}), pairs[2].prvKeyObj);
    },
    wrongCurveSigned() {
      const header = {alg:'ES384',x5c:[wrongCurveLeaf,intermediate,root].map(pem=>der(pem).toString('base64'))};
      const token = KJUR.jws.JWS.sign('ES384',JSON.stringify(header),JSON.stringify({bundleId:'com.spyclash.ios',environment:'Sandbox'}),wrongCurvePair.prvKeyObj);
      return Buffer.from(JSON.stringify({...header,alg:'ES256'})).toString('base64url')+'.'+token.split('.').slice(1).join('.');
    },
    invalidAlgorithmSigned(algorithm:'none'|'HS256') {
      const header={alg:algorithm,x5c:[leaf,intermediate,root].map(pem=>der(pem).toString('base64'))};
      const payload={bundleId:'com.spyclash.ios',environment:'Sandbox'};
      if (algorithm==='none') return [header,payload].map(value=>Buffer.from(JSON.stringify(value)).toString('base64url')).join('.')+'.';
      return KJUR.jws.JWS.sign('HS256',JSON.stringify(header),JSON.stringify(payload),{utf8:KEYUTIL.getPEM(pairs[2].pubKeyObj)});
    },
    async respond(request: Request) {
      calls++;
      const requestBody=Buffer.from(await request.arrayBuffer());
      if (mode === 'unavailable') return new Response(null,{status:503});
      const path = new URL(request.url).pathname;
      if (!path.endsWith('/leaf') && !path.endsWith('/intermediate')) return new Response(null,{status:404});
      const certID=new KJUR.asn1.ocsp.OCSPParser().getOCSPRequest(requestBody.toString('hex')).array[0];
      const key=path+JSON.stringify(certID);
      let body = responses.get(key);
      if (!body) { body = ocsp(path,certID); responses.set(key,body); }
      return new Response(Uint8Array.from(body),{headers:{'Content-Type':'application/ocsp-response'}});
    },
  };
}
