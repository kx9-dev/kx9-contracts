import {ethers} from 'ethers';import fs from 'node:fs';import {spawn} from 'node:child_process';import net from 'node:net';import path from 'node:path';
const art=n=>JSON.parse(fs.readFileSync('out/'+n+'.json','utf8'));
const probe=net.createServer();await new Promise(resolve=>probe.listen(0,'127.0.0.1',resolve));const port=probe.address().port;await new Promise(resolve=>probe.close(resolve));
const anvil=spawn(process.execPath,[path.resolve('node_modules/@foundry-rs/anvil/bin.mjs'),'--host','127.0.0.1','--port',String(port),'--chain-id','4663','--hardfork','shanghai','--silent'],{stdio:'ignore'});
process.on('exit',()=>anvil.kill());anvil.unref();
const url='http://127.0.0.1:'+port;
let ready=false;for(let i=0;i<100;i++){try{const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'eth_chainId',params:[]})});if((await r.json()).result==='0x1237'){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,50));}
if(!ready)throw new Error('Local test chain did not start.');
const provider=new ethers.JsonRpcProvider(url,4663,{staticNetwork:true,cacheTimeout:-1});
const [deployer, operator, executor, stranger] = await Promise.all([0,1,2,3].map(i=>provider.getSigner(i)));
const deploy = async (n, s, ...a) => { const c = art(n); const f = new ethers.ContractFactory(c.abi, c.bytecode, s); const x = await f.deploy(...a); await x.waitForDeployment(); return x; };
let pass=0, fail=0; const ok=(c,m)=>{ if(c){pass++;console.log('  ✓',m)} else {fail++;console.log('  ✗',m)} };
const ifaces=[art('KX9Shield').abi,art('KX9ShieldFactory').abi].map(a=>new ethers.Interface(a));
const decode=e=>{const data=e?.data??e?.info?.error?.data?.data??e?.info?.error?.data??e?.error?.data;if(typeof data==='string'&&data.length>=10){for(const i of ifaces){try{const x=i.parseError(data);if(x)return x.name+'('+x.args.join(',')+')'}catch{}}}return e.shortMessage||String(e.message).slice(0,80)};
const reverts = async (p, m, reason) => { try { await p; ok(false, m+' (did not revert)'); } catch(e){ const d=decode(e); ok(reason===undefined || d.includes(reason), m+' → '+d); } };

const usdc = await deploy('MockERC20', deployer, 'USD Coin','USDC',6);
const nvda = await deploy('MockERC20', deployer, 'NVIDIA stock token','NVDA',18);
const kx9  = await deploy('MockERC20', deployer, 'KX9','KX9',18);
const oracle = await deploy('MockOracle', deployer);
await (await oracle.set(await usdc.getAddress(), 1_000000, 6)).wait();
await (await oracle.set(await nvda.getAddress(), 182_400000, 18)).wait();
const router = await deploy('MockRouter', deployer);
const factory = await deploy('KX9ShieldFactory', deployer, await oracle.getAddress(), await kx9.getAddress(), ethers.parseEther('1000'), await executor.getAddress(), [await router.getAddress()]);

console.log('Commission');
const limits = { maxTradeUsd: 500_000000n, dailyCapUsd: 2000_000000n, slippageBps: 80, cooldownSec: 0 };
const rc = await (await factory.connect(operator).commission(limits, [await usdc.getAddress(), await nvda.getAddress()])).wait();
const ev = rc.logs.map(l=>{try{return factory.interface.parseLog(l)}catch{return null}}).find(x=>x&&x.name==='UnitCommissioned');
ok(ev && ev.args.serial==='KX-9-0001', 'serial KX-9-0001 emitted');
const shield = new ethers.Contract(ev.args.shield, art('KX9Shield').abi, provider);
ok((await shield.operator())===await operator.getAddress(), 'operator owns the vault');
await (await usdc.mint(ev.args.shield, 5000_000000n)).wait();

const S = await shield.getAddress(), U = await usdc.getAddress(), N = await nvda.getAddress(), R = await router.getAddress();
const rate = ethers.parseUnits('1',18) * 10n**12n / 182_400000n * 1_000000n; // NVDA per 1 USDC (18 dec) scaled
const swapData = amt => router.interface.encodeFunctionData('swap',[U,N,amt,rate,S]);
const block = await provider.getBlock('latest'); const dl = BigInt(block.timestamp + 3600);
const intent = (id, amt, min=0n) => ({ proposalId: ethers.id(id), tokenIn: U, tokenOut: N, amountIn: amt, minAmountOut: min, deadline: dl });

console.log('Supervised flow');
await reverts(shield.connect(executor).execute.staticCall(intent('p1',300_000000n), R, swapData(300_000000n)), 'execute without approval is blocked', 'Blocked');
await reverts(shield.connect(stranger).approveProposal.staticCall(ethers.id('p1'), 300_000000n, dl), 'stranger cannot approve', 'NotOperator');
await (await shield.connect(operator).approveProposal(ethers.id('p1'), 300_000000n, dl)).wait();
await (await shield.connect(executor).execute(intent('p1',300_000000n), R, swapData(300_000000n))).wait();
const nb = await nvda.balanceOf(S); ok(nb > 0n, `trade executed, vault holds ${ethers.formatUnits(nb,18)} NVDA`);
ok((await shield.usedToday())===300_000000n, 'daily usage recorded ($300)');
await reverts(shield.connect(executor).execute.staticCall(intent('p1',300_000000n), R, swapData(300_000000n)), 'approval cannot be reused', 'Blocked');

console.log('Limits');
await (await shield.connect(operator).approveProposal(ethers.id('p2'), 900_000000n, dl)).wait();
await reverts(shield.connect(executor).execute.staticCall(intent('p2',900_000000n), R, swapData(900_000000n)), '$900 > max per trade is vetoed', 'Blocked');
await (await shield.connect(operator).approveProposal(ethers.id('p3'), 400_000000n, dl)).wait();
await (await router.setHaircut(200)).wait();
await reverts(shield.connect(executor).execute.staticCall(intent('p3',400_000000n), R, swapData(400_000000n)), '2% price impact > 0.8% slippage is blocked', 'Blocked');
await (await router.setHaircut(0)).wait();
await reverts(shield.connect(operator).setLimits.staticCall({...limits, maxTradeUsd: 10_000_000000n}), 'out-of-range limits rejected', 'BadLimits');

console.log('Modes & class');
await reverts(shield.connect(operator).setMode.staticCall(1), 'autonomous needs Mk II ($KX9 balance)', 'Blocked');
await (await kx9.mint(await operator.getAddress(), ethers.parseEther('1000'))).wait();
await (await shield.connect(operator).setMode(1)).wait();
ok(Number(await shield.mode())===1, 'autonomous enabled after holding 1000 KX9');
// Ganache can underestimate gas when the block timestamp changes between
// estimation and execution. Validate the call, then allow estimation headroom.
const autonomousArgs = [intent('auto1',200_000000n), R, swapData(200_000000n)];
await shield.connect(executor).execute.staticCall(...autonomousArgs);
const autonomousGas = await shield.connect(executor).execute.estimateGas(...autonomousArgs);
await (await shield.connect(executor).execute(...autonomousArgs, {gasLimit: autonomousGas * 2n})).wait();
ok((await shield.usedToday())===500_000000n, 'autonomous trade ran without approval');
await (await shield.connect(operator).setMode(2)).wait();
await reverts(shield.connect(executor).execute.staticCall(intent('auto2',100_000000n), R, swapData(100_000000n)), 'standby blocks the executor', 'Blocked');

console.log('Custody');
await reverts(shield.connect(executor).withdraw.staticCall(U, 1n, await executor.getAddress()), 'executor cannot withdraw', 'NotOperator');
const before = await usdc.balanceOf(await operator.getAddress());
await (await shield.connect(operator).withdraw(U, 1000_000000n, await operator.getAddress())).wait();
ok((await usdc.balanceOf(await operator.getAddress())) - before === 1000_000000n, 'operator withdrew 1,000 USDC');

console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail?1:0);

await provider.destroy();anvil.kill();
